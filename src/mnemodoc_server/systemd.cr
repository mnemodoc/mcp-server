module MnemodocServer
  # Thin wrapper around the systemd sd_notify(3) protocol.
  # When the process is started as a systemd service with Type=notify, systemd
  # expects the process to write status messages to a UNIX datagram socket
  # whose path is given by the NOTIFY_SOCKET environment variable.
  # All public methods are no-ops when NOTIFY_SOCKET is not set, making it safe
  # to call unconditionally regardless of the execution environment.
  module SystemD
    Log = ::Log.for("mnemodoc-server.systemd")
    @@socket : UNIXSocket? = nil
    @@mutex = Mutex.new

    # Sends READY=1, telling systemd the service has finished initialising
    # and is ready to accept requests.
    def self.ready : Nil
      notify("READY=1")
    end

    # Sends STOPPING=1, telling systemd the service is beginning a clean shutdown.
    def self.stopping : Nil
      notify("STOPPING=1")
    end

    # Sends WATCHDOG=1, resetting the systemd watchdog timer.
    # Must be called at least once per watchdog interval to prevent a forced restart.
    def self.watchdog : Nil
      notify("WATCHDOG=1")
    end

    # Sends a human-readable STATUS line visible in `systemctl status` output.
    def self.status(message : String) : Nil
      notify("STATUS=#{message}")
    end

    # Returns half the WATCHDOG_USEC interval as a Time::Span, or nil if the
    # watchdog is not configured. Using half the interval gives a comfortable
    # safety margin before systemd considers the process unresponsive.
    def self.watchdog_interval : Time::Span?
      usec = ENV["WATCHDOG_USEC"]?.try(&.to_i64?)
      return nil unless usec
      (usec / 2).microseconds
    end

    # Spawns a background fiber that sends WATCHDOG=1 at the calculated interval.
    # Does nothing if WATCHDOG_USEC is not set in the environment.
    def self.start_watchdog : Nil
      interval = watchdog_interval
      return unless interval
      spawn do
        loop do
          sleep interval
          watchdog
        end
      end
    end

    # Closes and discards the cached socket. Useful in tests or after a fork
    # to ensure the next notify call opens a fresh connection.
    def self.reset_socket : Nil
      @@mutex.synchronize do
        @@socket.try(&.close) rescue nil
        @@socket = nil
      end
    end

    # Sends payload to the NOTIFY_SOCKET if set. The socket is lazily created
    # and cached; on send failure it is discarded so the next call reopens it.
    private def self.notify(payload : String) : Nil
      socket_path = ENV["NOTIFY_SOCKET"]?
      return unless socket_path
      @@mutex.synchronize do
        sock = @@socket ||= open_socket(socket_path)
        begin
          sock.send(payload)
        rescue
          @@socket = nil
        end
      end
    end

    # Opens a UNIX DGRAM socket at path. An "@" prefix is the Linux abstract
    # namespace convention; it is translated to a NUL-byte prefix.
    private def self.open_socket(path : String) : UNIXSocket
      path = "\0" + path[1..] if path.starts_with?("@")
      UNIXSocket.new(path, type: Socket::Type::DGRAM)
    end
  end
end
