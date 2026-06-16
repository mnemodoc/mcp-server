module MnemodocServer
  # Deduplicates concurrent work sharing the same key: the first caller (the
  # leader) runs the block while any concurrent callers for the same key wait
  # and return once the leader finishes. Prevents redundant work such as
  # indexing the same file from two overlapping requests.
  class SingleFlight
    def initialize
      @mutex = Mutex.new
      @inflight = {} of String => Channel(Nil)
    end

    # Runs the block if no other fiber is currently running work for `key`,
    # otherwise blocks until the in-flight leader completes.
    def run(key : String, &) : Nil
      # Atomically claim leadership for this key or grab the existing channel
      channel, leader = @mutex.synchronize do
        if existing = @inflight[key]?
          {existing, false}
        else
          ch = Channel(Nil).new
          @inflight[key] = ch
          {ch, true}
        end
      end

      if leader
        begin
          yield
        ensure
          # Remove the key before unblocking waiters so a later call for the
          # same key starts a fresh leader rather than a closed channel
          @mutex.synchronize { @inflight.delete(key) }
          channel.close
        end
      else
        # Wait until the leader closes the channel
        channel.receive?
      end
    end
  end
end
