module MnemodocServer
  module Usage
    # The daemon side of the journal: it accepts events on the usage socket,
    # imports whatever was spooled while it was not running, and purges past the
    # retention window.
    class Collector
      Log = ::Log.for("mnemodoc-server.usage.collector")

      # How long the importer waits after renaming the spool before reading it,
      # so a producer that was mid-write lands in the file we are about to read
      # rather than in the one we already read. Twice the send budget.
      IMPORT_GRACE = 200.milliseconds

      def initialize(@config : Config, @store : Store::SQLite)
        @server = nil.as(UNIXServer?)
        @stopping = false
      end

      # Binds the socket and serves until #stop. One line per connection: read
      # it, insert it, close. No reply is written — the producer is not waiting
      # for one, which is what makes the send fire-and-forget.
      def listen(ready : Channel(Nil)? = nil) : Nil
        path = @config.usage_socket_path
        # A hard kill leaves the file behind, and binding onto it fails. The
        # daemon's own socket is handled the same way.
        File.delete?(path)
        server = UNIXServer.new(path)
        @server = server
        ready.try(&.send(nil))

        while !@stopping
          client = server.accept?
          break unless client
          begin
            line = client.gets
            insert_line(line) if line
          ensure
            client.close rescue nil
          end
        end
      rescue ex
        Log.debug { "usage listener stopped: #{ex.message}" } unless @stopping
      ensure
        File.delete?(@config.usage_socket_path)
      end

      def stop : Nil
        @stopping = true
        @server.try(&.close) rescue nil
      end

      # Renames the spool, waits out in-flight writes, imports and deletes.
      #
      # The rename is what lets producers start a fresh file at once, with no
      # shared lock and therefore no way to block the prompt hook. A line
      # written into the old inode after the read is lost; that window is
      # IMPORT_GRACE, and it only affects the fallback path.
      def import_spool : Int32
        spool = @config.usage_spool_path
        return 0 unless File.file?(spool)

        staged = "#{spool}.importing"
        File.rename(spool, staged)
        sleep IMPORT_GRACE

        imported = 0
        File.each_line(staged) do |line|
          next if line.blank?
          begin
            @store.usage.insert(UsageEvent.from_json(line))
            imported += 1
          rescue ex : JSON::ParseException
            # One truncated line costs that line, not the batch: the spool is
            # written by processes that can be killed mid-write.
            Log.debug { "skipping malformed usage line: #{ex.message}" }
          end
        end
        File.delete?(staged)
        Log.info { "usage: imported #{imported} spooled events" } if imported > 0
        imported
      rescue ex
        Log.debug { "usage spool import failed: #{ex.message}" }
        0
      end

      def purge_expired : Int32
        cutoff = Time.utc.to_unix - (@config.usage.retention_days.to_i64 * 86_400)
        removed = @store.usage.purge(older_than: cutoff)
        Log.info { "usage: purged #{removed} events older than #{@config.usage.retention_days} days" } if removed > 0
        removed
      rescue ex
        Log.debug { "usage purge failed: #{ex.message}" }
        0
      end

      private def insert_line(line : String) : Nil
        @store.usage.insert(UsageEvent.from_json(line))
      rescue ex
        Log.debug { "unusable usage event on socket: #{ex.message}" }
      end
    end
  end
end
