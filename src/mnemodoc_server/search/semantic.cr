module MnemodocServer
  module Search
    # Ranks chunks by cosine similarity between the query embedding and each
    # chunk's stored embedding. Because stored embeddings are normalized to unit
    # length at index time, the query is normalized once and scoring reduces to
    # a plain dot product — allocation-free and faster than full cosine.
    class Semantic
      # Cosine similarity of two Float32 vectors; returns 0.0 for empty,
      # mismatched, or zero vectors. Accumulates dot product and squared norms
      # in Float64 for precision, reading Float32 inputs via unsafe_fetch.
      def self.cosine_similarity(a : Array(Float32), b : Array(Float32)) : Float64
        return 0.0 if a.empty? || b.empty? || a.size != b.size
        dot_val = 0.0
        norm_a = 0.0
        norm_b = 0.0
        i = 0
        while i < a.size
          av = a.unsafe_fetch(i).to_f64
          bv = b.unsafe_fetch(i).to_f64
          dot_val += av * bv
          norm_a += av * av
          norm_b += bv * bv
          i += 1
        end
        return 0.0 if norm_a == 0.0 || norm_b == 0.0
        dot_val / (Math.sqrt(norm_a) * Math.sqrt(norm_b))
      end

      # Scores all chunks against the query vector and returns the best
      # candidates with their 1-based rank (an over-fetch of top_k * 4 feeds the
      # downstream RRF fusion). The query is normalized to unit length once;
      # stored chunk embeddings are already unit-length, so scoring is a plain
      # dot product. Scores remain Float64.
      def search(query_vec : Array(Float32), chunks : Array(Chunk), top_k : Int32) : Array({chunk: Chunk, score: Float64, rank: Int32})
        normalized_query = normalize(query_vec)
        scored = chunks.map do |chunk|
          score = dot(normalized_query, chunk.embedding)
          {chunk: chunk, score: score}
        end

        scored.sort_by! { |item| -item[:score] }
        scored.first(top_k * 4).each_with_index.map do |item, idx|
          {chunk: item[:chunk], score: item[:score], rank: idx + 1}
        end.to_a
      end

      # Finds the top_k × 4 nearest chunks via the vec0 KNN SQL index.
      # Delegates entirely to store.knn_chunks; see Store::SQLite#knn_chunks.
      def search(query_vec : Array(Float32), store : Store::SQLite, top_k : Int32) : Array({chunk: Chunk, score: Float64, rank: Int32})
        store.knn_chunks(query_vec, limit: top_k * 4)
      end

      # KNN via Qdrant (the opt-in backend): hit ids are hydrated to Chunks from
      # SQLite, preserving Qdrant's score order. Ids absent from SQLite (a chunk
      # deleted while Qdrant lags) are skipped. An empty result (Qdrant down) lets
      # Hybrid degrade to keyword-only.
      def search(query_vec : Array(Float32), qdrant : Store::QdrantIndex, store : Store::SQLite, top_k : Int32) : Array({chunk: Chunk, score: Float64, rank: Int32})
        hits = qdrant.knn(query_vec, top_k)
        by_id = store.chunks_by_ids(hits.map(&.[:id]))
        hits.each_with_index.compact_map do |hit, index|
          by_id[hit[:id]]?.try { |chunk| {chunk: chunk, score: hit[:score], rank: index + 1} }
        end.to_a
      end

      # Normalizes a Float32 vector to L2 norm 1. Accumulates the norm in
      # Float64 for precision, then maps back to Float32. Returns the vector
      # unchanged if its norm is zero to avoid division by zero.
      private def normalize(vec : Array(Float32)) : Array(Float32)
        norm = Math.sqrt(vec.sum { |value| value.to_f64 * value.to_f64 })
        return vec if norm == 0.0
        vec.map { |value| (value.to_f64 / norm).to_f32 }
      end

      # Dot product of two Float32 vectors; returns 0.0 for empty or mismatched
      # vectors. Accumulates in Float64 for precision via unsafe_fetch.
      private def dot(a : Array(Float32), b : Array(Float32)) : Float64
        return 0.0 if a.empty? || b.empty? || a.size != b.size
        result = 0.0
        i = 0
        while i < a.size
          result += a.unsafe_fetch(i).to_f64 * b.unsafe_fetch(i).to_f64
          i += 1
        end
        result
      end
    end
  end
end
