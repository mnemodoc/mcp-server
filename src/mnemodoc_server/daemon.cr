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
    # Spawns the collector's two fibers, each reporting to *done* as it unwinds.
    #
    # A separate method purely so *done* is a parameter: a channel first assigned
    # in run_internal's body reads as nilable from inside a spawned block's
    # `ensure`, and the teardown's whole correctness rests on those sends
    # happening.
    #
    # The sweep belongs to the collector now. It used to be a bare `loop` inline
    # in run_internal that consulted nothing and therefore never ended: shutdown
    # closed the store while it slept, and its next purge prepared a statement
    # on a freed sqlite3 handle. See Usage::Collector#sweep_until_stopped.
    private def spawn_collector(collector : Usage::Collector, interval : Time::Span,
                                done : Channel(Nil), ready : Channel(Nil)) : Nil
      spawn do
        collector.listen(ready)
      ensure
        done.send(nil)
        # Unblocks a startup still waiting when the listener never bound at all,
        # rather than making it serve out the full grace period for nothing.
        ready.close rescue nil
      end
      spawn do
        collector.sweep_until_stopped(interval)
      ensure
        done.send(nil)
      end
    end

    # How long the teardown waits for each collector fiber to unwind before
    # closing the store regardless. Long enough for a query to finish, short
    # enough that a wedged fiber does not hold a daemon shutdown open.
    SHUTDOWN_GRACE = 5.seconds

    # The listener and the periodic sweep.
    COLLECTOR_FIBERS = 2

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
      # Both collector fibers report here as they unwind. The teardown waits on
      # it before closing the store: setting a stopping flag is not enough on
      # its own, since a fiber can already be inside a query when it is set.
      # Declared nilable, like `store` above, because a variable first assigned
      # in the body reads as nilable from `ensure`.
      collector_done : Channel(Nil)? = nil

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
        collector_done = Channel(Nil).new(2)
        collector_ready = Channel(Nil).new(1)
        spawn_collector(active_collector, @config.usage.import_interval.seconds,
          collector_done, collector_ready)
        # The daemon is not ready until BOTH of its sockets are bound. Firing
        # on_ready off the MCP socket alone promised nothing about the usage
        # one, so a producer that sent an event immediately after startup could
        # find nothing listening and spool instead — and the spec asserting the
        # socket exists after readiness failed intermittently under the
        # multi-threaded scheduler, which is how this surfaced. Bounded, because
        # a usage socket that cannot bind must degrade the journal, not the
        # daemon: the collector logs it and producers keep spooling.
        select
        when collector_ready.receive?
          # Bound, or the listener gave up and closed the channel — either way
          # there is nothing left to wait for. receive?, not receive: the close
          # in spawn_collector's ensure would make the latter raise here, inside
          # startup, over a journal that is allowed to be unavailable.
        when timeout(SHUTDOWN_GRACE)
          Log.warn { "usage socket not bound within #{SHUTDOWN_GRACE}; serving without it" }
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
      # Waited on, not merely signalled: #stop returns as soon as the flag is
      # set and the socket is closed, while a fiber may still be inside a query.
      # Closing the store under it is a use-after-free in libsqlite3, which
      # crashes the process rather than raising. Bounded so a wedged fiber
      # delays shutdown instead of preventing it.
      if done = collector_done
        # Two, always: spawn_collector starts exactly the listener and the sweep.
        COLLECTOR_FIBERS.times do
          select
          when done.receive
            # One of them is out.
          when timeout(SHUTDOWN_GRACE)
            Log.warn { "usage collector did not unwind within #{SHUTDOWN_GRACE}; closing the store anyway" }
            break
          end
        end
      end
      embedder.try(&.close)
      store.try(&.close)
    end
  end
end
