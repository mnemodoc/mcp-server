require "./spec_helper"
require "http/client"
require "socket"
require "file_utils"

# Drives MnemodocServer::DaemonProxy. Two paths are exercised:
#   1. Against an already-running in-process Daemon (forward round-trip and
#      notification suppression) — the proxy must take the "already healthy"
#      bootstrap branch and never spawn.
#   2. Auto-spawn end to end via the built binary as a subprocess, proving the
#      proxy bootstraps the daemon, forwards, and gets answers.
# Each example uses a temp directory with no `paths:` so background indexing
# is a no-op (the crawler finds nothing to embed and never contacts Ollama).
Spectator.describe MnemodocServer::DaemonProxy do
  # Unique temp root per example run.
  let(tmp_dir) { "/tmp/mnemodoc-proxy-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }

  # Path to the dev binary, resolved relative to this spec file (mirrors
  # cli_context_spec); produced by `mise dev:build`.
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }

  # In-process config: explicit db path under tmp_dir, no paths, short idle
  # timeout so any spawned daemon self-reaps fast.
  let(config) do
    db = File.join(tmp_dir, "index.db")
    MnemodocServer::Config.from_yaml(<<-YAML)
    paths:
      - #{tmp_dir}
    db:
      path: #{db}
    server:
      log_level: error
      daemon_idle_timeout: 2
    YAML
  end

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # A request id reused across the idempotent_rewrite unit tests.
  let(req_id) { JSON::Any.new(42_i64) }

  # A parsed delete_file tools/call request targeting doc/gone.md.
  let(delete_request) do
    JSON.parse(
      %({"jsonrpc":"2.0","id":42,"method":"tools/call",) +
      %("params":{"name":"delete_file","arguments":{"path":"doc/gone.md"}}})
    )
  end

  # A JSON-RPC error body whose message contains "not found in index".
  let(not_found_error) do
    %({"jsonrpc":"2.0","id":42,"error":{"code":-32000,) +
      %("message":"file doc/gone.md not found in index"}})
  end

  # Starts a Daemon in a fiber bound to config.daemon_socket_path and waits
  # until the transport signals ready (mirrors spec/daemon_spec.cr).
  private def start_daemon(cfg : MnemodocServer::Config) : MnemodocServer::Daemon
    daemon = MnemodocServer::Daemon.new(cfg)
    ready = Channel(Nil).new(1)
    spawn { daemon.run_with_ready_channel(ready) }
    select
    when ready.receive
      # Transport bound and listening.
    when timeout(5.seconds)
      daemon.stop
      raise "daemon did not start within 5 seconds"
    end
    daemon
  end

  # Writes a minimal config file so the subprocess resolves the same temp paths.
  private def write_config
    db = File.join(tmp_dir, "index.db")
    File.write(config_path, <<-YAML)
    db:
      path: #{db}
    server:
      log_level: error
      daemon_idle_timeout: 2
    YAML
  end

  describe "#run (forward round-trip against a running daemon)" do
    it "forwards initialize and status over the socket without spawning" do
      daemon = start_daemon(config)

      begin
        proxy = MnemodocServer::DaemonProxy.new(config, config_path)
        input = IO::Memory.new(
          %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n) +
          %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}}\n)
        )
        output = IO::Memory.new
        proxy.run(input: input, output: output)

        lines = output.to_s.lines.reject(&.blank?)
        expect(lines.size).to eq(2)

        init_resp = JSON.parse(lines[0])
        expect(init_resp["result"]["protocolVersion"].as_s).not_to be_empty

        status_resp = JSON.parse(lines[1])
        sc = status_resp.dig("result", "structuredContent")
        expect(sc["status"].as_s).to eq("ok")
      ensure
        daemon.stop
        sleep 200.milliseconds
      end
    end
  end

  describe "#run (notification suppression)" do
    it "writes nothing for a notification but answers the following request" do
      daemon = start_daemon(config)

      begin
        proxy = MnemodocServer::DaemonProxy.new(config, config_path)
        input = IO::Memory.new(
          %({"jsonrpc":"2.0","method":"notifications/initialized"}\n) +
          %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"status","arguments":{}}}\n)
        )
        output = IO::Memory.new
        proxy.run(input: input, output: output)

        lines = output.to_s.lines.reject(&.blank?)
        # Only the request-with-id produced output; the notification did not.
        expect(lines.size).to eq(1)
        resp = JSON.parse(lines[0])
        expect(resp["id"].as_i).to eq(7)
      ensure
        daemon.stop
        sleep 200.milliseconds
      end
    end
  end

  describe "auto-spawn end to end (subprocess)" do
    it "spawns the daemon, forwards requests, and returns valid responses" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_config

      input = IO::Memory.new(
        %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n) +
        %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}}\n)
      )
      output = IO::Memory.new
      error = IO::Memory.new

      status = Process.run(
        binary,
        ["serve", "--stdio", "--config", config_path],
        input: input,
        output: output,
        error: error
      )

      expect(status.success?).to be_true
      lines = output.to_s.lines.reject(&.blank?)
      expect(lines.size).to be >= 2

      init_resp = JSON.parse(lines[0])
      expect(init_resp["result"]["protocolVersion"].as_s).not_to be_empty

      status_resp = JSON.parse(lines[1])
      sc = status_resp.dig("result", "structuredContent")
      expect(sc["status"].as_s).to eq("ok")

      # The spawned daemon self-exits via the short idle timeout (2s); give it
      # a moment so its socket is gone before after_each wipes tmp_dir.
      sleep 3.seconds
    end
  end

  describe "#idempotent_rewrite" do
    let(proxy) { MnemodocServer::DaemonProxy.new(config, config_path) }

    it "leaves a first-attempt delete not-found error unchanged" do
      result = proxy.idempotent_rewrite(
        request: delete_request,
        response_body: not_found_error,
        attempt: 1
      )
      expect(result).to eq(not_found_error)
    end

    it "rewrites a replayed delete not-found error into a success carrying id and path" do
      result = proxy.idempotent_rewrite(
        request: delete_request,
        response_body: not_found_error,
        attempt: 2
      )
      parsed = JSON.parse(result)
      expect(parsed["id"].as_i).to eq(42)
      expect(parsed.dig("result", "structuredContent", "deleted").as_s).to eq("doc/gone.md")
      expect(parsed.dig("result", "content", 0, "text").as_s).to eq("deleted (idempotent replay)")
    end

    it "leaves a replayed NON-delete error unchanged" do
      query_request = JSON.parse(
        %({"jsonrpc":"2.0","id":42,"method":"tools/call",) +
        %("params":{"name":"query_documents","arguments":{"query":"x"}}})
      )
      query_error = %({"jsonrpc":"2.0","id":42,"error":{"code":-32000,"message":"not found in index"}})
      result = proxy.idempotent_rewrite(
        request: query_request,
        response_body: query_error,
        attempt: 2
      )
      expect(result).to eq(query_error)
    end

    it "leaves a replayed delete SUCCESS body unchanged" do
      success = %({"jsonrpc":"2.0","id":42,"result":{"content":[{"type":"text","text":"deleted"}]}})
      result = proxy.idempotent_rewrite(
        request: delete_request,
        response_body: success,
        attempt: 2
      )
      expect(result).to eq(success)
    end
  end

  describe "mid-session resurrection (subprocess + kill)" do
    it "respawns the dead daemon and still answers the next request" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      skip "pkill is unavailable" unless Process.find_executable("pkill")
      write_config

      # Drive the proxy as a long-lived subprocess so we can interleave writes to
      # its stdin and kill its child daemon between requests. A pipe pair gives us
      # control over framing and lets us close stdin to end the session.
      stdin_r, stdin_w = IO.pipe
      stdout_r, stdout_w = IO.pipe

      process = Process.new(
        binary,
        ["serve", "--stdio", "--config", config_path],
        input: stdin_r,
        output: stdout_w,
        error: Process::Redirect::Inherit
      )
      # The child inherited the read/write ends; close our copies of them.
      stdin_r.close
      stdout_w.close

      # Reads one non-blank JSON line from the proxy, bounding the wait so a hung
      # proxy cannot hang the suite. Runs the blocking gets in a fiber and races
      # it against a timeout.
      read_line = ->(deadline : Time::Span) do
        chan = Channel(String?).new(1)
        spawn do
          loop do
            line = stdout_r.gets
            if line.nil?
              chan.send(nil)
              break
            end
            stripped = line.strip
            next if stripped.empty?
            chan.send(stripped)
            break
          end
        end
        select
        when value = chan.receive
          value
        when timeout(deadline)
          nil
        end
      end

      begin
        # 1. initialize + status: proves the daemon is up and answering.
        stdin_w.puts(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}))
        stdin_w.flush
        init_line = read_line.call(20.seconds)
        expect(init_line).not_to be_nil

        stdin_w.puts(%({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}}))
        stdin_w.flush
        status_line = read_line.call(20.seconds)
        expect(status_line).not_to be_nil
        first = JSON.parse(status_line || "{}")
        expect(first.dig("result", "structuredContent", "status").as_s).to eq("ok")

        # 2. Kill the spawned daemon out from under the proxy.
        Process.run("pkill", ["-f", "serve --daemon --config #{config_path}"])
        # Let the OS tear down the listening socket so the next connect fails.
        sleep 500.milliseconds

        # 3. Another status: the proxy must detect the dead connection, respawn
        # the daemon under the flock, replay the request, and still answer "ok".
        stdin_w.puts(%({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{}}}))
        stdin_w.flush
        healed_line = read_line.call(40.seconds)
        expect(healed_line).not_to be_nil
        healed = JSON.parse(healed_line || "{}")
        expect(healed.dig("result", "structuredContent", "status").as_s).to eq("ok")
      ensure
        stdin_w.close
        stdout_r.close
        # Bound the wait on the proxy exiting so a wedged process cannot hang us.
        wait_chan = Channel(Nil).new(1)
        spawn do
          process.wait
          wait_chan.send(nil)
        end
        select
        when wait_chan.receive
        when timeout(10.seconds)
          process.terminate rescue nil
        end
        Process.run("pkill", ["-f", "serve --daemon --config #{config_path}"])
      end
    end
  end

  describe "exhausted healing → in-process standalone fallback" do
    # Test seam: a proxy that bootstraps fine (so #run enters the forward loop)
    # but whose every socket send fails — `post` always raises a connection
    # error. `ensure_daemon` is stubbed to report success instantly so the
    # heal-and-retry loop neither blocks on the 30s ready-wait nor escapes the
    # mid-session path into the startup fallback; after MAX_ATTEMPTS the proxy
    # falls into the in-process standalone fallback. This exercises exactly the
    # exhausted-healing transition without any real daemon or network.
    class DeadDaemonProxy < MnemodocServer::DaemonProxy
      private def ensure_daemon : Bool
        true
      end

      # post always fails to connect — the (pretend) daemon never answers.
      private def post(body : String) : String
        raise Socket::Error.new("connection refused (test seam)")
      end
    end

    it "answers status through the in-process fallback without indexing" do
      proxy = DeadDaemonProxy.new(config, config_path)
      input = IO::Memory.new(
        %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status","arguments":{}}}\n)
      )
      output = IO::Memory.new

      # Bound the whole run so a healing loop that fails to terminate cannot hang.
      done = Channel(Nil).new(1)
      spawn do
        proxy.run(input: input, output: output)
        done.send(nil)
      end
      select
      when done.receive
      when timeout(20.seconds)
        raise "proxy.run did not complete within 20 seconds"
      end

      lines = output.to_s.lines.reject(&.blank?)
      expect(lines.size).to eq(1)
      resp = JSON.parse(lines[0])
      sc = resp.dig("result", "structuredContent")
      expect(sc["status"].as_s).to eq("ok")
      # The fallback serves the existing (empty) index and never indexed: with
      # no chunks, the status reports zero — proof background_index did not run.
      expect(sc["chunk_count"].as_i).to eq(0)
    end
  end
end
