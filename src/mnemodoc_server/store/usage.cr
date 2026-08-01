module MnemodocServer
  module Store
    # The usage journal's reads and writes. Holds no connection of its own: it
    # is handed the store's database and write mutex, so a journal write can
    # never race an index write inside the daemon.
    class Usage
      def initialize(@db : DB::Database, @write_mutex : Mutex)
      end

      # Writes one event and its served files in a single transaction, so a
      # crash can never leave an event without the documents it served.
      def insert(event : MnemodocServer::Usage::UsageEvent) : Nil
        @write_mutex.synchronize do
          @db.transaction do |tx|
            cnn = tx.connection
            cnn.exec(
              "INSERT INTO usage_events (at, source, action, query, result_count, elapsed_ms, session, agent) " \
              "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
              event.at, event.source, event.action, event.query,
              event.result_count, event.elapsed_ms, event.session, event.agent
            )
            id = cnn.scalar("SELECT last_insert_rowid()").as(Int64)
            event.files.each do |path|
              cnn.exec("INSERT INTO usage_event_files (event_id, file_path) VALUES (?, ?)", id, path)
            end
          end
        end
      end

      # Drops events older than the cutoff; the file rows follow by cascade.
      def purge(older_than : Int64) : Int32
        @write_mutex.synchronize do
          @db.exec("DELETE FROM usage_events WHERE at < ?", older_than).rows_affected.to_i
        end
      end

      def count : Int64
        @db.scalar("SELECT COUNT(*) FROM usage_events").as(Int64)
      end

      # Headline figures for the window: how many calls, split by source and by
      # action, how many distinct documents were served, and how often the hook
      # chose to stay silent — the last being the one figure no other source can
      # report.
      def summary(since : Int64) : {events: Int32, by_source: Hash(String, Int32), by_action: Hash(String, Int32), documents: Int32, silent_hooks: Int32}
        events = @db.scalar("SELECT COUNT(*) FROM usage_events WHERE at >= ?", since).as(Int64).to_i
        documents = @db.scalar(
          "SELECT COUNT(DISTINCT f.file_path) FROM usage_event_files f " \
          "JOIN usage_events e ON e.id = f.event_id WHERE e.at >= ?", since).as(Int64).to_i
        silent = @db.scalar(
          "SELECT COUNT(*) FROM usage_events WHERE at >= ? AND source = 'hook' AND result_count = 0",
          since).as(Int64).to_i
        {events: events, by_source: group("source", since), by_action: group("action", since),
         documents: documents, silent_hooks: silent}
      end

      # Documents served in the window, most served first.
      def documents(since : Int64) : Array({path: String, served: Int32, last_at: Int64})
        rows = [] of {path: String, served: Int32, last_at: Int64}
        @db.query(
          "SELECT f.file_path, COUNT(*), MAX(e.at) FROM usage_event_files f " \
          "JOIN usage_events e ON e.id = f.event_id WHERE e.at >= ? " \
          "GROUP BY f.file_path ORDER BY COUNT(*) DESC, f.file_path", since
        ) do |result_set|
          result_set.each do
            rows << {path: result_set.read(String), served: result_set.read(Int64).to_i,
                     last_at: result_set.read(Int64)}
          end
        end
        rows
      end

      # Indexed documents never served in the window, split from those that were
      # indexed after the window opened.
      #
      # The split is what keeps this view honest: a document added yesterday
      # cannot have gone unserved for ninety days, and without the distinction
      # every fresh document would read as dead weight.
      def unused(since : Int64) : {unused: Array(String), too_recent: Array(String)}
        unused = [] of String
        too_recent = [] of String
        @db.query(
          "SELECT f.path, f.indexed_at FROM files f WHERE NOT EXISTS (" \
          "  SELECT 1 FROM usage_event_files uf JOIN usage_events e ON e.id = uf.event_id " \
          "  WHERE uf.file_path = f.path AND e.at >= ?) ORDER BY f.path", since
        ) do |result_set|
          result_set.each do
            path = result_set.read(String)
            indexed_at = result_set.read(Int64)
            (indexed_at <= since ? unused : too_recent) << path
          end
        end
        {unused: unused, too_recent: too_recent}
      end

      # The actions that go looking for a document, and so can meaningfully come
      # back empty. status, list_files, delete_file and get_project_context
      # serve no document by nature and record a zero count; counting them as
      # misses filled the one view meant to reveal gaps in the corpus with calls
      # that were never searching — and an agent calls status and list_files
      # routinely.
      SEARCHING_ACTIONS = {"query_documents", "prompt_hook"}

      # Searches that returned nothing, newest first, with the question that got
      # no answer — the view that says what a corpus is missing.
      def misses(since : Int64) : Array({at: Int64, source: String, action: String, query: String})
        rows = [] of {at: Int64, source: String, action: String, query: String}
        placeholders = Array.new(SEARCHING_ACTIONS.size, "?").join(",")
        args = [since.as(DB::Any)] + SEARCHING_ACTIONS.map(&.as(DB::Any)).to_a
        @db.query(
          "SELECT at, source, action, COALESCE(query, '') FROM usage_events " \
          "WHERE at >= ? AND result_count = 0 AND action IN (#{placeholders}) ORDER BY at DESC",
          args: args
        ) do |result_set|
          result_set.each do
            rows << {at: result_set.read(Int64), source: result_set.read(String),
                     action: result_set.read(String), query: result_set.read(String)}
          end
        end
        rows
      end

      # Counts events per value of one column. The column name is interpolated
      # rather than bound because SQLite cannot bind an identifier; the only two
      # call sites pass literals written here, never user input.
      private def group(column : String, since : Int64) : Hash(String, Int32)
        counts = {} of String => Int32
        @db.query("SELECT #{column}, COUNT(*) FROM usage_events WHERE at >= ? GROUP BY #{column}", since) do |result_set|
          result_set.each { counts[result_set.read(String)] = result_set.read(Int64).to_i }
        end
        counts
      end
    end
  end
end
