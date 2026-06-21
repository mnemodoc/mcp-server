require "http/client"
require "socket"
require "wait_group"

module MnemodocServer
  # Default `serve --stdio` entry point when `server.daemon` is enabled.
  #
  # The proxy bootstraps (or auto-spawns) the per-project daemon, then forwards
  # each newline-delimited JSON-RPC request from stdin to the daemon over its
  # UNIX socket and writes the reply back to stdout. It mirrors MCP::Stdio's
  # concurrency model: a bounded semaphore, a WaitGroup, and a stdout write
  # mutex so concurrent replies never interleave.
  #
  # Scope: happy path, a startup fallback to the standalone stdio server when
  # bootstrap fails entirely, plus a resilience layer (this lot) that survives
  # the daemon dying mid-session — self-healing re-spawn under the flock,
  # idempotent request replay, and a lazy in-process standalone fallback once
  # healing is exhausted.
  class DaemonProxy
    Log = ::Log.for("mnemodoc-server.daemon-proxy")

    # Upper bound on concurrently in-flight forwarded requests; mirrors
    # MCP::Stdio::MAX_CONCURRENT.
    MAX_CONCURRENT = 32

    # Maximum number of times a single request is sent before the proxy gives up
    # on the daemon and switches the whole remaining session to the in-process
    # standalone fallback. One initial attempt plus two heal-and-replay retries.
    MAX_ATTEMPTS = 3

    # Seconds to wait for a freshly spawned daemon to answer /health.
    SPAWN_DEADLINE = 30.seconds

    # Interval between /health polls while awaiting a spawned daemon.
    POLL_INTERVAL = 100.milliseconds

    # Builds a proxy for the given project configuration. *config_path* is the
    # `--config` path, passed through to the spawned daemon so it loads the very
    # same configuration as this proxy.
    def initialize(@config : Config, @config_path : String)
      @write_mutex = Mutex.new
      @wait_group = WaitGroup.new
      @semaphore = Channel(Nil).new(MAX_CONCURRENT)
      # Guards lazy construction of the in-process standalone fallback so that
      # multiple fibers hitting heal-exhaustion at once build it exactly once.
      @fallback_mutex = Mutex.new
      @fallback_handler = nil.as(MCP::Handler?)
      @fallback_store = nil.as(Store::SQLite?)
      @fallback_embedder = nil.as(Indexer::Embedder?)
    end

    # Bootstraps the daemon, then forwards stdin↔socket until EOF. If bootstrap
    # fails, falls back to the standalone stdio server for the whole session.
    # Each non-empty line is dispatched in a fiber (capped by the semaphore);
    # after EOF, blocks until all in-flight forwards drain.
    def run(input : IO = STDIN, output : IO = STDOUT) : Nil
      unless ensure_daemon
        Log.warn { "daemon bootstrap failed; falling back to standalone stdio server" }
        MnemodocServer.serve_stdio(@config)
        return
      end

      input.each_line do |line|
        stripped = line.strip
        next if stripped.empty?
        @semaphore.send(nil)
        @wait_group.add(1)
        spawn do
          begin
            forward(stripped, output)
          ensure
            @wait_group.done
            @semaphore.receive
          end
        end
      end
    ensure
      @wait_group.wait
      @fallback_embedder.try(&.close)
      @fallback_store.try(&.close)
    end

    # Forwards a single JSON-RPC line to the daemon and writes the reply to
    # *output* under the write mutex — but only for requests (those carrying an
    # `id`). Notifications (no `id`) yield the daemon's empty-ack, which must not
    # reach the client, matching MCP::Stdio's behaviour. A line that fails to
    # parse is still POSTed (treated as having an id) so the daemon's JSON-RPC
    # parse error reaches the client.
    #
    # Once the session has fallen back to the in-process standalone handler
    # (heal-exhaustion), every line is served locally instead of over the socket.
    private def forward(line : String, output : IO) : Nil
      has_id =
        begin
          JSON.parse(line).as_h?.try(&.has_key?("id")) || false
        rescue JSON::ParseException
          true
        end

      if handler = @fallback_handler
        forward_standalone(line: line, has_id: has_id, handler: handler, output: output)
        return
      end

      body = send_resilient(line)
      return unless has_id
      @write_mutex.synchronize do
        output.puts(body)
        output.flush
      end
    end

    # Sends *line* to the daemon with bounded self-healing retries and returns
    # the (possibly rewritten) response body.
    #
    # Death-detection rule: the daemon is considered dead ONLY when a connection
    # attempt fails (IO::Error / Socket::Error — ECONNREFUSED / ECONNRESET /
    # EPIPE / connect failures). A missing `daemon.sock` is NOT proof of death:
    # a `kill -9` leaves a ghost socket file behind, while an idle-shutdown
    # removes it deliberately. `post`/`healthy?` are already connection-based, so
    # we never inspect the socket file here — we only react to failed sends.
    #
    # On each connection failure we call `ensure_daemon`, which flock-serialises
    # re-test → stale-socket removal → respawn → ready-wait, so concurrent fibers
    # never double-spawn. After MAX_ATTEMPTS failures the whole remaining session
    # switches to the in-process standalone fallback (built once, lazily) and
    # this request is served through it.
    private def send_resilient(line : String) : String
      request =
        begin
          JSON.parse(line)
        rescue JSON::ParseException
          nil
        end

      attempt = 1
      loop do
        begin
          body = post(line)
          # Idempotent replay rewrite only applies to parseable requests; an
          # unparseable line carries no semantics to rewrite.
          return request ? idempotent_rewrite(request: request, response_body: body, attempt: attempt) : body
        rescue ex : IO::Error | Socket::Error
          Log.warn { "daemon connection failed on attempt #{attempt}/#{MAX_ATTEMPTS}: #{ex.message}" }
          if attempt >= MAX_ATTEMPTS
            Log.warn { "healing exhausted; switching session to in-process standalone fallback" }
            return serve_via_fallback(line)
          end
          ensure_daemon
          attempt += 1
        end
      end
    end

    # Routes one line through the lazily-built in-process standalone handler and
    # writes the reply under the same write mutex, honouring the same
    # notification rule: `Handler#handle` returns nil for notifications, so we
    # write only a non-nil result (and only when the request carries an id).
    private def forward_standalone(line : String, has_id : Bool, handler : MCP::Handler, output : IO) : Nil
      result = handler.handle(JSON.parse(line))
      return unless has_id
      return unless result
      @write_mutex.synchronize do
        output.puts(result.to_json)
        output.flush
      end
    rescue ex
      Log.error { "standalone fallback failed to handle request: #{ex.message}" }
    end

    # Serves one line through the in-process standalone handler, building the
    # fallback stack first if needed. Returns the JSON-RPC body as a string so
    # `send_resilient`'s caller can write it like a daemon reply.
    private def serve_via_fallback(line : String) : String
      handler = ensure_fallback
      result = handler.handle(JSON.parse(line))
      result ? result.to_json : ""
    end

    # POSTs *body* to the daemon's /mcp endpoint over a fresh UNIX socket and
    # returns the response body. The socket is always closed. Connection errors
    # may propagate here (a later lot wraps this with retry/fallback).
    private def post(body : String) : String
      socket = UNIXSocket.new(@config.daemon_socket_path)
      client = HTTP::Client.new(socket)
      begin
        response = client.post(
          "/mcp",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: body
        )
        response.body
      ensure
        client.close
      end
    end

    # Rewrites a daemon reply to make replayed requests idempotent. Pure: it
    # takes the parsed *request*, the daemon's *response_body*, and the 1-based
    # *attempt* number, and returns a body string — no I/O.
    #
    # The body is returned UNCHANGED except in exactly one case: a *replayed*
    # (`attempt > 1`) `tools/call` to `delete_file` whose response is a JSON-RPC
    # error mentioning "not found in index". A previous attempt may have already
    # deleted the file before the daemon died, so a replayed delete that now
    # reports "not found" is a SUCCESS, not an error — we synthesise a success
    # response carrying the original request id and the deleted path.
    #
    # Every other case (first attempt, non-delete errors, delete successes, and
    # naturally idempotent tools like query/status/list/ingest) passes through.
    #
    # Intentionally non-private (no behavioural reason) so the spec can unit-test
    # this pure inputs→string contract directly.
    def idempotent_rewrite(request : JSON::Any, response_body : String, attempt : Int32) : String
      return response_body if attempt <= 1
      return response_body unless request["method"]?.try(&.as_s?) == "tools/call"
      return response_body unless request.dig?("params", "name").try(&.as_s?) == "delete_file"

      response =
        begin
          JSON.parse(response_body)
        rescue JSON::ParseException
          return response_body
        end

      message = response.dig?("error", "message").try(&.as_s?)
      return response_body unless message && message.includes?("not found in index")

      id = request["id"]?
      path = request.dig?("params", "arguments", "path").try(&.as_s?) || "unknown"

      synthesised = {
        "jsonrpc" => JSON::Any.new("2.0"),
        "id"      => id || JSON::Any.new(nil),
        "result"  => JSON::Any.new({
          "content" => JSON::Any.new([
            JSON::Any.new({
              "type" => JSON::Any.new("text"),
              "text" => JSON::Any.new("deleted (idempotent replay)"),
            } of String => JSON::Any),
          ]),
          "structuredContent" => JSON::Any.new({
            "deleted" => JSON::Any.new(path),
          } of String => JSON::Any),
        } of String => JSON::Any),
      } of String => JSON::Any

      synthesised.to_json
    end

    # Lazily builds the in-process standalone fallback stack ONCE and returns its
    # handler. Concurrency-safe: guarded by `@fallback_mutex` with a double-check
    # inside so racing fibers share a single handler.
    #
    # The fallback opens its own `Store::SQLite`, builds the tool registry, and
    # wraps the resulting server in an `MCP::Handler`. It deliberately DOES NOT
    # run `background_index`: it serves the existing on-disk index only. Spawning
    # an indexer here would re-introduce exactly the multi-process re-index storm
    # the daemon design exists to remove (every dead-daemon proxy would start its
    # own indexer). The store/embedder are kept in ivars so `run`'s ensure closes
    # them.
    private def ensure_fallback : MCP::Handler
      @fallback_mutex.synchronize do
        if handler = @fallback_handler
          return handler
        end

        Dir.mkdir_p(File.dirname(@config.db_path))
        store = Store::SQLite.new(@config.db_path, vec0: @config.search.backend != "qdrant")
        qi = MnemodocServer.qdrant_index(@config)
        built = ToolRegistry.build(@config, store, qi)

        @fallback_store = store
        @fallback_embedder = built[:embedder]
        handler = MCP::Handler.new(built[:server])
        @fallback_handler = handler
        handler
      end
    end

    # Ensures a healthy daemon is listening on the socket, returning true on
    # success. Connects to an existing daemon when one answers /health; otherwise
    # serialises spawning behind an exclusive advisory lock so racing proxies do
    # not double-spawn, then waits until the new daemon is ready.
    private def ensure_daemon : Bool
      return true if healthy?

      Dir.mkdir_p(File.dirname(@config.daemon_lock_path))
      File.open(@config.daemon_lock_path, "w") do |lock|
        lock.flock_exclusive do
          # Another proxy may have spawned it while we waited for the lock.
          return true if healthy?
          # Drop a stale socket left behind by a hard-killed daemon.
          File.delete?(@config.daemon_socket_path)
          spawn_daemon
          await_healthy
        end
      end
    end

    # Spawns the daemon fully detached so it outlives this proxy. Its stdio is
    # closed; it communicates only over the UNIX socket.
    private def spawn_daemon : Nil
      executable = Process.executable_path || "mnemodoc-server"
      Log.info { "spawning daemon: #{executable} serve --daemon --config #{@config_path}" }
      Process.new(
        executable,
        ["serve", "--daemon", "--config", @config_path],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )
    end

    # Polls /health until the daemon answers 200 or the spawn deadline elapses.
    # Returns true on success, false on timeout.
    private def await_healthy : Bool
      deadline = Time.monotonic + SPAWN_DEADLINE
      until healthy?
        if Time.monotonic > deadline
          Log.error { "daemon did not become healthy within #{SPAWN_DEADLINE.total_seconds}s" }
          return false
        end
        sleep POLL_INTERVAL
      end
      true
    end

    # True iff the daemon answers `GET /health` with status 200 over a fresh
    # UNIX socket. Any connection error (no socket, refused, reset) is treated
    # as not-healthy.
    private def healthy? : Bool
      socket = UNIXSocket.new(@config.daemon_socket_path)
      client = HTTP::Client.new(socket)
      begin
        client.get("/health").status_code == 200
      ensure
        client.close
      end
    rescue
      false
    end
  end
end
