module MnemodocServer
  module Watch
    # Raised by a native backend that cannot start or keep running — the
    # kernel refused a watch, the event stream did not start. Defined on every
    # platform, so the code choosing a backend can rescue it without knowing
    # which one it got.
    class Unavailable < Exception
    end

    # A source of file events for the configured roots. `run` blocks until
    # *stop* is closed, and must notice that within about a second even when no
    # file changes: the daemon's teardown waits on it before closing the index.
    abstract class Backend
      abstract def run(stop : Channel(Nil), &block : Event ->) : Nil
    end
  end
end
