require "db"
require "sqlite3"

module MnemodocServer
  module Store
    # Persists indexed files and their chunks (with embeddings stored as binary
    # blobs) in a SQLite database. Runs in WAL mode so concurrent readers and a
    # single writer can operate without blocking. A single @write_mutex
    # serialises all mutations so concurrent callers (crawler fibers, ingest
    # tool, delete tool) never race on the same database connection.
    class SQLite
      Log = ::Log.for("mnemodoc-server.store")

      @db : DB::Database
      @write_mutex = Mutex.new

      # Five tables: `files` tracks indexed paths and their mtime for change
      # detection; `chunks` holds the embedded sections, cascade-deleted when
      # their parent file is removed; `meta` stores key-value pairs such as
      # the embedding model name for mismatch detection; `vec_chunks` is the
      # vec0 virtual table providing KNN search (rowid = chunks.id); `chunks_fts`
      # is the FTS5 virtual table providing BM25 keyword search (rowid = chunks.id).
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

        CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
          embedding float[768]
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
          content,
          heading,
          file_path UNINDEXED
        )
      SQL

      # vec0: when false (the qdrant backend), the vec_chunks virtual table is
      # not populated (insert skipped) and not backfilled — the durable chunks +
      # embedding BLOBs + chunks_fts are written as usual, so Qdrant stays
      # rebuildable from SQLite.
      def initialize(db_path : String, @vec0 : Bool = true)
        Dir.mkdir_p(File.dirname(db_path))
        # PRAGMAs are applied per-connection via URI parameters (B5 fix: ensures
        # every pooled connection has foreign_keys/WAL/timeout — not just the first).
        uri = "sqlite3://#{db_path}?foreign_keys=1&journal_mode=wal&busy_timeout=5000"
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
        @write_mutex.synchronize do
          write_chunks_transaction(chunks)
        end
      end

      # Atomically replaces a file's row and all its chunks under the store write
      # lock. Used by the crawler so every concurrent worker goes through the
      # same mutex. The files upsert and every chunk write (chunks + chunks_fts +
      # vec_chunks) commit or roll back together in ONE transaction on ONE
      # connection, so a crash or exception mid-write can never leave an orphan
      # files row (which would make file_indexed? wrongly skip re-indexing).
      def index_file(path : String, mtime : Int64, chunks : Array(Chunk)) : Nil
        @write_mutex.synchronize do
          now = Time.utc.to_unix
          @db.transaction do |tx|
            cnn = tx.connection
            cnn.exec(
              "INSERT INTO files (path, mtime, indexed_at) VALUES (?, ?, ?) ON CONFLICT(path) DO UPDATE SET mtime = excluded.mtime, indexed_at = excluded.indexed_at",
              path, mtime, now
            )
            after_file_upsert(path)
            write_chunks_into(cnn, chunks)
          end
        end
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
      def clear_index! : Nil
        @write_mutex.synchronize do
          @db.exec("DELETE FROM vec_chunks")
          @db.exec("DELETE FROM chunks_fts")
          @db.exec("DELETE FROM files")
        end
      end

      # Removes a file; its chunks are dropped automatically via ON DELETE
      # CASCADE. Returns the number of rows deleted (0 when the path was not
      # indexed, 1 on success).
      def delete_file(path : String) : Int64
        @write_mutex.synchronize do
          cleanup_virtual_indexes(@db, path)
          result = @db.exec("DELETE FROM files WHERE path = ?", path)
          result.rows_affected
        end
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

      def chunk_count : Int64
        @db.query_one("SELECT COUNT(*) FROM chunks", as: Int64)
      end

      # Number of rows in the vec0 index. Used by specs to assert the vec index
      # stays in sync with the chunks table (no orphaned embeddings).
      def vec_chunk_count : Int64
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
      # path is its best because the query is ordered ascending.
      def keyword_search(match : String, limit : Int32) : Array({path: String, score: Float64})
        results = [] of {path: String, score: Float64}
        seen = Set(String).new
        @db.query(
          "SELECT file_path, bm25(chunks_fts) AS score FROM chunks_fts " \
          "WHERE chunks_fts MATCH ? ORDER BY score",
          match
        ) do |result_set|
          result_set.each do
            path = result_set.read(String)
            score = result_set.read(Float64)
            next if seen.includes?(path)
            seen << path
            results << {path: path, score: score}
            break if results.size >= limit
          end
        end
        results
      end

      # Loads every chunk (with content; embedding left empty) for a set of
      # files, in one query. Used by the keyword path so only matched files are
      # hydrated, never the whole corpus. Returns an empty array for no paths.
      def chunks_for_files(paths : Array(String)) : Array(Chunk)
        return [] of Chunk if paths.empty?
        placeholders = Array.new(paths.size, "?").join(",")
        chunks = [] of Chunk
        @db.query(
          "SELECT c.file_path, c.heading, c.parent_heading, c.content, c.token_count, f.mtime " \
          "FROM chunks c JOIN files f ON c.file_path = f.path " \
          "WHERE c.file_path IN (#{placeholders})",
          args: paths.map(&.as(DB::Any))
        ) do |result_set|
          result_set.each do
            chunks << Chunk.new(
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
          [{chunk: chunk, score: 1.0 / (1.0 + knn[:distance]), rank: i + 1}]
        end.to_a
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
        backfill_vec_chunks if @vec0
        backfill_fts_chunks
      end

      # Backfills vec_chunks from the durable chunks.embedding BLOBs when the
      # virtual table is empty. Called after every migration so restarts after a
      # crash or the first open of an existing DB auto-populate the vec index.
      private def backfill_vec_chunks : Nil
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
              next if vec.size != 768
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
        executor.exec(
          "DELETE FROM vec_chunks WHERE rowid IN (SELECT id FROM chunks WHERE file_path = ?)",
          file_path
        )
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
          # Skipped entirely under the qdrant backend (@vec0 == false); otherwise
          # only inserted when the embedding has the expected 768 dimensions.
          if @vec0
            if chunk.embedding.size == 768
              vec_str = "[#{chunk.embedding.join(",")}]"
              cnn.exec("INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)", rowid, vec_str)
            else
              Log.warn { "skipping vec_chunks insert: embedding size #{chunk.embedding.size} != 768 for #{chunk.file_path}" }
            end
          end
        end
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
