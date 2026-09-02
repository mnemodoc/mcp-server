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
        ensure_within_configured_roots(expanded)

        # A changed embedding model invalidates every stored vector, so the
        # index has to be rebuilt whole. This entry point cannot do that: it was
        # given one path. It used to clear the index anyway, refill that single
        # path, and record the new model — erasing the very mark that would have
        # made the next full crawl rebuild the rest. Refusing keeps the index
        # intact and the mismatch visible; indexing without clearing would be
        # worse still, mixing vectors from two models in one index.
        if @store.model_mismatch?(@config.ollama.model)
          stored = @store.embedding_model || "unknown"
          raise MCP::ToolError.new(
            "index was built with embedding model '#{stored}' and the configuration now uses " \
            "'#{@config.ollama.model}': every stored vector is stale. Run a full re-index " \
            "(mnemodoc-server index) rather than ingesting a single path.")
        end

        # Same reasoning one step further down: the model name can be unchanged
        # while the model itself has been re-released at another vector width.
        # Probing before the crawl turns that into a refusal rather than a run
        # that indexes text and quietly stores no vectors.
        begin
          MnemodocServer.probe_embedding_dim!(@config, @store, @embedder)
        rescue ex : Store::EmbeddingDimMismatch
          raise MCP::ToolError.new(ex.message || "embedding dimension mismatch")
        end

        # Index the file or directory exactly as given; the crawler handles
        # both, and a file is indexed as itself (not its whole parent dir).
        crawler = Indexer::Crawler.new([expanded], @registry, @config.exclude)
        progress_proc = build_progress_proc(progress)
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

      # Refuses a path that does not sit under one of the configured roots.
      #
      # The corpus this server indexes is also the channel an attacker writes
      # on: a document can tell the agent to ingest ~/.aws/credentials, and the
      # answer used to be yes — the crawler treats an explicitly named file as
      # explicit, the registry falls back to plain text for any unknown
      # extension, and the contents left for Ollama and then sat in the index in
      # clear, retrievable by search. What may be indexed is a decision for the
      # configuration, not for whatever the agent was just told to do.
      private def ensure_within_configured_roots(expanded : String) : Nil
        roots = @config.resolved_paths
        return if roots.any? { |root| expanded == root || expanded.starts_with?(root.chomp(File::SEPARATOR) + File::SEPARATOR) }
        raise MCP::ToolError.new(
          "#{expanded} is outside the configured paths; add its directory to `paths:` " \
          "in the configuration file to make it indexable")
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
