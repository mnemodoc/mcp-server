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
        started = Time.instant
        expect { embedder.embed_batch(["text"]) }.to raise_error(MnemodocServer::Indexer::EmbedderError)
        elapsed = (Time.instant - started).total_seconds
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

  # Everything that goes wrong with Ollama has to arrive as EmbedderError,
  # because that is the only thing every caller rescues (tools/query.cr, and
  # the three CLI commands). Anything else reaches the MCP client as an
  # internal error instead of "Ollama is unreachable".
  describe "unexpected but well-formed responses" do
    private def responding(body : String, &)
      server = HTTP::Server.new do |ctx|
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        ctx.response.print(body)
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

    it "reports a null embeddings field as an embedder error" do
      responding(%({"embeddings": null})) do |port|
        embedder = MnemodocServer::Indexer::Embedder.new(
          MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}"))
        begin
          expect { embedder.embed_batch(["x"]) }
            .to raise_error(MnemodocServer::Indexer::EmbedderError)
        ensure
          embedder.close
        end
      end
    end

    it "reports a non-object body as an embedder error" do
      responding(%("OK")) do |port|
        embedder = MnemodocServer::Indexer::Embedder.new(
          MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}"))
        begin
          expect { embedder.embed_batch(["x"]) }
            .to raise_error(MnemodocServer::Indexer::EmbedderError)
        ensure
          embedder.close
        end
      end
    end
  end

  # Ollama closes idle keep-alive connections. The pool handed one back without
  # revalidating it and the caller did not retry, so the first request after a
  # pause failed with "cannot reach Ollama" while Ollama was perfectly up — and
  # the one after it succeeded. An intermittent failure with no cause visible.
  describe "a connection the server closed while it sat idle" do
    it "retries once on a fresh connection instead of failing" do
      embedding = Array(Float32).new(768, 0.25_f32)
      served = 0
      server = HTTP::Server.new do |ctx|
        served += 1
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        body = ctx.request.body.try(&.gets_to_end) || ""
        count = JSON.parse(body)["input"].as_a.size rescue 1
        # Refuse to keep the connection alive, so the pooled client is dead by
        # the time it is checked out again.
        ctx.response.headers["Connection"] = "close"
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      embedder = MnemodocServer::Indexer::Embedder.new(
        MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{addr.port}"))
      begin
        expect(embedder.embed_batch(["first"]).size).to eq(1)
        expect(embedder.embed_batch(["second"]).size).to eq(1)
        expect(served).to be >= 2
      ensure
        embedder.close
        server.close
      end
    end
  end

  # When the host itself is unreachable, retrying every chunk one by one buys
  # nothing: the failure is not about the chunk. On a corpus of any size that
  # turned one dead batch into one dead request per chunk, each paying the
  # connect timeout, times the indexing concurrency.
  describe "a host that is not answering" do
    it "does not retry every chunk individually" do
      attempts = 0
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      spawn do
        while socket = server.accept?
          attempts += 1
          socket.close
        end
      end
      Fiber.yield

      chunks = (1..30).map do |i|
        MnemodocServer::Chunk.new(file_path: "doc/a.md", heading: "## #{i}", parent_heading: nil,
          content: "body #{i}", embedding: [] of Float32, token_count: 1, mtime: 1_i64)
      end
      embedder = MnemodocServer::Indexer::Embedder.new(
        MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 10"))
      begin
        result = embedder.embed_chunks_resilient(chunks)
        expect(result[:embedded]).to be_empty
        expect(result[:failed]).to eq(30)
        # Three batches, plus at most one retry apiece. Thirty means the
        # per-chunk storm is back.
        expect(attempts).to be < 10
      ensure
        embedder.close
        server.close
      end
    end
  end
end
