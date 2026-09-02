require "db"
require "sqlite3"

module MnemodocServer
  module Store
    # Raised whenever a vector width meets an index built for another one.
    #
    # It is an exception and not a warning because the alternative was measured:
    # a 1024-dimension model against a 768-dimension table skipped every insert,
    # logged one WARN per chunk, exited 0, and left an index that reported its
    # files and answered searches with its keyword signal alone. A caller cannot
    # tell that apart from a working index, so the only honest outcome is to
    # stop and name what has to happen (a re-index).
    class EmbeddingDimMismatch < Exception
    end

    # Persists indexed files and their chunks (with embeddings stored as binary
    # blobs) in a SQLite database. Runs in WAL mode so concurrent readers and a
    # single writer can operate without blocking. A single @write_mutex
    # serialises all mutations so concurrent callers (crawler fibers, ingest
    # tool, delete tool) never race on the same database connection.
    class SQLite
      Log = ::Log.for("mnemodoc-server.store")

      @db : DB::Database
      @write_mutex = Mutex.new
      @count_mutex = Mutex.new
      @chunk_count : Int64? = nil
      @usage : Usage? = nil
      # The width vec_chunks was created at, and the only value this store will
      # accept a vector at. nil means "not known yet": no dimension recorded, no
      # virtual table, and KNN answers empty rather than guessing.
      @vec_dim : Int32? = nil
      # Whether the virtual table exists, which is NOT the same question as
      # which backend is in use. A qdrant-backed store writes no vec0 rows but
      # can perfectly well open an index that already has the table, and must
      # still purge it on delete — conflating the two left rowids behind that a
      # later switch back to vec0 served as missing results.
      @vec_table : Bool = false

      # Five tables: `files` tracks indexed paths and their mtime for change
      # detection; `chunks` holds the embedded sections, cascade-deleted when
      # their parent file is removed; `meta` stores key-value pairs such as
      # the embedding model name and vector dimension for mismatch detection;
      # `chunks_fts` is the FTS5 virtual table providing BM25 keyword search
      # (rowid = chunks.id);
      #
      # `vec_chunks` is deliberately ABSENT from this constant. vec0 freezes the
      # vector width in its DDL (`float[N]`), and N is a property of the
      # embedding model, which this class cannot know at open time. It is
      # created by `ensure_vec_table!` once the dimension is known — from
      # `meta.embedding_dim`, from a probe before a crawl, or from the first
      # vector actually written. Declaring it here at a fixed 768 is what let a
      # 1024-dimension model build an index with no vectors at all, one WARN per
      # chunk, and a `query_documents` that answered keyword results under the
      # name "hybrid";
      # `documents` holds each file's text as the reading tools serve it, with
      # `verbatim` telling the file itself apart from a handler's extraction; and
      # `outline` holds its heading plan. Both cascade with their file, like
      # `chunks`, so removal needs no extra cleanup path.
      #
      # `usage_events` and `usage_event_files` are the usage journal. The second
      # deliberately has NO foreign key to `files`: a document removed from the
      # index must leave its history behind, since "this document stopped being
      # served" only means something if the trace outlives the file. The only
      # cascade here is internal, from the files of an event to the event.
      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS files (
          path       TEXT    PRIMARY KEY,
          mtime      INTEGER NOT NULL,
          indexed_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS chunks (
          id             INTEGER PRIMARY KEY AUTOINCREMENT,
          file_path      TEXT    NOT NULL REFERENCES files(path) ON DELETE CASCADE,
          heading        TEXT,
          parent_heading TEXT,
          content        TEXT    NOT NULL,
          embedding      BLOB    NOT NULL,
          token_count    INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_path);

        CREATE TABLE IF NOT EXISTS meta (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
          content,
          heading,
          file_path UNINDEXED
        );

        CREATE TABLE IF NOT EXISTS documents (
          file_path  TEXT    PRIMARY KEY REFERENCES files(path) ON DELETE CASCADE,
          text       TEXT    NOT NULL,
          line_count INTEGER NOT NULL,
          verbatim   INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS outline (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          file_path  TEXT    NOT NULL REFERENCES files(path) ON DELETE CASCADE,
          level      INTEGER NOT NULL,
          title      TEXT    NOT NULL,
          start_line INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_outline_file ON outline(file_path);

        CREATE TABLE IF NOT EXISTS usage_events (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          at           INTEGER NOT NULL,
          source       TEXT    NOT NULL,
          action       TEXT    NOT NULL,
          query        TEXT,
          result_count INTEGER NOT NULL DEFAULT 0,
          elapsed_ms   INTEGER,
          session      TEXT,
          agent        TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_usage_at ON usage_events(at);

        CREATE TABLE IF NOT EXISTS usage_event_files (
          event_id  INTEGER NOT NULL REFERENCES usage_events(id) ON DELETE CASCADE,
          file_path TEXT    NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_usage_files_path  ON usage_event_files(file_path);
        CREATE INDEX IF NOT EXISTS idx_usage_files_event ON usage_event_files(event_id)
      SQL

      # vec0: when false (the qdrant backend), the vec_chunks virtual table is
      # not populated (insert skipped) and not backfilled — the durable chunks +
      # embedding BLOBs + chunks_fts are written as usual, so Qdrant stays
      # rebuildable from SQLite.
      # The path an uninitialised project is served from: a store that exists so
      # the transport has one, and that touches no directory at all.
      MEMORY = ":memory:"

      def initialize(db_path : String, @vec0 : Bool = true)
        memory = db_path == MEMORY
        Dir.mkdir_p(File.dirname(db_path)) unless memory
        # PRAGMAs are applied per-connection via URI parameters (B5 fix: ensures
        # every pooled connection has foreign_keys/WAL/timeout — not just the first).
        # The in-memory form must be percent-encoded: `:memory:` in an authority
        # position parses as a bad port. WAL is meaningless without a file.
        uri = if memory
                "sqlite3://%3Amemory%3A?foreign_keys=1&busy_timeout=5000"
              else
                "sqlite3://#{db_path}?foreign_keys=1&journal_mode=wal&busy_timeout=5000"
              end
        @db = DB.open(uri)
        # Register the vec0 extension on every new connection before any query.
        @db.setup_connection do |conn|
          rc = LibVec.mnemo_vec_init(conn.as(SQLite3::Connection).to_unsafe.as(Void*))
          raise "sqlite-vec init failed (rc=#{rc})" unless rc == 0
        end
        migrate!
      end

      def close : Nil
        @db.close
      end

      # The usage journal's queries, kept out of this class: they have nothing
      # to do with indexing, and this file is large enough already. Shares this
      # store's connection and write mutex, so a journal write can never race an
      # index write inside the daemon.
      def usage : Usage
        @usage ||= Usage.new(@db, @write_mutex)
      end

      # Returns the active SQLite journal mode (expected "wal"); used in tests.
      def journal_mode : String
        @db.query_one("PRAGMA journal_mode", as: String)
      end

      # Returns the sqlite-vec extension version string (e.g. "v0.1.9").
      # Used in specs to confirm vec0 is active on the connection.
      def vec_version : String
        @db.query_one("SELECT vec_version()", as: String)
      end

      # True when the file is already indexed at exactly this mtime, letting the
      # crawler skip unchanged files.
      def file_indexed?(path : String, mtime : Int64) : Bool
        result = @db.query_one?(
          "SELECT mtime FROM files WHERE path = ?", path,
          as: Int64
        )
        result == mtime
      end

      # True when any row exists for the given path; cheaper than list_files.any?.
      def exists?(path : String) : Bool
        @db.query_one?(
          "SELECT 1 FROM files WHERE path = ? LIMIT 1", path,
          as: Int32
        ) == 1
      end

      # Inserts or refreshes the file's mtime and index timestamp.
      def upsert_file(path : String, mtime : Int64) : Nil
        @write_mutex.synchronize do
          now = Time.utc.to_unix
          @db.exec(
            "INSERT INTO files (path, mtime, indexed_at) VALUES (?, ?, ?) ON CONFLICT(path) DO UPDATE SET mtime = excluded.mtime, indexed_at = excluded.indexed_at",
            path, mtime, now
          )
        end
      end

      # Replaces all chunks for the affected files in a single transaction.
      def save_chunks(chunks : Array(Chunk)) : Nil
        return if chunks.empty?
        invalidate_chunk_count
        @write_mutex.synchronize do
          adopt_dim_for(chunks)
          write_chunks_transaction(chunks)
        end
      end

      # Atomically replaces a file's row and all its chunks under the store write
      # lock. Used by the crawler so every concurrent worker goes through the
      # same mutex. The files upsert and every chunk write (chunks + chunks_fts +
      # vec_chunks) commit or roll back together in ONE transaction on ONE
      # connection, so a crash or exception mid-write can never leave an orphan
      # files row (which would make file_indexed? wrongly skip re-indexing).
      def index_file(path : String, mtime : Int64, chunks : Array(Chunk),
                     text : String, verbatim : Bool, outline : Array(Indexer::OutlineEntry)) : Nil
        invalidate_chunk_count
        @write_mutex.synchronize do
          # Ahead of the transaction, deliberately. Adopting a width writes a
          # DDL statement and a meta row; done inside the caller's transaction,
          # a rollback undid both while the in-memory width survived, leaving
          # the store pointing at a table that no longer existed. Outside it,
          # the worst a rollback leaves behind is an empty vec table of the
          # right width — which is exactly what the next write needs.
          adopt_dim_for(chunks)
          now = Time.utc.to_unix
          @db.transaction do |tx|
            cnn = tx.connection
            cnn.exec(
              "INSERT INTO files (path, mtime, indexed_at) VALUES (?, ?, ?) ON CONFLICT(path) DO UPDATE SET mtime = excluded.mtime, indexed_at = excluded.indexed_at",
              path, mtime, now
            )
            after_file_upsert(path)
            write_chunks_into(cnn, chunks)
            after_chunk_write(path)
            write_document_into(cnn, path, text, verbatim, outline)
          end
        end
      end

      # Replaces a file's document text and outline. Runs on the same connection
      # and inside the same transaction as the chunk write, so the stored text
      # can never describe a different revision from the chunks searched against
      # it — which is the whole reason reading serves this copy rather than the
      # file on disk.
      private def write_document_into(cnn : DB::Connection, path : String, text : String,
                                      verbatim : Bool, outline : Array(Indexer::OutlineEntry)) : Nil
        cnn.exec("DELETE FROM documents WHERE file_path = ?", path)
        cnn.exec("DELETE FROM outline WHERE file_path = ?", path)
        cnn.exec(
          "INSERT INTO documents (file_path, text, line_count, verbatim) VALUES (?, ?, ?, ?)",
          path, text, text.lines.size, verbatim ? 1 : 0
        )
        outline.each do |entry|
          cnn.exec(
            "INSERT INTO outline (file_path, level, title, start_line) VALUES (?, ?, ?, ?)",
            path, entry.level, entry.title, entry.start_line
          )
        end
      end

      # The stored document for a path, or nil when the file is unknown or was
      # indexed before documents were stored.
      def document_for(path : String) : {text: String, line_count: Int32, verbatim: Bool}?
        @db.query_one?(
          "SELECT text, line_count, verbatim FROM documents WHERE file_path = ?",
          path, as: {String, Int32, Int32}
        ).try { |row| {text: row[0], line_count: row[1], verbatim: row[2] != 0} }
      end

      # A file's plan, in document order. Ordering by start_line makes the order
      # a property of the rows rather than of the insertion sequence; id only
      # breaks ties between two headings reported on one line.
      def outline_for(path : String) : Array(Indexer::OutlineEntry)
        entries = [] of Indexer::OutlineEntry
        @db.query(
          "SELECT level, title, start_line FROM outline WHERE file_path = ? ORDER BY start_line, id",
          path
        ) do |result_set|
          result_set.each do
            entries << Indexer::OutlineEntry.new(
              result_set.read(Int32), result_set.read(String), result_set.read(Int32)
            )
          end
        end
        entries
      end

      # Indexed files carrying no stored document — an index built before this
      # existed. Drives the startup backfill, which needs the recorded mtime so
      # rebuilding leaves the file's freshness bookkeeping untouched.
      def files_missing_documents : Array({path: String, mtime: Int64})
        rows = [] of {path: String, mtime: Int64}
        @db.query(
          "SELECT f.path, f.mtime FROM files f LEFT JOIN documents d ON d.file_path = f.path " \
          "WHERE d.file_path IS NULL ORDER BY f.path"
        ) do |result_set|
          result_set.each { rows << {path: result_set.read(String), mtime: result_set.read(Int64)} }
        end
        rows
      end

      # Test-only seam: invoked inside the index_file transaction, right after
      # the files row is upserted and before any chunk is written. The default
      # is a no-op; specs override it in a subclass to raise here and prove the
      # whole transaction (files row included) rolls back atomically.
      protected def after_file_upsert(path : String) : Nil
      end

      # Wipes the entire index: all files (cascading their chunks), the vec0
      # index, and the FTS index. Used when the embedding model changes so the
      # next crawl re-indexes every file with the new model.
      #
      # The vec0 table is DROPPED, not emptied, and the recorded dimension goes
      # with it. Emptying would keep the width of the model being replaced, so
      # the very rebuild this clear exists to trigger would meet a table frozen
      # at the old size and skip every vector — which is the failure that
      # brought this code into being, merely deferred by one command.
      def clear_index! : Nil
        invalidate_chunk_count
        @write_mutex.synchronize do
          @db.exec("DROP TABLE IF EXISTS vec_chunks")
          @db.exec("DELETE FROM meta WHERE key = 'embedding_dim'")
          @vec_dim = nil
          @vec_table = false
          @db.exec("DELETE FROM chunks_fts")
          @db.exec("DELETE FROM files")
        end
      end

      # Removes a file; its chunks are dropped automatically via ON DELETE
      # CASCADE. Returns the number of rows deleted (0 when the path was not
      # indexed, 1 on success).
      # The virtual-index cleanup and the DELETE share ONE transaction on ONE
      # connection. As two separate statements they could half-succeed — a busy
      # timeout under concurrent writes is enough — emptying vec0 and FTS5 while
      # leaving the files row and its chunks behind. The file then still counted
      # as indexed at its recorded mtime, so no crawl ever revisited it, and it
      # had no search entries left: present, unreachable, and silent about it.
      # That half-state does not repair itself either, since the startup
      # backfill only fires when the virtual table is entirely empty.
      def delete_file(path : String) : Int64
        invalidate_chunk_count
        @write_mutex.synchronize do
          rows = 0_i64
          @db.transaction do |tx|
            cnn = tx.connection
            cleanup_virtual_indexes(cnn, path)
            after_virtual_cleanup(path)
            rows = cnn.exec("DELETE FROM files WHERE path = ?", path).rows_affected
          end
          rows
        end
      end

      # Test-only seam, third of three: fires inside the index_file transaction
      # once the chunks are written, which is the only window in which a write
      # can roll back schema the chunk write itself created. No-op in production.
      protected def after_chunk_write(path : String) : Nil
      end

      # Test-only seam, mirroring after_file_upsert: fires inside the delete
      # transaction, between the virtual-index cleanup and the DELETE, so a spec
      # can prove the two roll back together. No-op in production.
      protected def after_virtual_cleanup(path : String) : Nil
      end

      # Returns all indexed file paths as a lightweight string array, without
      # the JOIN/GROUP BY overhead of list_files. Useful for pruning and path
      # resolution where only the paths are needed.
      def file_paths : Array(String)
        paths = [] of String
        @db.query("SELECT path FROM files") do |result_set|
          result_set.each { paths << result_set.read(String) }
        end
        paths
      end

      # Resolves a user-supplied path string to the actual absolute path stored
      # in the index, using a three-step strategy:
      #   1. Exact match — returns input unchanged when already indexed.
      #   2. Expanded match — tries File.expand_path(input) for relative paths.
      #   3. Suffix match — searches all stored paths for a unique one whose
      #      path component ends with "/" + input; returns nil if ambiguous.
      # Returns nil when no match is found or the suffix is ambiguous.
      def indexed_path_for(input : String) : String?
        return input if exists?(input)

        expanded = File.expand_path(input)
        return expanded if exists?(expanded)

        suffix = "/#{input}"
        all_paths = file_paths
        matches = all_paths.select(&.ends_with?(suffix))
        matches.size == 1 ? matches.first : nil
      end

      # Lists indexed files with their chunk counts, ordered by path.
      def list_files : Array(FileInfo)
        files = [] of FileInfo
        @db.query("SELECT f.path, f.mtime, f.indexed_at, COUNT(c.id) as chunk_count FROM files f LEFT JOIN chunks c ON f.path = c.file_path GROUP BY f.path ORDER BY f.path") do |result_set|
          result_set.each do
            files << FileInfo.new(
              path: result_set.read(String),
              mtime: result_set.read(Int64),
              indexed_at: result_set.read(Int64),
              chunk_count: result_set.read(Int32)
            )
          end
        end
        files
      end

      # Retrieves a metadata value by key; returns nil when the key is absent.
      def meta_get(key : String) : String?
        @db.query_one?("SELECT value FROM meta WHERE key = ?", key, as: String)
      end

      # Inserts or updates a metadata key-value pair under the write lock.
      def meta_set(key : String, value : String) : Nil
        @write_mutex.synchronize do
          @db.exec(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            key, value
          )
        end
      end

      # Convenience reader for the recorded embedding model name.
      def embedding_model : String?
        meta_get("embedding_model")
      end

      # Convenience writer that records the embedding model used for indexing.
      def embedding_model=(model : String) : Nil
        meta_set("embedding_model", model)
      end

      # Returns true when a model name is recorded in the store and it differs
      # from the currently configured model, signalling that a re-index is needed.
      def model_mismatch?(current : String) : Bool
        stored = embedding_model
        !stored.nil? && stored != current
      end

      # Memoised, because query_documents reports it on every single search and
      # a COUNT(*) walks the table. Invalidated by each write path below, so a
      # stale value cannot outlive the change that made it stale.
      def chunk_count : Int64
        @count_mutex.synchronize do
          @chunk_count ||= @db.query_one("SELECT COUNT(*) FROM chunks", as: Int64)
        end
      end

      # Called by every mutation. Cheaper and far harder to get wrong than
      # adjusting the cached number by hand at each site.
      private def invalidate_chunk_count : Nil
        @count_mutex.synchronize { @chunk_count = nil }
      end

      # Number of rows in the vec0 index. Used by specs to assert the vec index
      # stays in sync with the chunks table (no orphaned embeddings). Zero when
      # no dimension has been adopted: the table does not exist then, and
      # "no vectors" is the honest answer rather than a SQL error.
      def vec_chunk_count : Int64
        return 0_i64 unless @vec_table
        @db.query_one("SELECT COUNT(*) FROM vec_chunks", as: Int64)
      end

      # Number of rows in the FTS index. Used by specs to assert the keyword
      # index stays in sync with the chunks table (no orphaned entries).
      def fts_chunk_count : Int64
        @db.query_one("SELECT COUNT(*) FROM chunks_fts", as: Int64)
      end

      # Returns the files whose chunks best match an FTS5 query, ranked best
      # first by their most relevant chunk's BM25 score (lower bm25 = better),
      # one row per file, capped at `limit`. The caller is responsible for
      # building a non-empty, well-formed FTS5 MATCH expression (FTS5 raises on
      # an empty expression). bm25() may only be used in a flat MATCH query (not
      # inside an aggregate or subquery), so rows are scored and ordered in SQL
      # and collapsed to the best score per file here — the first row seen for a
      # path is its best because the query is ordered ascending. Each row also
      # carries that best chunk's id (the FTS rowid IS chunks.id), so the caller
      # can attribute the file's keyword mass to the chunk that actually matched
      # rather than spreading it across the file's every chunk.
      def keyword_search(match : String, limit : Int32) : Array({path: String, score: Float64, chunk_id: Int64})
        results = [] of {path: String, score: Float64, chunk_id: Int64}
        seen = Set(String).new
        @db.query(
          "SELECT file_path, rowid, bm25(chunks_fts) AS score FROM chunks_fts " \
          "WHERE chunks_fts MATCH ? ORDER BY score",
          match
        ) do |result_set|
          result_set.each do
            path = result_set.read(String)
            chunk_id = result_set.read(Int64)
            score = result_set.read(Float64)
            next if seen.includes?(path)
            seen << path
            results << {path: path, score: score, chunk_id: chunk_id}
            break if results.size >= limit
          end
        end
        results
      end

      # Loads every chunk (with content; embedding left empty) for a set of
      # files, in one query. Used by the rehydrate path
      # (`MnemodocServer.rehydrated_chunks`) to reload a file's stored chunks.
      # Returns an empty array for no paths.
      def chunks_for_files(paths : Array(String)) : Array(Chunk)
        return [] of Chunk if paths.empty?
        placeholders = Array.new(paths.size, "?").join(",")
        chunks = [] of Chunk
        @db.query(
          "SELECT c.id, c.file_path, c.heading, c.parent_heading, c.content, c.token_count, f.mtime " \
          "FROM chunks c JOIN files f ON c.file_path = f.path " \
          "WHERE c.file_path IN (#{placeholders})",
          args: paths.map(&.as(DB::Any))
        ) do |result_set|
          result_set.each do
            chunks << Chunk.new(
              id: result_set.read(Int64),
              file_path: result_set.read(String),
              heading: result_set.read(String?),
              parent_heading: result_set.read(String?),
              content: result_set.read(String),
              embedding: [] of Float32,
              token_count: result_set.read(Int32),
              mtime: result_set.read(Int64),
            )
          end
        end
        chunks
      end

      # Hydrates chunks by their `chunks.id`, keyed by id (embedding left empty).
      # Used by the Qdrant read path to turn KNN hit ids into Chunks. Missing ids
      # are simply absent from the result.
      def chunks_by_ids(ids : Array(Int64)) : Hash(Int64, Chunk)
        result = {} of Int64 => Chunk
        return result if ids.empty?
        placeholders = Array.new(ids.size, "?").join(",")
        @db.query(
          "SELECT c.id, c.file_path, c.heading, c.parent_heading, c.content, c.token_count, f.mtime " \
          "FROM chunks c JOIN files f ON c.file_path = f.path WHERE c.id IN (#{placeholders})",
          args: ids.map(&.as(DB::Any))
        ) do |result_set|
          result_set.each do
            id = result_set.read(Int64)
            result[id] = Chunk.new(
              id: id,
              file_path: result_set.read(String),
              heading: result_set.read(String?),
              parent_heading: result_set.read(String?),
              content: result_set.read(String),
              embedding: [] of Float32,
              token_count: result_set.read(Int32),
              mtime: result_set.read(Int64),
            )
          end
        end
        result
      end

      # Returns a file's chunk ids in row order. Used to delete a pruned file's
      # points from Qdrant before the SQLite cascade removes the chunks rows.
      def chunk_ids_for_file(path : String) : Array(Int64)
        ids = [] of Int64
        @db.query("SELECT id FROM chunks WHERE file_path = ?", path) do |result_set|
          result_set.each { ids << result_set.read(Int64) }
        end
        ids
      end

      # Returns (id, deserialized embedding) for one file's chunks — fed straight
      # to QdrantIndex#upsert after the file's SQLite write commits.
      def embeddings_for_file(path : String) : Array({id: Int64, vector: Array(Float32)})
        read_embeddings("SELECT id, embedding FROM chunks WHERE file_path = ?", path)
      end

      # Corpus-wide (id, deserialized embedding) reader for the Qdrant startup
      # backfill (parallel to backfill_vec_chunks).
      def stored_embeddings : Array({id: Int64, vector: Array(Float32)})
        read_embeddings("SELECT id, embedding FROM chunks WHERE embedding IS NOT NULL AND length(embedding) > 0")
      end

      # The same rows, handed over one batch at a time. The upsert that consumes
      # them was already batched; the read was not, so the whole corpus of
      # vectors was resident before the first batch left — around 150 MB for
      # 50 000 chunks, at daemon startup.
      def each_stored_embedding_batch(size : Int32, & : Array({id: Int64, vector: Array(Float32)}) -> Nil) : Nil
        batch = [] of {id: Int64, vector: Array(Float32)}
        @db.query("SELECT id, embedding FROM chunks WHERE embedding IS NOT NULL AND length(embedding) > 0") do |result_set|
          result_set.each do
            id = result_set.read(Int64)
            blob = result_set.read(Bytes)
            next if blob.empty?
            batch << {id: id, vector: deserialize_embedding(blob)}
            if batch.size >= size
              yield batch
              batch = [] of {id: Int64, vector: Array(Float32)}
            end
          end
        end
        yield batch unless batch.empty?
      end

      # Shared (id, embedding-BLOB → Array(Float32)) reader for the two methods
      # above; skips empty BLOBs.
      private def read_embeddings(sql : String, *args) : Array({id: Int64, vector: Array(Float32)})
        rows = [] of {id: Int64, vector: Array(Float32)}
        @db.query(sql, *args) do |result_set|
          result_set.each do
            id = result_set.read(Int64)
            blob = result_set.read(Bytes)
            next if blob.empty?
            rows << {id: id, vector: deserialize_embedding(blob)}
          end
        end
        rows
      end

      # Finds the k nearest chunks by L2 distance using the vec0 virtual table.
      # Hydrates the full Chunk structs from the chunks+files tables. Returns
      # results ordered by ascending distance (rank 1 = closest match).
      def knn_chunks(query_vec : Array(Float32), limit : Int32) : Array({chunk: Chunk, score: Float64, rank: Int32})
        dim = @vec_dim
        # No dimension adopted means no vectors at all — an empty index, or one
        # whose first crawl has yet to run. Nothing to return, and nothing wrong.
        return [] of {chunk: Chunk, score: Float64, rank: Int32} if !@vec_table || dim.nil?
        # A query vector of another width, though, is a caller searching a
        # corpus embedded by a different model. vec0 would reject the MATCH with
        # its own message and the fusion above would quietly answer with the
        # keyword signal alone, which reads as a working hybrid search.
        if query_vec.size != dim
          raise EmbeddingDimMismatch.new(
            "the query embedding has #{query_vec.size} dimensions but this index stores " \
            "#{dim}-dimension vectors: the configured embedding model is not the one the " \
            "index was built with — re-index before searching")
        end
        query_str = "[#{query_vec.join(",")}]"
        knn_rows = [] of {rowid: Int64, distance: Float64}
        @db.query(
          "SELECT rowid, distance FROM vec_chunks WHERE embedding MATCH ? ORDER BY distance LIMIT ?",
          query_str, limit
        ) do |result_set|
          result_set.each do
            knn_rows << {rowid: result_set.read(Int64), distance: result_set.read(Float64)}
          end
        end
        return [] of {chunk: Chunk, score: Float64, rank: Int32} if knn_rows.empty?

        # Hydrate in one query; interpolating Int64 IDs is safe (DB-generated).
        id_list = knn_rows.map(&.[:rowid]).join(",")
        chunk_map = {} of Int64 => Chunk
        @db.query(
          "SELECT c.id, c.file_path, c.heading, c.parent_heading, c.content, c.token_count, f.mtime " \
          "FROM chunks c JOIN files f ON c.file_path = f.path " \
          "WHERE c.id IN (#{id_list})"
        ) do |result_set|
          result_set.each do
            id = result_set.read(Int64)
            chunk_map[id] = Chunk.new(
              id: id,
              file_path: result_set.read(String),
              heading: result_set.read(String?),
              parent_heading: result_set.read(String?),
              content: result_set.read(String),
              embedding: [] of Float32,
              token_count: result_set.read(Int32),
              mtime: result_set.read(Int64),
            )
          end
        end

        knn_rows.each_with_index.flat_map do |knn, i|
          chunk = chunk_map[knn[:rowid]]?
          next [] of {chunk: Chunk, score: Float64, rank: Int32} unless chunk
          [{chunk: chunk, score: cosine_from_l2(knn[:distance]), rank: i + 1}]
        end.to_a
      end

      # vec0 ranks by L2 distance. Chunk embeddings are normalised at index time
      # and Ollama returns unit vectors, so the distance is purely angular and
      # L2² = 2 - 2·cos inverts exactly.
      #
      # This used to return 1/(1 + distance): monotonic in cosine, so ranking was
      # correct, but it is not a similarity. It compresses the scale hard toward
      # 0.5 — on the benchmark corpus the separation between on-topic and
      # off-topic prompts collapsed from 0.054 in cosine to 0.014 — so any
      # threshold calibrated on real cosines was being applied to the wrong axis.
      private def cosine_from_l2(distance : Float64) : Float64
        (1.0 - (distance * distance) / 2.0).clamp(-1.0, 1.0)
      end

      # Counts indexed files without the GROUP BY/JOIN that list_files performs.
      def file_count : Int64
        @db.query_one("SELECT COUNT(*) FROM files", as: Int64)
      end

      # Applies the schema statement by statement (idempotent via IF NOT EXISTS),
      # then backfills vec_chunks from stored BLOBs if the virtual table is empty.
      private def migrate! : Nil
        SCHEMA.split(";").each do |stmt|
          stmt = stmt.strip
          @db.exec(stmt) unless stmt.empty?
        end
        adopt_recorded_dim!
        backfill_vec_chunks if @vec0 && vec_ready?
        backfill_fts_chunks
      end

      # Restores @vec_dim from what the database already knows, and reconciles
      # the two places that can know it.
      #
      # Two orders are possible and both are legitimate. `meta.embedding_dim`
      # without a table is an index whose virtual table was dropped — by a
      # `clear_index!`, or by running under the qdrant backend — and the table
      # is rebuilt at the recorded width, the startup backfill refilling it from
      # the durable BLOBs. A table without the meta row is an index built before
      # the dimension was recorded at all: its width is readable from its own
      # DDL, and writing it down is what gives every later check something to
      # compare against. A fresh database has neither, and stays without a
      # dimension until one is adopted.
      private def adopt_recorded_dim! : Nil
        recorded = meta_get("embedding_dim").try(&.to_i?)
        table_dim = vec_table_dim

        # The two disagreeing is not a model mismatch but corrupt bookkeeping,
        # reachable only by editing the database by hand. The DDL wins, because
        # it is the record that actually constrains: vec0 cannot be made to
        # accept a vector of another width, so no wrong answer can come of
        # trusting it, while refusing to open would take the read-only tools,
        # keyword search and `status` down with an index they work fine against.
        # The meta row is then corrected rather than left to disagree again.
        if recorded && table_dim && recorded != table_dim
          Log.warn { "index metadata records #{recorded}-dimension vectors but vec_chunks is declared float[#{table_dim}]; trusting the table and correcting the metadata" }
        end

        dim = table_dim || recorded
        return if dim.nil?

        @vec_dim = dim
        @vec_table = !table_dim.nil?
        if recorded != dim
          @db.exec(
            "INSERT INTO meta (key, value) VALUES ('embedding_dim', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            dim.to_s
          )
        end
        ensure_vec_table!(@db, dim) if @vec0 && table_dim.nil?
      end

      # The width vec_chunks was declared at, read back from its own DDL, or nil
      # when the table does not exist. sqlite_master is the only place that
      # holds it: vec0 exposes no introspection of its own.
      def vec_table_dim : Int32?
        sql = @db.query_one?(
          "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'vec_chunks'",
          as: String?
        )
        return nil if sql.nil?
        sql.match(/float\s*\[\s*(\d+)\s*\]/).try(&.[1].to_i)
      end

      # The recorded vector width of this index, or nil when none was adopted.
      def embedding_dim : Int32?
        @vec_dim
      end

      # True when the virtual table exists and its width is known — the two
      # conditions any vec0 statement needs, whatever the configured backend.
      def vec_ready? : Bool
        @vec_table && !@vec_dim.nil?
      end

      # Adopts `dim` for this index, or refuses it.
      #
      # Called before a crawl, with the width of an embedding the configured
      # model has just produced. Refusing here rather than at write time is the
      # whole point: the crawler rescues per file (see Indexer::Crawler#run), so
      # an error raised while writing a chunk would come back as a `failed`
      # counter — the same silent degradation in a different disguise.
      def prepare_embedding_dim!(dim : Int32) : Nil
        stored = @vec_dim
        if stored && stored != dim
          raise EmbeddingDimMismatch.new(
            "index was built with #{stored}-dimension vectors and the configured embedding " \
            "model produces #{dim}: sqlite-vec freezes the width in the table definition, so " \
            "the index cannot be extended — a full re-index is required (delete the index " \
            "directory, or let the model change clear it)")
        end
        return if stored

        @write_mutex.synchronize do
          @db.exec(
            "INSERT INTO meta (key, value) VALUES ('embedding_dim', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            dim.to_s
          )
          ensure_vec_table!(@db, dim) if @vec0
          @vec_dim = dim
        end
      end

      # Creates the vec0 virtual table at the given width. `dim` is an Int32
      # this class derived itself, never a caller's string, so interpolating it
      # into the DDL carries no injection surface — and vec0 takes no bind
      # parameter in a CREATE.
      private def ensure_vec_table!(executor, dim : Int32) : Nil
        executor.exec("CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(embedding float[#{dim}])")
        @vec_table = true
      end

      # Backfills vec_chunks from the durable chunks.embedding BLOBs when the
      # virtual table is empty. Called after every migration so restarts after a
      # crash or the first open of an existing DB auto-populate the vec index.
      private def backfill_vec_chunks : Nil
        dim = @vec_dim
        return if dim.nil?
        count = @db.query_one("SELECT COUNT(*) FROM vec_chunks", as: Int64)
        return unless count == 0
        chunk_count = @db.query_one("SELECT COUNT(*) FROM chunks WHERE embedding IS NOT NULL AND length(embedding) > 0", as: Int64)
        return unless chunk_count > 0

        Log.info { "backfilling vec_chunks from #{chunk_count} stored embeddings" }
        @db.transaction do |tx|
          cnn = tx.connection
          cnn.query("SELECT id, embedding FROM chunks WHERE embedding IS NOT NULL AND length(embedding) > 0") do |result_set|
            result_set.each do
              id = result_set.read(Int64)
              blob = result_set.read(Bytes)
              next if blob.empty?
              vec = deserialize_embedding(blob)
              # A stored BLOB of another width predates the current index: it
              # cannot be searched against these vectors, so it is left out of
              # vec0 rather than rejected — refusing here would make an index
              # carrying one stale row impossible to open at all.
              if vec.size != dim
                Log.warn { "skipping backfill of a #{vec.size}-dimension embedding into a float[#{dim}] index (chunk #{id})" }
                next
              end
              vec_str = "[#{vec.join(",")}]"
              cnn.exec("INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)", id, vec_str)
            end
          end
        end
        Log.info { "vec_chunks backfill complete" }
      end

      # Backfills chunks_fts from the durable chunks table when the FTS index is
      # empty (e.g. first open of a pre-FTS5 database, or after a crash). Called
      # after every migration so existing indexes gain keyword search for free.
      private def backfill_fts_chunks : Nil
        count = @db.query_one("SELECT COUNT(*) FROM chunks_fts", as: Int64)
        return unless count == 0
        chunk_count = @db.query_one("SELECT COUNT(*) FROM chunks", as: Int64)
        return unless chunk_count > 0

        Log.info { "backfilling chunks_fts from #{chunk_count} stored chunks" }
        @db.transaction do |tx|
          cnn = tx.connection
          cnn.query("SELECT id, content, heading, file_path FROM chunks") do |result_set|
            result_set.each do
              cnn.exec(
                "INSERT INTO chunks_fts(rowid, content, heading, file_path) VALUES (?, ?, ?, ?)",
                result_set.read(Int64), result_set.read(String),
                result_set.read(String?), result_set.read(String)
              )
            end
          end
        end
        Log.info { "chunks_fts backfill complete" }
      end

      # Clears a file's rows from the virtual indexes (vec0 and FTS5). Neither
      # has FK cascade, so they must be emptied explicitly before the chunks rows
      # their rowids reference are deleted. Accepts either the pooled database or
      # a transaction connection (both respond to #exec).
      private def cleanup_virtual_indexes(executor, file_path : String) : Nil
        # Guarded on the table existing, NOT on the configured backend: a
        # qdrant-backed store that opened an index carrying a vec0 table still
        # owns those rows, and skipping the purge orphans them.
        if @vec_table
          executor.exec(
            "DELETE FROM vec_chunks WHERE rowid IN (SELECT id FROM chunks WHERE file_path = ?)",
            file_path
          )
        end
        executor.exec(
          "DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE file_path = ?)",
          file_path
        )
      end

      # Replaces chunks for all affected files in a single transaction.
      # Must be called from within a @write_mutex.synchronize block.
      # Thin wrapper around write_chunks_into so callers that only touch chunks
      # (save_chunks) keep their own transaction boundary.
      private def write_chunks_transaction(chunks : Array(Chunk)) : Nil
        return if chunks.empty?
        @db.transaction do |tx|
          write_chunks_into(tx.connection, chunks)
        end
      end

      # Writes the given chunks (chunks + chunks_fts + vec_chunks) on the passed
      # connection WITHOUT opening its own transaction, so the caller controls the
      # transaction boundary (index_file shares one transaction with the files
      # upsert; write_chunks_transaction wraps this in a dedicated transaction).
      # Deletes vec_chunks rows before deleting chunks (vec0 has no FK cascade),
      # then inserts fresh vec_chunks entries using last_insert_rowid().
      private def write_chunks_into(cnn : DB::Connection, chunks : Array(Chunk)) : Nil
        return if chunks.empty?
        files = chunks.map(&.file_path).uniq!
        files.each do |file_path|
          cleanup_virtual_indexes(cnn, file_path)
          cnn.exec("DELETE FROM chunks WHERE file_path = ?", file_path)
        end
        chunks.each do |chunk|
          cnn.exec(
            "INSERT INTO chunks (file_path, heading, parent_heading, content, embedding, token_count) VALUES (?, ?, ?, ?, ?, ?)",
            chunk.file_path,
            chunk.heading,
            chunk.parent_heading,
            chunk.content,
            serialize_embedding(chunk.embedding),
            chunk.token_count
          )
          rowid = cnn.query_one("SELECT last_insert_rowid()", as: Int64)
          # The FTS index covers every chunk regardless of embedding validity,
          # so keyword search works even when a vector is missing/malformed.
          cnn.exec(
            "INSERT INTO chunks_fts(rowid, content, heading, file_path) VALUES (?, ?, ?, ?)",
            rowid, chunk.content, chunk.heading, chunk.file_path
          )
          # Insert this chunk's embedding into vec_chunks using the same rowid.
          # Skipped entirely under the qdrant backend (@vec0 == false), and for a
          # chunk whose embedding failed: it carries an empty vector, is indexed
          # for keyword search all the same, and has simply nothing to put in
          # vec0. Any other width is a mismatch and raises — see verify_dim!.
          # The width itself was adopted before this transaction opened.
          unless chunk.embedding.empty?
            verify_dim!(chunk.embedding.size, chunk.file_path)
            if @vec0
              vec_str = "[#{chunk.embedding.join(",")}]"
              cnn.exec("INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)", rowid, vec_str)
            end
          end
        end
      end

      # Adopts or verifies the vector width from a vector about to be written,
      # on the transaction's own connection.
      #
      # It runs on `cnn` and not through meta_set/prepare_embedding_dim! because
      # the write mutex is already held by the caller: Crystal's Mutex is
      # checked, so taking it again from the same fiber raises rather than
      # deadlocking. Riding the caller's transaction is also the correct
      # semantics — the table, the meta row and the first vector commit together
      # or not at all.
      #
      # This is the last line of defence, not the usual path: a crawl probes the
      # model first (MnemodocServer.probe_embedding_dim!). It matters for the one
      # entry point that legitimately indexes without a probe — `init`, which is
      # allowed to run before Ollama is up.
      private def adopt_dim_for(chunks : Array(Chunk)) : Nil
        chunk = chunks.find { |candidate| !candidate.embedding.empty? }
        return if chunk.nil?
        size = chunk.embedding.size
        dim = @vec_dim
        unless dim.nil?
          verify_dim!(size, chunk.file_path)
          return
        end

        @db.exec(
          "INSERT INTO meta (key, value) VALUES ('embedding_dim', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          size.to_s
        )
        ensure_vec_table!(@db, size) if @vec0
        @vec_dim = size
        Log.info { "adopted #{size}-dimension embeddings for this index" }
      end

      # Refuses a vector this index cannot hold. Cheap and read-only, so it runs
      # per chunk inside the write: a batch mixing two widths is caught on the
      # one that does not fit, not on whichever happened to come first.
      private def verify_dim!(size : Int32, file_path : String) : Nil
        dim = @vec_dim
        return if dim.nil? || dim == size

        raise EmbeddingDimMismatch.new(
          "#{file_path} produced a #{size}-dimension embedding but this index stores " \
          "#{dim}-dimension vectors: sqlite-vec freezes the width in the table definition, " \
          "so a full re-index is required")
      end

      # Packs the Float32 vector into a little-endian blob (4 bytes per value).
      # No conversion needed since the in-memory type is already Float32.
      private def serialize_embedding(embedding : Array(Float32)) : Bytes
        io = IO::Memory.new(embedding.size * 4)
        embedding.each { |value| io.write_bytes(value, IO::ByteFormat::LittleEndian) }
        io.to_slice
      end

      # Reverses serialize_embedding, reading 4-byte little-endian Float32 values
      # directly into an Array(Float32) — no widening to Float64.
      private def deserialize_embedding(bytes : Bytes) : Array(Float32)
        io = IO::Memory.new(bytes)
        Array(Float32).new(bytes.size // 4) { io.read_bytes(Float32, IO::ByteFormat::LittleEndian) }
      end
    end
  end
end
