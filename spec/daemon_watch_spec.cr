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

  # Winds the watcher fiber down and waits for it to actually return. Closing
  # the signal is not enough on its own: the loop is parked inside the shard's
  # poll, so it needs one event before it looks at the signal again. Returns
  # false if the fiber is still running at the deadline.
  private def wind_down(stop : Channel(Nil), done : Channel(Nil)) : Bool
    stop.close
    File.write(File.join(tmp_dir, "wake.md"), "# wake") rescue nil
    select
    when done.receive
      true
    when timeout(10.seconds)
      false
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

  describe "index artifacts" do
    # The index now lives inside the project (.mnemodoc/), so it sits under the
    # watched paths: its own files must never be treated as documents.
    it "recognises the database, its sidecars and the daemon files" do
      config = MnemodocServer::Config.from_yaml("db:\n  path: #{tmp_db}\npaths:\n  - #{tmp_dir}")
      expect(MnemodocServer.index_artifact?(tmp_db, config)).to be_true
      expect(MnemodocServer.index_artifact?("#{tmp_db}-wal", config)).to be_true
      expect(MnemodocServer.index_artifact?("#{tmp_db}-shm", config)).to be_true
      expect(MnemodocServer.index_artifact?("#{tmp_db}-journal", config)).to be_true
      expect(MnemodocServer.index_artifact?(config.daemon_socket_path, config)).to be_true
      expect(MnemodocServer.index_artifact?(config.daemon_lock_path, config)).to be_true
      expect(MnemodocServer.index_artifact?(config.daemon_pid_path, config)).to be_true
    end

    it "leaves ordinary documents sharing the directory alone" do
      config = MnemodocServer::Config.from_yaml("db:\n  path: #{tmp_db}\npaths:\n  - #{tmp_dir}")
      expect(MnemodocServer.index_artifact?(File.join(tmp_dir, "guide.md"), config)).to be_false
    end

    it "does not touch the store on a Deleted event for a sidecar" do
      with_mock_ollama do |port|
        h = harness(port)
        begin
          path = File.join(tmp_dir, "kept.md")
          File.write(path, "# Kept\n\n## S\n\nbody")
          MnemodocServer.handle_watch_event(FileWatcher::Event.new(path, :added),
            h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])

          MnemodocServer.handle_watch_event(
            FileWatcher::Event.new("#{tmp_db}-wal", :deleted),
            h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])

          expect(h[:store].list_files.map(&.path)).to contain(path)
        ensure
          h[:store].close
          h[:embedder].close
        end
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

  # Nothing used to stop this loop, which is fine for the daemon — its watcher
  # dies with the process — but not for a spec: the fiber outlived its example
  # and kept polling a directory the teardown had deleted, with a store it had
  # closed, logging DB::PoolRetryAttemptsExceeded (message nil, hence a bare
  # colon) into the middle of whatever example ran next.
  it "returns once its stop signal is closed" do
    with_mock_ollama do |port|
      h = harness(port)
      stop = Channel(Nil).new
      done = Channel(Nil).new
      begin
        spawn do
          MnemodocServer.watch_and_index(h[:config], h[:store], nil, stop: stop)
          done.send(nil)
        end
        Fiber.yield
        expect(wind_down(stop, done)).to be_true
      ensure
        h[:store].close
        h[:embedder].close
      end
    end
  end

  it "live-indexes a newly created file through the real watcher loop" do
    with_mock_ollama do |port|
      h = harness(port)
      stop = Channel(Nil).new
      done = Channel(Nil).new
      begin
        spawn do
          MnemodocServer.watch_and_index(h[:config], h[:store], nil, stop: stop)
          done.send(nil)
        end
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
        # Before anything it reads is taken away from it.
        wind_down(stop, done)
        h[:store].close
        h[:embedder].close
      end
    end
  end
end
