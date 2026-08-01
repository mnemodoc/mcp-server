module MnemodocServer
  module Usage
    # Gets one event to the daemon, or to disk when the daemon is not there.
    #
    # Everything here is shaped by one constraint: the prompt hook calls it
    # before every user message, under a standing rule of "fail silently, exit
    # 0". So the socket write is bounded, no acknowledgement is awaited, and
    # every failure degrades one step further rather than raising.
    module Transport
      Log = ::Log.for("mnemodoc-server.usage.transport")

      # Bounds the write, not the connect: a UNIX connect either fails at once
      # or succeeds, unless the daemon's accept backlog is saturated. The daemon
      # closes each connection as soon as it has the line, so the backlog
      # drains; that residual case is the one bound we do not have.
      SEND_TIMEOUT = 100.milliseconds

      # Returns :socket when the daemon took it, :spooled when it went to disk,
      # :dropped when neither worked. Never raises.
      def self.send(config : Config, event : UsageEvent) : Symbol
        line = event.to_json
        return :socket if send_to_socket(config.usage_socket_path, line)
        return :spooled if spool(config.usage_spool_path, line)
        Log.debug { "usage event dropped: neither socket nor spool accepted it" }
        :dropped
      end

      # Writes the line and closes without reading: the daemon sends no reply,
      # which is what makes this fire-and-forget rather than a request.
      private def self.send_to_socket(path : String, line : String) : Bool
        return false unless File.exists?(path)
        socket = UNIXSocket.new(path)
        begin
          socket.write_timeout = SEND_TIMEOUT
          socket.puts(line)
          socket.flush
          true
        ensure
          socket.close rescue nil
        end
      rescue ex
        Log.debug { "usage socket send failed, spooling instead: #{ex.message}" }
        false
      end

      # One line appended under O_APPEND, so concurrent producers cannot
      # overwrite one another's records.
      private def self.spool(path : String, line : String) : Bool
        File.open(path, "a") do |file|
          file.puts(line)
          file.flush
        end
        true
      rescue ex
        Log.debug { "usage spool write failed: #{ex.message}" }
        false
      end
    end
  end
end
