module MnemodocServer
  module Watch
    # Folds the events of one path within a window into one, so that an editor
    # save — created, written, renamed over — costs one re-index rather than
    # three. The folded event carries the last kind seen: what the file ended
    # up as is all the indexer needs.
    #
    # Reading and delivering are two fibers. Delivery calls the indexer, which
    # can take seconds on an embedding; reading never waits for it, so the
    # backend behind *input* keeps draining — the FSEvents pipe, the inotify
    # queue — instead of filling up and dropping events.
    class Coalescer
      DEFAULT_WINDOW = 300.milliseconds

      def initialize(@window : Time::Span = DEFAULT_WINDOW)
      end

      # Delivers folded events to the block until *input* is closed, then
      # returns at once, dropping what is still pending. Closing the input is
      # the watch shutting down, and the daemon teardown waits on it: each
      # pending event would cost an embedding call bounded only by the Ollama
      # timeout. The next boot crawl picks those changes up by mtime,
      # deletions included.
      def run(input : Channel(Event), &block : Event ->) : Nil
        pending = {} of String => {Event, Time::Instant}
        mutex = Mutex.new
        wake = Channel(Nil).new(1)
        closed = Atomic(Bool).new(false)

        spawn do
          while event = input.receive?
            mutex.synchronize do
              # The window runs from the first event of a burst: a path that
              # keeps changing is still delivered, at most one window late.
              due = pending[event.path]?.try(&.[1]) || Time.instant + @window
              pending[event.path] = {event, due}
            end
            nudge(wake)
          end
        ensure
          closed.set(true)
          nudge(wake)
        end

        loop do
          break if closed.get
          ready, next_due = mutex.synchronize { take_ready(pending) }
          ready.each do |event|
            break if closed.get
            block.call(event)
          end

          wait = next_due ? next_due - Time.instant : @window
          select
          when wake.receive
          when timeout(wait.positive? ? wait : Time::Span.zero)
          end
        end
      end

      # Removes and returns the events that are due, oldest first, with the
      # earliest remaining due time.
      private def take_ready(pending : Hash(String, {Event, Time::Instant})) : {Array(Event), Time::Instant?}
        now = Time.instant
        due = pending.select { |_path, entry| entry[1] <= now }
        due.each_key { |path| pending.delete(path) }
        ready = due.values.sort_by!(&.[1]).map(&.[0])
        {ready, pending.values.min_of?(&.[1])}
      end

      # Wakes the delivery loop without ever blocking the reader: one pending
      # wake-up is as good as several.
      private def nudge(wake : Channel(Nil)) : Nil
        select
        when wake.send(nil)
        else
        end
      end
    end
  end
end
