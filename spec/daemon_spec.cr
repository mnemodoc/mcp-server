require "./spec_helper"
require "http/client"
require "socket"
require "file_utils"

# Drives MnemodocServer::Daemon in-process over a UNIX socket.
# Each example uses a temp directory with no `paths:` so background indexing
# is a no-op (the crawler finds nothing to embed and never contacts Ollama).
# The daemon is started in a spawned fiber; tests talk to it via HTTP::Client
# over UNIXSocket, then stop it through the exposed `#stop` accessor.
Spectator.describe MnemodocServer::Daemon do
  # Unique temp root per example run.
  let(tmp_dir) { "/tmp/mnemodoc-daemon-#{Random::Secure.hex(4)}" }

  # Build a minimal config: explicit db path under tmp_dir, no paths, short
  # idle timeout (overridden per test). The daemon_socket_path and
  # daemon_lock_path both resolve to the same directory as db_path.
  let(config) do
    db = File.join(tmp_dir, "index.db")
    MnemodocServer::Config.from_yaml(<<-YAML)
    paths:
      - #{tmp_dir}
    db:
      path: #{db}
    server:
      log_level: error
      daemon_idle_timeout: 600
    YAML
  end

  # Short-idle variant used for the idle-shutdown test.
  let(idle_config) do
    db = File.join(tmp_dir, "index.db")
    MnemodocServer::Config.from_yaml(<<-YAML)
    paths:
      - #{tmp_dir}
    db:
      path: #{db}
    server:
      log_level: error
      daemon_idle_timeout: 1
    YAML
  end

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Starts the daemon in a fiber and waits until the transport signals ready
  # (on_ready fires after the socket is bound and listen has started).
  # Uses a Channel(Exception?) so errors during startup propagate as test failures.
  # Returns the daemon so callers can call #stop.
  private def start_daemon(cfg : MnemodocServer::Config) : MnemodocServer::Daemon
    daemon = MnemodocServer::Daemon.new(cfg)
    ready = Channel(Nil).new(1)

    spawn do
      # Tap into the transport's on_ready via the post-run accessor.
      # Daemon#run sets @transport before calling t.start, so we inject
      # on_ready by patching it right before .start via a wrapper approach.
      # Instead, we wire ready via the daemon's own on_ready hook.
      daemon.run_with_ready_channel(ready)
    end

    select
    when ready.receive
      # Transport bound and listening.
    when timeout(5.seconds)
      daemon.stop
      raise "daemon did not start within 5 seconds"
    end

    daemon
  end

  # Sends a single JSON-RPC request over the UNIX socket and returns the
  # parsed response body.
  private def rpc(socket_path : String, body : String) : JSON::Any
    sock = UNIXSocket.new(socket_path)
    client = HTTP::Client.new(sock)
    response = client.post(
      "/mcp",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: body
    )
    JSON.parse(response.body)
  ensure
    sock.try(&.close)
  end

  describe "#run (round-trip)" do
    it "responds to initialize and status tools/call over the UNIX socket" do
      daemon = start_daemon(config)

      begin
        socket_path = config.daemon_socket_path

        # Step 1: MCP initialize handshake.
        init_body = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
        init_resp = rpc(socket_path, init_body)
        expect(init_resp["result"]["protocolVersion"].as_s).not_to be_empty

        # Step 2: tools/call status — no embedding required.
        status_body = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}})
        status_resp = rpc(socket_path, status_body)
        sc = status_resp.dig("result", "structuredContent")
        expect(sc["status"].as_s).to eq("ok")
      ensure
        daemon.stop
        # Allow fiber to drain.
        sleep 200.milliseconds
      end
    end
  end

  describe "#run (pid file)" do
    it "writes its pid on startup and removes the file on shutdown" do
      daemon = start_daemon(config)
      pid_path = config.daemon_pid_path

      begin
        expect(File.exists?(pid_path)).to be_true
        expect(File.read(pid_path).strip.to_i).to eq(Process.pid)
      ensure
        daemon.stop
        sleep 200.milliseconds
      end

      expect(File.exists?(pid_path)).to be_false
    end
  end

  # The pid file was cleaned up on shutdown and the usage socket was not: the
  # collector's own fiber never unwound, so a stopped daemon left the file
  # behind. Inert, and removed at the next bind, but the asymmetry hid a
  # collector that was never told to stop.
  describe "#run (usage socket)" do
    it "binds the usage socket and removes it on shutdown" do
      daemon = start_daemon(config)
      usage_path = config.usage_socket_path

      begin
        expect(File.exists?(usage_path)).to be_true
      ensure
        daemon.stop
        sleep 200.milliseconds
      end

      expect(File.exists?(usage_path)).to be_false
    end
  end

  # The teardown's whole job: run_internal spawns four fibers that query the
  # store, and closing a DB::Database under any of them is a use-after-free in
  # libsqlite3 — a SIGSEGV, not an exception, so nothing rescues it. All three
  # variants of that crash were found by CI rather than by this suite, in
  # Collector#listen, Collector#purge_expired and Crawler#prune_stale. This is
  # the guard that was missing.
  describe "#run (shutdown while the index is held)" do
    it "returns without crashing when a crawl is still holding the index" do
      Dir.mkdir_p(File.join(tmp_dir, "doc"))
      3.times do |index|
        File.write(File.join(tmp_dir, "doc", "f#{index}.md"), "# Title #{index}\n\n## Section\n\nbody text\n")
      end

      # Accepts the connection and never answers, so the boot crawl parks inside
      # its embedding call holding the store — exactly the state the teardown
      # used to close the handle in.
      hanging = HTTP::Server.new { |_ctx| sleep }
      addr = hanging.bind_tcp("127.0.0.1", 0)
      spawn { hanging.listen }
      Fiber.yield

      cfg = MnemodocServer::Config.from_yaml(<<-YAML)
      paths:
        - #{File.join(tmp_dir, "doc")}
      ollama:
        host: http://127.0.0.1:#{addr.port}
        timeout: 60
      db:
        path: #{File.join(tmp_dir, "index.db")}
      server:
        log_level: error
        daemon_idle_timeout: 600
      YAML

      daemon = MnemodocServer::Daemon.new(cfg)
      ready = Channel(Nil).new(1)
      finished = Channel(Nil).new(1)

      begin
        spawn do
          daemon.run_with_ready_channel(ready)
        ensure
          finished.send(nil)
        end

        select
        when ready.receive
          # Bound and serving.
        when timeout(10.seconds)
          fail "the daemon never became ready"
        end

        daemon.stop

        # THE discriminating assertion. Shutdown must still be in progress here,
        # because the crawl it is waiting for cannot finish while the mock hangs.
        # Without the wait, run returns at once — having closed the index under
        # a fiber that is about to use it again — and this example is the only
        # thing standing between that and a green suite.
        select
        when finished.receive
          fail "the daemon returned while a crawl still held the index"
        when timeout(500.milliseconds)
          # Still waiting, as it should be.
        end

        # Release the crawl: its embedding call fails, background_index rescues,
        # and the fiber reports itself out — which is what the teardown has been
        # waiting for.
        hanging.close

        select
        when finished.receive
          # Unwound in order.
        when timeout(30.seconds)
          fail "the daemon did not return once the crawl was released"
        end

        expect(File.exists?(cfg.daemon_pid_path)).to be_false
        expect(File.exists?(cfg.daemon_socket_path)).to be_false
      ensure
        # Idempotent: the body closes it as part of the sequence above, this
        # only covers an example that failed before reaching that point.
        hanging.close rescue nil
      end
    end
  end

  describe "#run (idle shutdown)" do
    it "stops and removes the socket file after daemon_idle_timeout seconds" do
      daemon = start_daemon(idle_config)
      socket_path = idle_config.daemon_socket_path

      # Observe run completion from outside; daemon.run was already spawned
      # inside start_daemon — we poll the socket file disappearing instead.
      deadline = Time.instant + 5.seconds
      until !File.exists?(socket_path)
        if Time.instant > deadline
          daemon.stop
          fail "daemon did not idle-shutdown within 5 seconds"
        end
        sleep 50.milliseconds
      end

      expect(File.exists?(socket_path)).to be_false
    end
  end

  describe "#run (stale socket)" do
    it "removes a pre-existing file at the socket path and binds successfully" do
      # Pre-create a stale socket file before the daemon starts.
      Dir.mkdir_p(File.dirname(config.daemon_socket_path))
      File.write(config.daemon_socket_path, "stale")

      daemon = start_daemon(config)

      begin
        # If bind succeeded the transport is live (start_daemon awaited on_ready).
        # A health check confirms the real socket is serving.
        sock = UNIXSocket.new(config.daemon_socket_path)
        client = HTTP::Client.new(sock)
        response = client.get("/health")
        expect(response.status_code).to eq(200)
        sock.close
      ensure
        daemon.stop
        sleep 200.milliseconds
      end
    end
  end

  # A socket that accepts and then says nothing is not a theoretical case: the
  # daemon does its SQLite writes through blocking C calls that never yield, so
  # during a large vec0 backfill the process holds the listening socket while
  # answering nothing. The kernel completes the connection from the backlog and
  # the client waits — with no read timeout, forever, and the MCP client that
  # spawned the proxy hangs with it, without a message.
  describe "liveness probe against an unresponsive socket" do
    it "reports not running instead of waiting forever" do
      Dir.mkdir_p(File.dirname(config.daemon_socket_path))
      server = UNIXServer.new(config.daemon_socket_path)
      accepted = [] of UNIXSocket
      spawn do
        while socket = server.accept?
          # Held open on purpose: accepted, never answered.
          accepted << socket
        end
      end
      Fiber.yield

      answer = Channel(Bool).new
      spawn { answer.send(MnemodocServer.daemon_healthy?(config)) }

      outcome = select
      when value = answer.receive
        value ? "running" : "not running"
      when timeout(15.seconds)
        "hung"
      end
      expect(outcome).to eq("not running")
    ensure
      accepted.each(&.close) if accepted
      server.close if server
      File.delete?(config.daemon_socket_path)
    end
  end
end
