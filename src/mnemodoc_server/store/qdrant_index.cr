require "qdrant-client"

module MnemodocServer
  module Store
    # Best-effort wrapper over Qdrant::Collection: every call rescues transport/
    # Qdrant errors, logs, records an Advisory, and returns a safe value so a
    # missing/down Qdrant never aborts indexing or crashes a query. Used only
    # when search.backend == "qdrant".
    # Raised when Qdrant cannot even be addressed, so callers can degrade to
    # keyword-only rather than fail to start.
    class QdrantUnavailable < Exception; end

    class QdrantIndex
      Log = ::Log.for("mnemodoc-server.store.qdrant")

      # The one place in this best-effort wrapper that could still take the
      # process down. Qdrant::Collection raises ArgumentError on a URL with no
      # authority — `my-qdrant:6333`, which parses as a scheme, and which
      # validate! accepts since it only checks the URL is non-empty. The daemon
      # then died at startup instead of degrading to keyword-only as this
      # class's whole contract promises.
      def initialize(config : QdrantConfig, collection : String)
        ensure_addressable!(config.url)
        @collection = Qdrant::Collection.new(collection, config.url, config.api_key)
      end

      # Checked before constructing, because the client raises ArgumentError on
      # a URL with no authority — "my-qdrant:6333" parses as a scheme — and
      # validate! lets that through, only checking the URL is non-empty.
      private def ensure_addressable!(url : String) : Nil
        host = URI.parse(url).host
        return if host && !host.empty?
        raise QdrantUnavailable.new("qdrant.url has no host (#{url.inspect}); expected a scheme, e.g. http://host:6333")
      rescue ex : URI::Error
        raise QdrantUnavailable.new("qdrant.url is not a valid URL (#{url.inspect}): #{ex.message}")
      end

      # Idempotent collection creation (cosine; dim from the embedding model).
      def ensure(dim : Int32) : Bool
        @collection.ensure(dim, :cosine)
        true
      rescue ex
        warn("ensure", ex)
      end

      # Batch upsert keyed by chunks.id. Empty payload (hydration is SQLite's).
      # The qdrant-client batch overload reads point[0]=id, point[1]=vector.
      def upsert(entries : Array({id: Int64, vector: Array(Float32)})) : Bool
        return true if entries.empty?
        @collection.upsert(entries.map { |entry| {entry[:id], entry[:vector]} })
        true
      rescue ex
        warn("upsert", ex)
      end

      def delete(ids : Array(Int64)) : Bool
        return true if ids.empty?
        @collection.delete(ids)
        true
      rescue ex
        warn("delete", ex)
      end

      # Drops the whole collection (the caller's "clear").
      def clear : Bool
        @collection.delete
        true
      rescue ex
        warn("clear", ex)
      end

      # Unfiltered KNN; returns the matched (id, score), or [] on failure.
      def knn(query_vec : Array(Float32), limit : Int32) : Array({id: Int64, score: Float64})
        @collection.search(query_vec, limit).map { |hit| {id: hit.id, score: hit.score.to_f64} }
      rescue ex
        warn("knn", ex)
        [] of {id: Int64, score: Float64}
      end

      # Exact point count, or nil on failure (used for backfill parity).
      def count : Int64?
        @collection.count
      rescue ex
        warn("count", ex)
        nil
      end

      # Logs the failure and records a single deduplicated advisory; returns false
      # (the Bool methods' failure value).
      private def warn(op : String, ex : Exception) : Bool
        Log.warn { "qdrant #{op} failed: #{ex.message}" }
        Advisories.add("Qdrant #{op} failed (#{ex.message}); SQLite remains authoritative — re-index to resync.")
        false
      end
    end
  end
end
