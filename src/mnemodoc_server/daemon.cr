module MnemodocServer
  # Per-project daemon: owns the single SQLite index for a project, starts
  # background indexing, and serves MCP over a UNIX domain socket until idle.
  # Launched by `serve --daemon`; the proxy (lot 5) connects to the socket.
  #
  # Future extension point: the file-watcher will attach here to trigger
  # incremental re-indexing when source files change (not implemented yet).
  class Daemon
    # Builds a daemon for the given project configuration.
    def initialize(@config : Config)
    end

    # Accessor that lets tests stop the daemon without sending a real signal.
    # Nil until #run binds the transport.
    getter transport : MCP::Http? = nil

    # Opens the project store, spawns background indexing, binds the UNIX
    # socket transport, wires SystemD + signal callbacks, and blocks until
    # the transport stops (idle timeout or SIGTERM).
    # Does NOT close the log file — the CLI entry point owns that lifecycle.
    def run : Nil
      run_internal(ready_channel: nil)
    end

    # Test seam: identical to #run but sends nil on *ready_channel* once the
    # transport is bound and listening. Callers use this to await readiness
    # without polling the socket file (which fails for the stale-socket test
    # because the file exists before the daemon starts). Minimal surface area:
    # the production path never calls this method.
    def run_with_ready_channel(ready_channel : Channel(Nil)) : Nil
      run_internal(ready_channel: ready_channel)
    end

    # Stops the daemon by stopping its transport. No-op when the transport has
    # not been bound yet. Intended for use in tests and for orderly shutdown.
    def stop : Nil
      @transport.try(&.stop)
    end

    # Shared implementation for #run and #run_with_ready_channel. The optional
    # *ready_channel* is sent nil exactly once when the transport is ready;
    # when nil, only the SystemD.ready notification is issued (production path).
    private def run_internal(ready_channel : Channel(Nil)?) : Nil
      store : Store::SQLite? = nil        # ameba:disable Lint/UselessAssign
      embedder : Indexer::Embedder? = nil # ameba:disable Lint/UselessAssign

      # Ensure the socket's parent directory (= the index directory) exists
      # before MCP::Http tries to bind.
      Dir.mkdir_p(File.dirname(@config.daemon_socket_path))

      store = Store::SQLite.new(
        @config.db_path,
        vec0: @config.search.backend != "qdrant"
      )
      # Non-nil binding captured by the background fiber closure.
      active_store = store

      qi = MnemodocServer.qdrant_index(@config)

      built = ToolRegistry.build(@config, active_store, qi)
      server = built[:server]
      embedder = built[:embedder]

      # Index configured paths in the background so the daemon is immediately
      # responsive; unchanged files are skipped via mtime so restarts are cheap.
      spawn { MnemodocServer.background_index(@config, active_store, qi) }

      # Live re-index: watch the configured paths and pick up changes while the
      # daemon runs. Dies with the process on shutdown (holds no external resource).
      if @config.server.daemon_watch?
        spawn { MnemodocServer.watch_and_index(@config, active_store, qi) }
      end

      t = MCP::Http.new(
        server,
        socket_path: @config.daemon_socket_path,
        idle_timeout: @config.server.daemon_idle_timeout.seconds
      )
      @transport = t

      t.on_ready do
        SystemD.ready
        ready_channel.try(&.send(nil))
      end
      t.on_stopping { SystemD.stopping }
      Signal::TERM.trap { t.stop }
      Signal::USR1.trap { MnemodocServer.reopen_log_file! }

      t.start
    ensure
      embedder.try(&.close)
      store.try(&.close)
    end
  end
end
