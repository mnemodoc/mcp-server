module MnemodocServer
  module Tools
    # MCP tool that indexes a file or directory into the SQLite store.
    # Accepts a path argument, resolves it, then delegates format detection,
    # embedding, and persistence to Indexer::Crawler via the format registry.
    # Uses SingleFlight to avoid duplicate concurrent indexing of the same file.
    # When an MCP::Progress reporter is provided, emits notifications/progress
    # events after each file is indexed.
    class Ingest
      Log = ::Log.for("mnemodoc-server.tools.ingest")

      def initialize(@config : Config, @store : Store::SQLite, @embedder : Indexer::Embedder)
        @registry = Indexer::Format::Registry.new(@config)
        @sf = SingleFlight.new
      end

      # Indexes the file or directory given by the "path" argument.
      # A directory is scanned for all supported format files within it.
      # A file is indexed as itself (not its whole parent directory).
      # Returns a ToolResult with structured_content containing indexed, skipped, and pruned counts.
      # When any chunks fail to embed a warnings entry is included in structured_content.
      def call(args : Hash(String, JSON::Any), progress : MCP::Progress? = nil) : MCP::ToolResult
        path = MCP::Arguments.new(args).require_string("path")
        expanded = File.expand_path(path)

        # Index the file or directory exactly as given; the crawler handles
        # both, and a file is indexed as itself (not its whole parent dir).
        crawler = Indexer::Crawler.new([expanded], @registry, @config.exclude)
        progress_proc = build_progress_proc(progress)
        if @store.model_mismatch?(@config.ollama.model)
          Log.warn { "embedding model changed; clearing index for a full re-index" }
          @store.clear_index!
        end
        result = crawler.run(@store, @embedder, @sf, concurrency: @config.index.concurrency, progress: progress_proc)
        @store.embedding_model = @config.ollama.model

        structured = {
          "indexed" => JSON::Any.new(result[:indexed]),
          "skipped" => JSON::Any.new(result[:skipped]),
          "pruned"  => JSON::Any.new(result[:pruned]),
        } of String => JSON::Any

        if result[:failed] > 0
          structured["warnings"] = JSON::Any.new([
            JSON::Any.new("#{result[:failed]} chunk(s) failed to embed and were skipped"),
          ])
        end

        MCP::ToolResult.new(structured_content: JSON::Any.new(structured))
      end

      # Bridges MCP::Progress to the crawler's (indexed, total, file_path) proc.
      # Returns nil when no progress reporter is present.
      private def build_progress_proc(progress : MCP::Progress?) : Proc(Int32, Int32, String, Nil)?
        return nil unless reporter = progress
        Proc(Int32, Int32, String, Nil).new do |indexed, total, file_path|
          reporter.report(progress: indexed, total: total, message: file_path)
          nil
        end
      end
    end
  end
end
