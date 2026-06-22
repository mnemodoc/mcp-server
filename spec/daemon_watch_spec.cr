require "./spec_helper"
require "file_utils"

# Drives the watch event handler directly (no infinite poll loop): a synthesised
# FileWatcher::Event is fed to handle_watch_event with a mock Ollama embeddings
# server, and the store is inspected. Mirrors the mock pattern in crawler_spec.
Spectator.describe "MnemodocServer daemon watch" do
  let(tmp_dir) { "/tmp/mnemodoc-watch-#{Random::Secure.hex(4)}" }
  let(tmp_db) { File.join(tmp_dir, "index.db") }

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Mock Ollama embeddings server returning a fixed 768-dim vector for any input.
  private def with_mock_ollama(&)
    embedding = Array(Float32).new(768, 0.1_f32)
    server = HTTP::Server.new do |ctx|
      ctx.response.status_code = 200
      ctx.response.content_type = "application/json"
      body = ctx.request.body.try(&.gets_to_end) || ""
      count = JSON.parse(body)["input"].as_a.size rescue 1
      ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
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

  # Builds the config + collaborators handle_watch_event needs, pointed at the
  # mock Ollama and the temp dir as the only watched path.
  private def harness(port : Int32)
    config = MnemodocServer::Config.from_yaml(
      "db:\n  path: #{tmp_db}\npaths:\n  - #{tmp_dir}\nollama:\n  host: http://127.0.0.1:#{port}\n  model: test"
    )
    store = MnemodocServer::Store::SQLite.new(config.db_path)
    registry = MnemodocServer::Indexer::Format::Registry.new(config)
    embedder = MnemodocServer::Indexer::Embedder.new(config.ollama)
    {config: config, store: store, registry: registry, embedder: embedder, sf: MnemodocServer::SingleFlight.new}
  end

  it "indexes a new supported file on an Added event" do
    with_mock_ollama do |port|
      h = harness(port)
      begin
        path = File.join(tmp_dir, "guide.md")
        File.write(path, "# Guide\n\n## Section\n\nReal content here.")
        MnemodocServer.handle_watch_event(
          FileWatcher::Event.new(path, :added),
          h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])
        expect(h[:store].list_files.map(&.path)).to contain(path)
      ensure
        h[:store].close
        h[:embedder].close
      end
    end
  end

  it "removes a file from the index on a Deleted event" do
    with_mock_ollama do |port|
      h = harness(port)
      begin
        path = File.join(tmp_dir, "gone.md")
        File.write(path, "# Gone\n\n## S\n\nbody")
        MnemodocServer.handle_watch_event(FileWatcher::Event.new(path, :added),
          h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])
        File.delete(path)
        MnemodocServer.handle_watch_event(FileWatcher::Event.new(path, :deleted),
          h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])
        expect(h[:store].list_files.map(&.path)).not_to contain(path)
      ensure
        h[:store].close
        h[:embedder].close
      end
    end
  end

  it "ignores an unsupported extension" do
    with_mock_ollama do |port|
      h = harness(port)
      begin
        path = File.join(tmp_dir, "logo.png")
        File.write(path, "not text")
        MnemodocServer.handle_watch_event(FileWatcher::Event.new(path, :added),
          h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])
        expect(h[:store].list_files).to be_empty
      ensure
        h[:store].close
        h[:embedder].close
      end
    end
  end

  it "live-indexes a newly created file through the real watcher loop" do
    with_mock_ollama do |port|
      h = harness(port)
      begin
        spawn { MnemodocServer.watch_and_index(h[:config], h[:store], nil) }
        Fiber.yield
        path = File.join(tmp_dir, "live.md")
        File.write(path, "# Live\n\n## S\n\nbody")
        indexed = false
        12.times do
          sleep 0.5.seconds
          if h[:store].list_files.map(&.path).includes?(path)
            indexed = true
            break
          end
        end
        expect(indexed).to be_true
      ensure
        h[:store].close
        h[:embedder].close
      end
    end
  end
end
