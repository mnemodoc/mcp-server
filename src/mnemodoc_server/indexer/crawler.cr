module MnemodocServer
  module Indexer
    # Scans configured paths — each a file OR a directory — for documents whose
    # extension has a registered format handler, compares mtimes against the
    # store, and indexes changed files in parallel. Format reading/parsing is
    # delegated to handlers via the registry; this class only orchestrates.
    class Crawler
      Log = ::Log.for("mnemodoc-server.indexer.crawler")

      # qdrant_index: when set (search.backend == "qdrant"), a file's points are
      # upserted post-commit and a pruned file's points are deleted — both
      # best-effort, outside the SQLite transaction.
      def initialize(@paths : Array(String), @registry : Format::Registry, @exclude : Array(String) = [] of String,
                     @qdrant_index : Store::QdrantIndex? = nil)
      end

      # Collects indexable files. A directory entry is globbed for supported
      # extensions (explicit: false). A file entry is taken as-is (explicit:
      # true) so the registry can fall back to plain text for unknown
      # extensions. Missing entries are skipped with a warning.
      def collect_files : Array({path: String, mtime: Int64, explicit: Bool})
        files = [] of {path: String, mtime: Int64, explicit: Bool}
        @paths.each do |entry|
          expanded = File.expand_path(entry)
          if File.directory?(expanded)
            Dir.glob("#{expanded}/**/*") do |path|
              next unless File.file?(path)
              next unless @registry.supported?(File.extname(path))
              next if excluded?(path)
              add_file(files, path, explicit: false)
            end
          elsif File.file?(expanded)
            add_file(files, expanded, explicit: true) unless excluded?(expanded)
          else
            Log.warn { "path does not exist, skipping: #{expanded}" }
          end
        end
        files.sort_by { |file_entry| file_entry[:path] }
      end

      # Stats and appends a file entry; skips on stat failure.
      private def add_file(files : Array({path: String, mtime: Int64, explicit: Bool}), path : String, explicit : Bool) : Nil
        mtime = File.info(path).modification_time.to_unix
        files << {path: path, mtime: mtime, explicit: explicit}
      rescue File::Error
        Log.warn { "cannot stat #{path}, skipping" }
      end

      # Returns the subset of discovered files not yet stored or whose mtime changed.
      def files_to_index(store : Store::SQLite) : Array({path: String, mtime: Int64, explicit: Bool})
        collect_files.reject { |file| store.file_indexed?(file[:path], mtime: file[:mtime]) }
      end

      # Discovers, indexes changed files across bounded worker fibers, then
      # prunes store entries no longer present (under roots that still exist).
      # Returns a named tuple with indexed, skipped, pruned, and failed counts.
      # failed is the total number of chunks that could not be embedded across the run.
      def run(store : Store::SQLite, embedder : Embedder, sf : SingleFlight, concurrency : Int32 = 4, progress : Proc(Int32, Int32, String, Nil)? = nil) : {indexed: Int32, skipped: Int32, pruned: Int32, failed: Int32}
        all_files = collect_files
        candidate_set = Set(String).new(all_files.map { |file| file[:path] })
        to_index = all_files.reject { |file| store.file_indexed?(file[:path], mtime: file[:mtime]) }
        skipped = all_files.size - to_index.size

        indexed, failed = index_files(to_index, store, embedder, sf, concurrency, progress)
        pruned = prune_stale(store, candidate_set)

        {indexed: indexed, skipped: skipped, pruned: pruned, failed: failed}
      end

      # Fans out indexing work across bounded worker fibers. Results carry the
      # success flag, path, and per-file failed chunk count for aggregation.
      # Returns {indexed_count, total_failed_chunks}.
      private def index_files(
        to_index : Array({path: String, mtime: Int64, explicit: Bool}),
        store : Store::SQLite,
        embedder : Embedder,
        sf : SingleFlight,
        concurrency : Int32,
        progress : Proc(Int32, Int32, String, Nil)? = nil,
      ) : {Int32, Int32}
        return {0, 0} if to_index.empty?

        jobs = Channel({path: String, mtime: Int64, explicit: Bool}).new(to_index.size)
        results = Channel({success: Bool, path: String, failed: Int32}).new(to_index.size)

        # Spawn bounded worker fibers
        concurrency.times do
          spawn do
            loop do
              job = jobs.receive?
              break if job.nil?
              outcome = begin
                index_one(job, store, embedder, sf)
              rescue ex
                Log.error { "unexpected error indexing #{job[:path]}: #{ex.message}" }
                {success: false, failed: 0}
              end
              results.send({success: outcome[:success], path: job[:path], failed: outcome[:failed]})
            end
          end
        end

        # Feed all jobs then close to signal workers
        spawn do
          to_index.each { |file| jobs.send(file) }
          jobs.close
        end

        # Collect exactly to_index.size results and fire the progress callback
        count = 0
        total_failed = 0
        to_index.size.times do
          result = results.receive
          count += 1 if result[:success]
          total_failed += result[:failed]
          progress.try(&.call(count, to_index.size, result[:path]))
        end
        {count, total_failed}
      end

      # Removes store entries no longer in the candidate set, but only under
      # roots (file or directory) that still exist on disk.
      private def prune_stale(store : Store::SQLite, candidate_set : Set(String)) : Int32
        pruned = 0
        @paths.each do |root|
          expanded_root = File.expand_path(root)
          next unless File.exists?(expanded_root)
          to_prune = store.file_paths.select do |stored_path|
            under_root?(stored_path, expanded_root) && !candidate_set.includes?(stored_path)
          end
          next if to_prune.empty?
          to_prune.each do |path|
            # Capture ids before the SQLite cascade removes the chunks rows, so
            # the matching Qdrant points can be deleted afterward (best-effort).
            ids = @qdrant_index ? store.chunk_ids_for_file(path) : [] of Int64
            store.delete_file(path)
            @qdrant_index.try(&.delete(ids)) unless ids.empty?
            Log.info { "pruned #{path} (removed from disk or newly excluded)" }
          end
          pruned += to_prune.size
        end
        pruned
      end

      # True when a stored path is the root itself (file root) or nested under
      # it (directory root). Avoids a bare prefix match that would falsely catch
      # a sibling sharing the root's string prefix (e.g. notes.md vs notes.mdown).
      private def under_root?(stored_path : String, expanded_root : String) : Bool
        stored_path == expanded_root || stored_path.starts_with?(expanded_root + File::SEPARATOR)
      end

      # True when the path matches any configured exclude glob.
      private def excluded?(path : String) : Bool
        @exclude.any? { |pattern| File.match?(pattern, path) }
      end

      # Dispatches one file to its handler, embeds, then writes to the store.
      # A handler returning no chunks (empty/unreadable/unsupported) leaves the
      # file unindexed so it is retried on a later run.
      # Returns {success, failed} where failed is the count of chunks that could
      # not be embedded. On unrecoverable error returns {success: false, failed: 0}.
      private def index_one(
        file : {path: String, mtime: Int64, explicit: Bool},
        store : Store::SQLite,
        embedder : Embedder,
        sf : SingleFlight,
      ) : {success: Bool, failed: Int32}
        outcome = {success: false, failed: 0}
        sf.run(file[:path]) do
          handler = @registry.for(file[:path], explicit: file[:explicit])
          if handler.nil?
            Log.debug { "no handler for #{file[:path]}, skipping" }
            next
          end
          raw_chunks = handler.extract(file[:path], file[:mtime])
          if raw_chunks.empty?
            Log.debug { "no chunks for #{file[:path]}, skipping" }
            next
          end
          embed_result = embedder.embed_chunks_resilient(raw_chunks)
          if embed_result[:embedded].empty?
            Log.warn { "all #{raw_chunks.size} chunks failed to embed for #{file[:path]}, skipping" }
            outcome = {success: false, failed: embed_result[:failed]}
          else
            store.index_file(file[:path], file[:mtime], embed_result[:embedded])
            # Best-effort Qdrant upsert from the just-committed rows (post-commit,
            # outside the SQLite transaction). Reads (id, embedding) by file.
            @qdrant_index.try { |index| index.upsert(store.embeddings_for_file(file[:path])) }
            if embed_result[:failed] > 0
              Log.warn { "indexed #{file[:path]} (#{embed_result[:embedded].size} chunks, #{embed_result[:failed]} skipped)" }
            else
              Log.info { "indexed #{file[:path]} (#{embed_result[:embedded].size} chunks)" }
            end
            outcome = {success: true, failed: embed_result[:failed]}
          end
        end
        outcome
      end
    end
  end
end
