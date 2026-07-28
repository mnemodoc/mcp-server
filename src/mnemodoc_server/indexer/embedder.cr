module MnemodocServer
  module Indexer
    # Raised for any failure talking to Ollama: unreachable host, non-200
    # response, or an unparseable body.
    class EmbedderError < Exception; end

    # Ollama could not be reached at all: the connection failed, was reset, or
    # the handshake did not complete. Distinguished from a bad *response*
    # because the two deserve opposite reactions — a rejected chunk is worth
    # retrying alone, an unreachable host is not, and retrying it per chunk
    # multiplies a dead batch by its chunk count.
    class EmbedderUnreachable < EmbedderError; end

    # Turns chunk text into embedding vectors by calling Ollama's /api/embeddings
    # endpoint, reusing connections through a per-host pool.
    class Embedder
      Log = ::Log.for("mnemodoc-server.indexer.embedder")

      # idle_connections: how many clients the pool keeps per host. The indexing
      # paths pass their concurrency, so a worker always finds one waiting.
      def initialize(@config : OllamaConfig, idle_connections : Int32 = ConnectionPool::IDLE_PER_HOST)
        @pool = ConnectionPool.new(@config.timeout, idle_connections)
        @uri = URI.parse(@config.host)
      end

      # Embeds all texts in a single /api/embed request and returns one raw
      # (unnormalized) vector per input text. Callers that need normalized
      # vectors (e.g. query path) should normalize the result themselves.
      def embed_batch(texts : Array(String)) : Array(Array(Float32))
        return [] of Array(Float32) if texts.empty?
        embed_many(texts)
      end

      # Embeds chunks in batches of @config.batch_size. A batch that fails
      # entirely is retried one-by-one so a single bad chunk never loses the
      # whole file. Returns successfully embedded chunks (normalised) and the
      # number skipped.
      def embed_chunks_resilient(chunks : Array(Chunk)) : {embedded: Array(Chunk), failed: Int32}
        embedded = [] of Chunk
        failed = 0
        chunks.each_slice(@config.batch_size) do |batch|
          begin
            vectors = embed_many(batch.map(&.content))
            batch.zip(vectors).each do |chunk, vec|
              embedded << Chunk.new(
                file_path: chunk.file_path,
                heading: chunk.heading,
                parent_heading: chunk.parent_heading,
                content: chunk.content,
                embedding: normalize(vec),
                token_count: chunk.token_count,
                mtime: chunk.mtime,
              )
            end
          rescue ex : EmbedderUnreachable
            # Nothing chunk-specific about an unreachable host: retrying each
            # one individually would only repeat the same failure, once per
            # chunk, each paying the connect timeout.
            Log.warn { "ollama unreachable, skipping #{batch.size} chunks without per-chunk retry: #{ex.message}" }
            failed += batch.size
          rescue ex : EmbedderError
            # The response was refused, which may well be about this batch's
            # content (an oversized input, typically), so it is worth splitting.
            Log.warn { "batch embed failed (#{batch.size} chunks), retrying one-by-one: #{ex.message}" }
            batch.each do |chunk|
              begin
                vec = embed_many([chunk.content]).first
                embedded << Chunk.new(
                  file_path: chunk.file_path,
                  heading: chunk.heading,
                  parent_heading: chunk.parent_heading,
                  content: chunk.content,
                  embedding: normalize(vec),
                  token_count: chunk.token_count,
                  mtime: chunk.mtime,
                )
              rescue ex : EmbedderError
                failed += 1
                Log.warn { "skipping chunk in #{chunk.file_path} (#{chunk.heading}): #{ex.message}" }
              end
            end
          end
        end
        {embedded: embedded, failed: failed}
      end

      # Drains all idle HTTP connections in the pool.
      def close : Nil
        @pool.close_all
      end

      # Normalizes a vector to L2 norm 1. Accumulates the norm in Float64 for
      # precision, then maps back to Float32. Returns the vector unchanged if
      # its norm is zero to avoid division by zero.
      private def normalize(vec : Array(Float32)) : Array(Float32)
        norm = Math.sqrt(vec.sum { |value| value.to_f64 * value.to_f64 })
        return vec if norm == 0.0
        vec.map { |value| (value.to_f64 / norm).to_f32 }
      end

      # Sends all texts in one /api/embed request and returns one unnormalized
      # Float32 vector per input. Uses batch semantics: one round-trip per call.
      private def embed_many(texts : Array(String)) : Array(Array(Float32))
        body = {model: @config.model, input: texts}.to_json
        client = @pool.checkout(@uri)
        headers = HTTP::Headers{"Content-Type" => "application/json"}

        begin
          response = client.post("/api/embed", headers: headers, body: body)

          unless response.success?
            @pool.discard(client)
            raise EmbedderError.new("Ollama returned #{response.status_code}: #{response.body.strip}")
          end

          @pool.checkin(@uri, client)

          # Every access is guarded: JSON::Any#[] raises on a receiver that is
          # not a hash, and as_a/as_f raise on a type mismatch. A 200 whose body
          # is `{"embeddings": null}` or plain `"OK"` — a proxy in the way, a
          # server marshalling a nil slice — used to escape as TypeCastError or
          # a bare Exception, past every caller's `rescue EmbedderError`, and
          # reach the MCP client as an internal error.
          body = JSON.parse(response.body).as_h?
          raise EmbedderError.new("Unexpected Ollama response: not a JSON object") unless body
          rows = body["embeddings"]?.try(&.as_a?)
          raise EmbedderError.new("Unexpected Ollama response: no embeddings array") unless rows
          rows.map do |vec|
            values = vec.as_a?
            raise EmbedderError.new("Unexpected Ollama response: an embedding is not an array") unless values
            values.map { |value| value.as_f?.try(&.to_f32) || 0.0_f32 }
          end
        rescue ex : IO::Error | Socket::Error | OpenSSL::Error
          # OpenSSL::Error is not an IO::Error, so a TLS failure against an
          # https:// host used to escape this rescue entirely — leaking the
          # borrowed client along with it, one descriptor per chunk.
          @pool.discard(client)
          raise EmbedderUnreachable.new("Cannot reach Ollama at #{@config.host}: #{ex.message}")
        rescue ex : KeyError | JSON::ParseException | TypeCastError
          raise EmbedderError.new("Unexpected Ollama response: #{ex.message}")
        end
      end
    end
  end
end
