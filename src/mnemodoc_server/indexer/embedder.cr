module MnemodocServer
  module Indexer
    # Raised for any failure talking to Ollama: unreachable host, non-200
    # response, or an unparseable body.
    class EmbedderError < Exception; end

    # Turns chunk text into embedding vectors by calling Ollama's /api/embeddings
    # endpoint, reusing connections through a per-host pool.
    class Embedder
      Log = ::Log.for("mnemodoc-server.indexer.embedder")

      def initialize(@config : OllamaConfig)
        @pool = ConnectionPool.new(@config.timeout)
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
          rescue ex : EmbedderError
            # Batch failed: fall back to per-chunk to recover whatever we can.
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

          json = JSON.parse(response.body)
          json["embeddings"].as_a.map { |vec| vec.as_a.map(&.as_f.to_f32) }
        rescue ex : IO::Error | Socket::ConnectError
          @pool.discard(client)
          raise EmbedderError.new("Cannot reach Ollama at #{@config.host}: #{ex.message}")
        rescue ex : KeyError | JSON::ParseException
          raise EmbedderError.new("Unexpected Ollama response: #{ex.message}")
        end
      end
    end
  end
end
