require "./spec_helper"
require "file_utils"
require "log/memory_backend"

# Drives the watch event handler directly (no infinite poll loop): a synthesised
# Watch::Event is fed to handle_watch_event with a mock Ollama embeddings
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
  # the signal is enough on its own — no file event is needed to wake it, which
  # is what let the daemon teardown give up on it and leave the index open.
  # Returns false if the fiber is still running at the deadline.
  private def wind_down(stop : Channel(Nil), done : Channel(Nil), within = 1.second) : Bool
    stop.close
    select
    when done.receive
      true
    when timeout(within)
      false
    end
  end

  # A native backend that cannot start, as when the kernel refuses a watch.
  class RefusedBackend < Watch::Backend
    def run(stop : Channel(Nil), &_block : Watch::Event ->) : Nil
      raise Watch::Unavailable.new("refused for the spec")
    end
  end

  # Builds the config + collaborators handle_watch_event needs, pointed at the
  # mock Ollama and the temp dir as the only watched path.
  private def harness(port : Int32, backend = "auto")
    config = MnemodocServer::Config.from_yaml(
      "db:\n  path: #{tmp_db}\npaths:\n  - #{tmp_dir}\nollama:\n  host: http://127.0.0.1:#{port}\n  model: test\n" \
      "server:\n  daemon_watch_backend: #{backend}\n  daemon_watch_interval: 1"
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
          Watch::Event.new(path, Watch::Event::Kind::Added),
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
        MnemodocServer.handle_watch_event(Watch::Event.new(path, Watch::Event::Kind::Added),
          h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])
        File.delete(path)
        MnemodocServer.handle_watch_event(Watch::Event.new(path, Watch::Event::Kind::Deleted),
          h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])
        expect(h[:store].list_files.map(&.path)).not_to contain(path)
      ensure
        h[:store].close
        h[:embedder].close
      end
    end
  end

  # A directory moved out of the tree arrives as one deleted event on the
  # directory itself: nothing reports the files it held.
  it "removes every indexed file under a deleted directory, and nothing beside it" do
    with_mock_ollama do |port|
      h = harness(port)
      begin
        inside = File.join(tmp_dir, "chapter", "one.md")
        nested = File.join(tmp_dir, "chapter", "part", "two.md")
        sibling = File.join(tmp_dir, "chapter-old", "three.md")
        [inside, nested, sibling].each do |path|
          Dir.mkdir_p(File.dirname(path))
          File.write(path, "# Title\n\n## S\n\nbody")
          MnemodocServer.handle_watch_event(
            Watch::Event.new(path, Watch::Event::Kind::Added),
            h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])
        end
        FileUtils.rm_rf(File.join(tmp_dir, "chapter"))

        MnemodocServer.handle_watch_event(
          Watch::Event.new(File.join(tmp_dir, "chapter"), Watch::Event::Kind::Deleted),
          h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])

        expect(h[:store].list_files.map(&.path)).to eq([sibling])
      ensure
        h[:store].close
        h[:embedder].close
      end
    end
  end

  # Collects what the server logs while the block runs.
  private def capture_logs(&) : Array(String)
    backend = Log::MemoryBackend.new
    Log.builder.bind("*", :info, backend)
    begin
      yield
    ensure
      Log.builder.unbind("*", :info, backend)
    end
    backend.entries.map(&.message)
  end

  # The audit log said "removed" for every deleted path the filter let
  # through — a never-indexed file, a directory holding nothing indexed —
  # so a branch switch filled it with removals that never happened.
  it "logs a removal only for a file the index actually held" do
    with_mock_ollama do |port|
      h = harness(port)
      begin
        kept = File.join(tmp_dir, "kept.md")
        File.write(kept, "# Kept\n\n## S\n\nbody")
        MnemodocServer.handle_watch_event(
          Watch::Event.new(kept, Watch::Event::Kind::Added),
          h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])
        File.delete(kept)

        messages = capture_logs do
          [File.join(tmp_dir, "never.md"), File.join(tmp_dir, "empty-dir"), kept].each do |path|
            MnemodocServer.handle_watch_event(
              Watch::Event.new(path, Watch::Event::Kind::Deleted),
              h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])
          end
        end

        expect(messages.select(&.starts_with?("watch: removed"))).to eq(["watch: removed #{kept}"])
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
      expect(MnemodocServer.index_artifact?(File.join(File.dirname(tmp_db), "daemon.instance.lock"), config)).to be_true
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
          MnemodocServer.handle_watch_event(Watch::Event.new(path, Watch::Event::Kind::Added),
            h[:config], h[:store], nil, h[:registry], h[:embedder], h[:sf])

          MnemodocServer.handle_watch_event(
            Watch::Event.new("#{tmp_db}-wal", Watch::Event::Kind::Deleted),
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
        MnemodocServer.handle_watch_event(Watch::Event.new(path, Watch::Event::Kind::Added),
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
  it "returns within 1 s of its stop signal being closed, with no file event" do
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
        indexed = false
        # The file is (re)written on every turn, not once before the loop.
        # The watcher snapshots the directory when it starts, and under the
        # multi-threaded scheduler that can happen AFTER the first write — the
        # file then belongs to the initial snapshot and never raises an event.
        # Rewriting moves its mtime, which is a change whenever the watcher
        # looks. Production does not have this problem: the daemon's boot crawl
        # is what covers files that already existed.
        20.times do
          File.write(path, "# Live\n\n## S\n\nbody #{Random::Secure.hex(2)}")
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

  # Writes *path* until the store lists it, or gives up after *attempts* turns.
  private def indexed_within?(store, path : String, attempts = 12) : Bool
    attempts.times do
      File.write(path, "# Live\n\n## S\n\nbody #{Random::Secure.hex(2)}")
      sleep 0.5.seconds
      return true if store.list_files.map(&.path).includes?(path)
    end
    false
  end

  it "returns within 1 s of its stop signal while a change is pending and Ollama hangs" do
    hanging = HTTP::Server.new { |_ctx| sleep }
    addr = hanging.bind_tcp("127.0.0.1", 0)
    spawn { hanging.listen }
    Fiber.yield
    h = harness(addr.port)
    stop = Channel(Nil).new
    done = Channel(Nil).new
    begin
      spawn do
        MnemodocServer.watch_and_index(h[:config], h[:store], nil, stop: stop)
        done.send(nil)
      end
      sleep 500.milliseconds
      File.write(File.join(tmp_dir, "pending.md"), "# Pending\n\n## S\n\nbody")
      sleep 100.milliseconds
      expect(wind_down(stop, done)).to be_true
    ensure
      hanging.close
      h[:store].close
      h[:embedder].close
    end
  end

  # A backend whose run returns though nobody asked it to stop.
  class ReturningBackend < Watch::Backend
    getter runs = 0

    def run(stop : Channel(Nil), &_block : Watch::Event ->) : Nil
      @runs += 1
    end
  end

  it "restarts a backend that returned on its own after a pause, not in a tight loop" do
    with_mock_ollama do |port|
      h = harness(port, backend: "native")
      stop = Channel(Nil).new
      done = Channel(Nil).new
      backend = ReturningBackend.new
      native = ->(_filter : Watch::Filter) { backend.as(Watch::Backend) }
      begin
        spawn do
          MnemodocServer.watch_and_index(h[:config], h[:store], nil, stop: stop, native: native)
          done.send(nil)
        end
        sleep 1500.milliseconds
        expect(backend.runs).to be <= 3
      ensure
        wind_down(stop, done)
        h[:store].close
        h[:embedder].close
      end
    end
  end

  describe "backend selection" do
    before_each { MnemodocServer::Advisories.clear }
    after_each { MnemodocServer::Advisories.clear }

    it "falls back to polling with an advisory when auto's native backend is unavailable" do
      with_mock_ollama do |port|
        h = harness(port, backend: "auto")
        stop = Channel(Nil).new
        done = Channel(Nil).new
        native = ->(_filter : Watch::Filter) { RefusedBackend.new.as(Watch::Backend) }
        begin
          spawn do
            MnemodocServer.watch_and_index(h[:config], h[:store], nil, stop: stop, native: native)
            done.send(nil)
          end
          Fiber.yield
          expect(indexed_within?(h[:store], File.join(tmp_dir, "polled.md"))).to be_true
          expect(MnemodocServer::Advisories.all.join).to match(/native file events unavailable.*polling/)
        ensure
          wind_down(stop, done)
          h[:store].close
          h[:embedder].close
        end
      end
    end

    it "runs without a live watch, and never polls, when native is unavailable" do
      with_mock_ollama do |port|
        h = harness(port, backend: "native")
        stop = Channel(Nil).new
        done = Channel(Nil).new
        native = ->(_filter : Watch::Filter) { RefusedBackend.new.as(Watch::Backend) }
        begin
          spawn do
            MnemodocServer.watch_and_index(h[:config], h[:store], nil, stop: stop, native: native)
            done.send(nil)
          end
          returned = select
          when done.receive
            true
          when timeout(2.seconds)
            false
          end
          expect(returned).to be_true
          expect(MnemodocServer::Advisories.all.join).to match(/no live re-index/)
          expect(indexed_within?(h[:store], File.join(tmp_dir, "unseen.md"), attempts: 5)).to be_false
        ensure
          stop.close rescue nil
          h[:store].close
          h[:embedder].close
        end
      end
    end

    it "never starts a native backend under poll" do
      with_mock_ollama do |port|
        h = harness(port, backend: "poll")
        stop = Channel(Nil).new
        done = Channel(Nil).new
        started = false
        native = ->(_filter : Watch::Filter) do
          started = true
          RefusedBackend.new.as(Watch::Backend)
        end
        begin
          spawn do
            MnemodocServer.watch_and_index(h[:config], h[:store], nil, stop: stop, native: native)
            done.send(nil)
          end
          Fiber.yield
          expect(indexed_within?(h[:store], File.join(tmp_dir, "polled.md"))).to be_true
          expect(started).to be_false
          expect(MnemodocServer::Advisories.all).to be_empty
        ensure
          wind_down(stop, done)
          h[:store].close
          h[:embedder].close
        end
      end
    end
  end
end
