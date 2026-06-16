require "./spec_helper"

Spectator.describe MnemodocServer::Indexer::Embedder do
  # Fake Ollama server responding to /api/embed with a fixed embedding for each input.
  private def fake_ollama(embedding : Array(Float32), status : Int32 = 200, &)
    server = HTTP::Server.new do |ctx|
      ctx.response.status_code = status
      ctx.response.content_type = "application/json"
      if status == 200
        body = ctx.request.body.try(&.gets_to_end) || ""
        count = JSON.parse(body)["input"].as_a.size rescue 1
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      else
        ctx.response.print({"error" => "server error"}.to_json)
      end
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield addr.port
    ensure
      server.close
    end
  end

  # Variant that returns 500 when the request body contains the given marker,
  # and 200 with a valid embedding array otherwise. Simulates per-chunk failures.
  private def fake_ollama_selective(marker : String, embedding : Array(Float32), &)
    server = HTTP::Server.new do |ctx|
      body = ctx.request.body.try(&.gets_to_end) || ""
      if body.includes?(marker)
        ctx.response.status_code = 500
        ctx.response.content_type = "application/json"
        ctx.response.print(%({"error": "the input length exceeds the context length"}))
      else
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        count = JSON.parse(body)["input"].as_a.size rescue 1
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      end
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield addr.port
    ensure
      server.close
    end
  end

  # Starts a server that accepts connections but never sends a response,
  # simulating a hung Ollama process. Used to test read-timeout behavior.
  private def slow_ollama(&)
    server = HTTP::Server.new do |_ctx|
      sleep 300.seconds
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield addr.port
    ensure
      server.close
    end
  end

  # Fake Ollama that tracks request count and returns one embedding per input
  # via the /api/embed format ({"embeddings": [[...], [...]]}).
  # Yields (port, get_count) where get_count is a lambda returning the current count.
  # Using a lambda avoids the Atomic struct copy-on-yield problem.
  private def counting_ollama(embedding : Array(Float32), &)
    request_count = Atomic(Int32).new(0)
    server = HTTP::Server.new do |ctx|
      request_count.add(1)
      body = ctx.request.body.try(&.gets_to_end) || ""
      parsed = JSON.parse(body)
      inputs = parsed["input"].as_a
      embeddings = inputs.map { embedding }
      ctx.response.status_code = 200
      ctx.response.content_type = "application/json"
      ctx.response.print({"embeddings" => embeddings}.to_json)
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    get_count = -> { request_count.get }
    begin
      yield addr.port, get_count
    ensure
      server.close
    end
  end

  describe "#embed_batch" do
    it "returns embeddings for each text" do
      embedding = Array(Float32).new(768, 0.1_f32)
      counting_ollama(embedding) do |port, _get_count|
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 2")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        results = embedder.embed_batch(["text one", "text two"])
        expect(results.size).to eq(2)
        expect(results.first.size).to eq(768)
        embedder.close
      end
    end

    it "sends all texts in a single HTTP request per batch" do
      embedding = Array(Float32).new(4, 0.1_f32)
      counting_ollama(embedding) do |port, get_count|
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 10")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        results = embedder.embed_batch(["a", "b", "c", "d"])
        expect(results.size).to eq(4)
        expect(get_count.call).to eq(1)
        embedder.close
      end
    end

    it "raises EmbedderError within the configured timeout when Ollama hangs" do
      # Server sleeps 300s so without a real read_timeout the test would hang.
      # With timeout=1 the call must fail in under 5 seconds.
      slow_ollama do |port|
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\ntimeout: 1")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        started = Time.monotonic
        expect { embedder.embed_batch(["text"]) }.to raise_error(MnemodocServer::Indexer::EmbedderError)
        elapsed = (Time.monotonic - started).total_seconds
        expect(elapsed).to be < 5.0
        embedder.close
      end
    end

    it "raises EmbedderError when Ollama is unreachable" do
      config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:1")
      embedder = MnemodocServer::Indexer::Embedder.new(config)
      expect { embedder.embed_batch(["text"]) }.to raise_error(MnemodocServer::Indexer::EmbedderError)
      embedder.close
    end

    it "raises EmbedderError on non-200 response" do
      fake_ollama([] of Float32, status: 404) do |port|
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        expect { embedder.embed_batch(["text"]) }.to raise_error(MnemodocServer::Indexer::EmbedderError)
        embedder.close
      end
    end
  end

  describe "#embed_chunks_resilient" do
    it "skips chunks that fail to embed and returns the rest successfully embedded" do
      embedding = Array(Float32).new(768, 0.1_f32)
      # The fake server returns 500 when the body contains "BOOM", 200 otherwise.
      fake_ollama_selective(marker: "BOOM", embedding: embedding) do |port|
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)

        mtime = 1000_i64
        chunks = [
          MnemodocServer::Chunk.new(file_path: "doc/a.md", heading: "## A", parent_heading: nil, content: "good content one", embedding: [] of Float32, token_count: 10, mtime: mtime),
          MnemodocServer::Chunk.new(file_path: "doc/a.md", heading: "## B", parent_heading: nil, content: "this chunk has BOOM in it", embedding: [] of Float32, token_count: 10, mtime: mtime),
          MnemodocServer::Chunk.new(file_path: "doc/a.md", heading: "## C", parent_heading: nil, content: "good content three", embedding: [] of Float32, token_count: 10, mtime: mtime),
        ]

        result = embedder.embed_chunks_resilient(chunks)

        expect(result[:embedded].size).to eq(2)
        expect(result[:failed]).to eq(1)
        # Embedded chunks must have a non-empty embedding vector
        result[:embedded].each do |chunk|
          expect(chunk.embedding.size).to eq(768)
        end
        embedder.close
      end
    end

    it "embeds chunks in batches of batch_size, reducing Ollama round-trips" do
      request_count = Atomic(Int32).new(0)
      embedding = Array(Float32).new(768, 0.1_f32)

      server = HTTP::Server.new do |ctx|
        request_count.add(1)
        body = ctx.request.body.try(&.gets_to_end) || ""
        count = JSON.parse(body)["input"].as_a.size rescue 1
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      # batch_size = 3, 7 chunks → should make ceil(7/3) = 3 requests (not 7)
      cfg = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{addr.port}\nmodel: test\nbatch_size: 3")
      embedder = MnemodocServer::Indexer::Embedder.new(cfg)
      mtime = Time.utc.to_unix
      chunks = 7.times.map { |i|
        MnemodocServer::Chunk.new(
          file_path: "/f.md", heading: nil, parent_heading: nil,
          content: "chunk #{i}", embedding: [] of Float32, token_count: 1, mtime: mtime
        )
      }.to_a

      result = embedder.embed_chunks_resilient(chunks)
      expect(result[:embedded].size).to eq(7)
      expect(result[:failed]).to eq(0)
      expect(request_count.get).to eq(3)

      server.close
    end

    it "normalizes embedded chunk vectors to unit length" do
      # All-0.1 vector of size 4; its raw norm is sqrt(4 * 0.01) = 0.2, not 1.
      # After normalization the L2 norm must be approximately 1.0.
      # Tolerance is 0.001 to accommodate Float32 precision.
      embedding = Array(Float32).new(4, 0.1_f32)
      fake_ollama(embedding) do |port|
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)

        mtime = 1000_i64
        chunks = [
          MnemodocServer::Chunk.new(file_path: "doc/norm.md", heading: nil, parent_heading: nil, content: "normalize me", embedding: [] of Float32, token_count: 2, mtime: mtime),
        ]

        result = embedder.embed_chunks_resilient(chunks)
        expect(result[:embedded].size).to eq(1)

        vec = result[:embedded].first.embedding
        norm = Math.sqrt(vec.sum { |value| value.to_f64 * value.to_f64 })
        expect(norm).to be_close(1.0, 0.001)
        embedder.close
      end
    end
  end
end
