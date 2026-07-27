module MnemodocServer
  module Search
    # A scored chunk returned to callers, after fusion and recency boosting.
    #
    # `score` is the fused RRF value: it orders results but carries no absolute
    # meaning — the top hit of an off-topic query scores like the top hit of a
    # perfectly targeted one. `similarity` is the cosine against the query
    # vector — a real one: `knn_chunks` converts vec0's L2 distance back with
    # `cos = 1 - L2²/2`, exact because both sides are unit vectors. It *is*
    # comparable across queries, and is what a caller needs
    # to decide whether a prompt concerns this corpus at all (the prompt hook).
    # It is nil for a chunk surfaced by the lexical signal alone: that chunk was
    # never scored against the query vector, so it must not clear a threshold.
    struct SearchResult
      getter chunk : Chunk
      getter score : Float64
      getter similarity : Float64?

      def initialize(@chunk, @score, @similarity = nil)
      end
    end

    # Combines semantic and keyword results using Reciprocal Rank Fusion (RRF)
    # and applies a small recency boost. The config's `mode` selects which
    # signals contribute (hybrid, semantic-only, or keyword-only).
    class Hybrid
      Log = ::Log.for("mnemodoc-server.search.hybrid")

      # RRF dampening constant: larger values flatten the contribution of rank.
      RRF_K = 60

      # qdrant_index: when set (search.backend == "qdrant"), the semantic half
      # routes through Qdrant instead of vec0; nil → vec0 (default).
      def initialize(@config : SearchConfig, @qdrant_index : Store::QdrantIndex? = nil)
        @semantic = Semantic.new
        @keyword = Keyword.new
      end

      # Runs the enabled search signals, fuses them per chunk via RRF, applies
      # the recency boost, and returns the top_k highest-scoring chunks.
      # Semantic weight is 1.0; keyword weight is config.keyword_weight split
      # evenly across a file's chunks so chunk count does not inflate scores.
      # The store backs both signals: vec0 KNN for semantic, FTS5/BM25 for
      # keyword; only the matched files' chunks are then hydrated for fusion.
      def search(query : String, query_vec : Array(Float32), store : Store::SQLite) : Array(SearchResult)
        semantic_results = [] of {chunk: Chunk, score: Float64, rank: Int32}
        keyword_file_ranks = {} of String => Int32
        keyword_chunks = [] of Chunk

        if @config.mode.in?("hybrid", "semantic")
          semantic_results =
            if qdrant = @qdrant_index
              @semantic.search(query_vec, qdrant, store, top_k: @config.top_k * 4)
            else
              @semantic.search(query_vec, store, top_k: @config.top_k * 4)
            end
        end

        if @config.mode.in?("hybrid", "keyword")
          kw_results = @keyword.search(query, store, limit: @config.top_k * 4)
          kw_results.each { |kw_result| keyword_file_ranks[kw_result[:path]] = kw_result[:rank] }
          keyword_chunks = store.chunks_for_files(keyword_file_ranks.keys) unless keyword_file_ranks.empty?
        end

        Log.debug { "fusion: semantic=#{semantic_results.size} chunks, keyword=#{keyword_file_ranks.size} files" }

        # similarity rides alongside the fused score: RRF still orders, cosine
        # only travels with the result so callers can judge absolute relevance.
        scores = {} of String => {chunk: Chunk, rrf: Float64, similarity: Float64?}
        accumulate_semantic(scores, semantic_results)
        unless keyword_file_ranks.empty?
          accumulate_keyword(scores, keyword_file_ranks, keyword_chunks.group_by(&.file_path))
        end

        cutoff = recency_cutoff
        results = scores.values.map do |entry|
          SearchResult.new(entry[:chunk], apply_recency(entry[:rrf], entry[:chunk].mtime, cutoff), entry[:similarity])
        end

        top = results.sort_by! { |result| -result.score }.first(@config.top_k)
        Log.debug { "top_k: #{top.map { |result| "#{result.chunk.file_path}=#{result.score.round(5)}" }}" }
        top
      end

      # Reciprocal Rank Fusion weight for a given rank.
      def rrf_score(rank : Int32) : Float64
        1.0 / (RRF_K + rank)
      end

      # Unix timestamp marking the start of the recency window.
      def recency_cutoff : Int64
        (Time.utc - @config.recency_days.days).to_unix
      end

      # Multiplicatively nudges files changed within the recency window:
      # recent files score x(1 + recency_boost). Never dominates the ranking.
      def apply_recency(score : Float64, mtime : Int64, cutoff : Int64 = recency_cutoff) : Float64
        mtime >= cutoff ? score * (1.0 + @config.recency_boost) : score
      end

      # Identifies a chunk for fusion: the two signals must land on the same key
      # for the same chunk, and on different keys for different ones.
      #
      # The `chunks.id` is what makes that true. Both signals read their chunks
      # from the store, so both carry it. Path + heading does NOT: a headingless
      # document, and every section long enough to be split, yield several chunks
      # sharing one heading — they collapsed onto a single entry, so one passage
      # disappeared from the results while its RRF mass inflated the survivor.
      # The path+heading form is kept only for a chunk built outside the store
      # (never the case on the search path), where it is the best available.
      private def fusion_key(chunk : Chunk) : String
        if id = chunk.id
          "id:#{id}"
        else
          "path:#{chunk.file_path}::#{chunk.heading}"
        end
      end

      # Adds the semantic RRF contribution (weight 1.0) per chunk.
      private def accumulate_semantic(
        scores : Hash(String, NamedTuple(chunk: Chunk, rrf: Float64, similarity: Float64?)),
        semantic_results : Array(NamedTuple(chunk: Chunk, score: Float64, rank: Int32)),
      ) : Nil
        semantic_results.each do |sem_result|
          key = fusion_key(sem_result[:chunk])
          current = scores[key]?.try(&.[:rrf]) || 0.0
          contribution = rrf_score(sem_result[:rank])
          scores[key] = {chunk: sem_result[:chunk], rrf: current + contribution, similarity: sem_result[:score]}
          Log.debug { "semantic #{key} rank=#{sem_result[:rank]} +#{contribution.round(5)}" }
        end
      end

      # Adds the keyword contribution: a file's TOTAL keyword mass is
      # keyword_weight * rrf(file_rank), split evenly across all its chunks.
      # A large file's individual chunks therefore score LOWER than a small
      # file's chunks, preventing large files from dominating the top-k purely
      # by having many chunks.
      private def accumulate_keyword(
        scores : Hash(String, NamedTuple(chunk: Chunk, rrf: Float64, similarity: Float64?)),
        keyword_file_ranks : Hash(String, Int32),
        chunks_by_file : Hash(String, Array(Chunk)),
      ) : Nil
        keyword_file_ranks.each do |path, rank|
          file_chunks = chunks_by_file[path]?
          next unless file_chunks
          per_chunk = (@config.keyword_weight * rrf_score(rank)) / file_chunks.size
          file_chunks.each do |chunk|
            key = fusion_key(chunk)
            existing = scores[key]?
            current = existing.try(&.[:rrf]) || 0.0
            # Never invent a similarity here: a chunk the semantic signal did
            # not score keeps nil, so it cannot clear a threshold on lexical
            # evidence alone.
            scores[key] = {chunk: chunk, rrf: current + per_chunk, similarity: existing.try(&.[:similarity])}
          end
          Log.debug { "keyword #{path} rank=#{rank} per_chunk=#{per_chunk.round(5)} over #{file_chunks.size} chunks" }
        end
      end
    end
  end
end
