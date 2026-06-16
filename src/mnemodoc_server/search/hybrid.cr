module MnemodocServer
  module Search
    # A scored chunk returned to callers, after fusion and recency boosting.
    struct SearchResult
      getter chunk : Chunk
      getter score : Float64

      def initialize(@chunk, @score)
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

        scores = {} of String => {chunk: Chunk, rrf: Float64}
        accumulate_semantic(scores, semantic_results)
        unless keyword_file_ranks.empty?
          accumulate_keyword(scores, keyword_file_ranks, keyword_chunks.group_by(&.file_path))
        end

        cutoff = recency_cutoff
        results = scores.values.map do |entry|
          SearchResult.new(entry[:chunk], apply_recency(entry[:rrf], entry[:chunk].mtime, cutoff))
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

      # Adds the semantic RRF contribution (weight 1.0) per chunk.
      private def accumulate_semantic(
        scores : Hash(String, NamedTuple(chunk: Chunk, rrf: Float64)),
        semantic_results : Array(NamedTuple(chunk: Chunk, score: Float64, rank: Int32)),
      ) : Nil
        semantic_results.each do |sem_result|
          key = "#{sem_result[:chunk].file_path}::#{sem_result[:chunk].heading}"
          current = scores[key]?.try(&.[:rrf]) || 0.0
          contribution = rrf_score(sem_result[:rank])
          scores[key] = {chunk: sem_result[:chunk], rrf: current + contribution}
          Log.debug { "semantic #{key} rank=#{sem_result[:rank]} +#{contribution.round(5)}" }
        end
      end

      # Adds the keyword contribution: a file's TOTAL keyword mass is
      # keyword_weight * rrf(file_rank), split evenly across all its chunks.
      # A large file's individual chunks therefore score LOWER than a small
      # file's chunks, preventing large files from dominating the top-k purely
      # by having many chunks.
      private def accumulate_keyword(
        scores : Hash(String, NamedTuple(chunk: Chunk, rrf: Float64)),
        keyword_file_ranks : Hash(String, Int32),
        chunks_by_file : Hash(String, Array(Chunk)),
      ) : Nil
        keyword_file_ranks.each do |path, rank|
          file_chunks = chunks_by_file[path]?
          next unless file_chunks
          per_chunk = (@config.keyword_weight * rrf_score(rank)) / file_chunks.size
          file_chunks.each do |chunk|
            key = "#{chunk.file_path}::#{chunk.heading}"
            current = scores[key]?.try(&.[:rrf]) || 0.0
            scores[key] = {chunk: chunk, rrf: current + per_chunk}
          end
          Log.debug { "keyword #{path} rank=#{rank} per_chunk=#{per_chunk.round(5)} over #{file_chunks.size} chunks" }
        end
      end
    end
  end
end
