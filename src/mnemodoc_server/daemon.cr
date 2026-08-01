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
      collector : Usage::Collector? = nil

      # Opening the store also prepares the index directory (= the socket's
      # parent), which MCP::Http needs to exist before it can bind.
      store = MnemodocServer.open_store(@config)
      # Non-nil binding captured by the background fiber closure.
      active_store = store

      qi = MnemodocServer.qdrant_index(@config)

      built = ToolRegistry.build(@config, active_store, qi)
      server = built[:server]
      embedder = built[:embedder]

      # One SingleFlight for both indexing paths. They were given one each,
      # which meant the deduplication it exists for did not apply between them:
      # a file saved while the boot crawl was still running got indexed twice,
      # concurrently, by the crawl and by the watcher.
      single_flight = SingleFlight.new

      # Index configured paths in the background so the daemon is immediately
      # responsive; unchanged files are skipped via mtime so restarts are cheap.
      spawn { MnemodocServer.background_index(@config, active_store, qi, single_flight) }

      # Live re-index: watch the configured paths and pick up changes while the
      # daemon runs. Dies with the process on shutdown (holds no external resource).
      if @config.server.daemon_watch?
        spawn { MnemodocServer.watch_and_index(@config, active_store, qi, sf: single_flight) }
      end

      # The usage journal's own socket, beside the MCP one. Producers that
      # cannot reach it spool to a file, which this same collector drains: the
      # import runs first so a restart picks up whatever was recorded while no
      # daemon was listening, then the retention sweep, then both on a timer.
      if @config.usage.enabled?
        active_collector = collector = Usage::Collector.new(@config, active_store)
        spawn { active_collector.listen }
        spawn do
          loop do
            active_collector.import_spool
            active_collector.purge_expired
            sleep @config.usage.import_interval.seconds
          end
        end
      end

      t = MCP::Http.new(
        server,
        socket_path: @config.daemon_socket_path,
        idle_timeout: @config.server.daemon_idle_timeout.seconds
      )
      @transport = t

      t.on_ready do
        # Written only once the socket is bound, so the file's presence means
        # "a daemon is reachable here" rather than "one is starting up".
        File.write(@config.daemon_pid_path, "#{Process.pid}\n")
        SystemD.ready
        ready_channel.try(&.send(nil))
      end
      t.on_stopping { SystemD.stopping }
      Signal::TERM.trap { t.stop }
      Signal::USR1.trap { MnemodocServer.reopen_log_file! }

      t.start
    ensure
      # Best-effort: a hard kill leaves the file behind, which is why callers
      # probe /health before trusting the pid it contains.
      File.delete?(@config.daemon_pid_path)
      # Stopped explicitly rather than left to the process exit: the listener
      # removes its socket as it unwinds, and a fiber killed with the process
      # never unwinds. Symmetrical with the pid file above.
      collector.try(&.stop)
      embedder.try(&.close)
      store.try(&.close)
    end
  end
end
