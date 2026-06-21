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

  describe "#run (idle shutdown)" do
    it "stops and removes the socket file after daemon_idle_timeout seconds" do
      daemon = start_daemon(idle_config)
      socket_path = idle_config.daemon_socket_path

      # Observe run completion from outside; daemon.run was already spawned
      # inside start_daemon — we poll the socket file disappearing instead.
      deadline = Time.monotonic + 5.seconds
      until !File.exists?(socket_path)
        if Time.monotonic > deadline
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
end
