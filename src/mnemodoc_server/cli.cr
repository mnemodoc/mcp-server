module MnemodocServer
  # Mixin that prints an error message to stderr and exits with status 1.
  # Included by subcommands that need uniform error handling for recoverable
  # failures such as Ollama connection errors.
  module CLIErrorHandling
    private def handle_error(ex : Exception) : NoReturn
      STDERR.puts "Error: #{ex.message}"
      exit 1
    end
  end

  # Root Admiral command that registers all subcommands.
  # Prints the help text when invoked without a subcommand.
  class CLI < Admiral::Command
    define_version MnemodocServer.version
    define_help description: "mnemodoc-server — MCP server for documentation search"

    # Starts the MCP server in either stdio or HTTP/SSE mode.
    # Stdio is the default and is required for Claude Code; SSE is used by
    # Cursor and other HTTP-capable MCP clients.
    # The store is closed in the ensure block even if the transport raises.
    class Serve < Admiral::Command
      include CLIErrorHandling
      define_help description: "Start the MCP server (stdio or SSE)"

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
      define_flag stdio : Bool, long: "stdio", default: false, description: "Use stdio transport (for Claude Code)" # ameba:disable Lint/UselessAssign
      define_flag sse : Bool, long: "sse", default: false, description: "Use HTTP/SSE transport"                    # ameba:disable Lint/UselessAssign
      define_flag port : Int32, long: "port", default: 0, description: "SSE port override (0 = use config)"         # ameba:disable Lint/UselessAssign
      define_flag host : String, long: "host", default: "", description: "SSE bind address override (e.g. 0.0.0.0)" # ameba:disable Lint/UselessAssign

      def run
        store : Store::SQLite? = nil
        embedder : Indexer::Embedder? = nil
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config

        if flags.port > 0
          config.server.sse_port = flags.port
        end
        unless flags.host.empty?
          config.server.sse_host = flags.host
        end

        Dir.mkdir_p(File.dirname(config.db_path))
        store = Store::SQLite.new(config.db_path, vec0: config.search.backend != "qdrant")
        # Non-nil binding so the background fiber captures a typed store
        active_store = store
        qi = MnemodocServer.qdrant_index(config)

        built = ToolRegistry.build(config, store, qi)
        server = built[:server]
        embedder = built[:embedder]

        # Index configured paths in the background so the server is immediately
        # responsive; unchanged files are skipped via mtime so restarts are cheap.
        # Use resolved_paths so relative entries are anchored to the config file's
        # directory rather than the process working directory.
        spawn do
          idx_embedder = Indexer::Embedder.new(config.ollama)
          registry = Indexer::Format::Registry.new(config)
          crawler = Indexer::Crawler.new(config.resolved_paths, registry, config.exclude, qdrant_index: qi)
          if active_store.model_mismatch?(config.ollama.model)
            Log.warn { "embedding model changed; clearing index for a full re-index" }
            active_store.clear_index!
            qi.try(&.clear)
          end
          qi.try { |index| MnemodocServer.ensure_qdrant!(index, active_store) }
          index_result = crawler.run(active_store, idx_embedder, SingleFlight.new, concurrency: config.index.concurrency)
          active_store.embedding_model = config.ollama.model
          Log.info { "startup indexing: #{index_result[:indexed]} indexed, #{index_result[:skipped]} skipped, #{index_result[:pruned]} pruned" }
        rescue ex
          Log.error { "startup indexing failed: #{ex.message}" }
        end

        # stdio is the default; SSE must be explicitly requested with --sse.
        if flags.stdio || !flags.sse
          transport = MCP::Stdio.new(server)
        else
          transport = MCP::Http.new(server, host: config.server.sse_host, port: config.server.sse_port)
        end
        transport.on_ready { SystemD.ready }
        transport.on_stopping { SystemD.stopping }
        Signal::TERM.trap { transport.stop }
        Signal::USR1.trap { MnemodocServer.reopen_log_file! }
        transport.start
      ensure
        embedder.try(&.close)
        store.try(&.close)
        MnemodocServer.close_log_file!
      end
    end

    # Crawls and indexes a file or directory, computing Ollama embeddings for
    # each Markdown chunk and persisting them to the SQLite store.
    # Files whose mtime has not changed since the last run are skipped.
    class Index < Admiral::Command
      include CLIErrorHandling
      define_help description: "Index a file or directory"

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
      define_argument path : String, description: "File or directory to index", required: true # ameba:disable Lint/UselessAssign

      def run
        store : Store::SQLite? = nil
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        store = Store::SQLite.new(config.db_path, vec0: config.search.backend != "qdrant")
        embedder = Indexer::Embedder.new(config.ollama)
        registry = Indexer::Format::Registry.new(config)
        sf = SingleFlight.new
        qi = MnemodocServer.qdrant_index(config)

        # The crawler handles a file or a directory directly.
        expanded = File.expand_path(arguments.path)
        crawler = Indexer::Crawler.new([expanded], registry, config.exclude, qdrant_index: qi)
        if store.model_mismatch?(config.ollama.model)
          Log.warn { "embedding model changed; clearing index for a full re-index" }
          store.clear_index!
          qi.try(&.clear)
        end
        qi.try { |index| MnemodocServer.ensure_qdrant!(index, store) }
        index_result = crawler.run(store, embedder, sf, concurrency: config.index.concurrency)
        store.embedding_model = config.ollama.model
        # Summary audit line, parity with the Serve background-indexing path.
        Log.info { "indexing: #{index_result[:indexed]} indexed, #{index_result[:skipped]} skipped, #{index_result[:pruned]} pruned" }
        puts "Indexed: #{index_result[:indexed]} files, skipped: #{index_result[:skipped]} (up to date), pruned: #{index_result[:pruned]}"
      rescue ex : Indexer::EmbedderError
        handle_error(ex)
      ensure
        store.try(&.close)
      end
    end

    # Runs a hybrid search query against the local index and prints the top
    # results as a formatted table. Intended for manual exploration and debugging
    # rather than programmatic use.
    class Search < Admiral::Command
      include CLIErrorHandling
      define_help description: "Search the index from the terminal"

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
      define_flag mode : String, long: "mode", default: "hybrid", description: "Search mode: hybrid|semantic|keyword" # ameba:disable Lint/UselessAssign
      define_flag top : Int32, long: "top", default: 5, description: "Number of results"                              # ameba:disable Lint/UselessAssign
      define_argument query : String, description: "Search query", required: true                                     # ameba:disable Lint/UselessAssign

      def run
        store : Store::SQLite? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        config.search.mode = flags.mode
        config.search.top_k = flags.top

        store = Store::SQLite.new(config.db_path, vec0: config.search.backend != "qdrant")
        embedder = Indexer::Embedder.new(config.ollama)

        query_vec = embedder.embed_batch([arguments.query]).first
        hybrid = MnemodocServer::Search::Hybrid.new(config.search, MnemodocServer.qdrant_index(config))
        results = hybrid.search(arguments.query, query_vec, store)
        # Diagnostic trace for tuning relevance; off at the default info level.
        Log.debug { "query=#{arguments.query.inspect} mode=#{flags.mode} top_k=#{flags.top} → #{results.size} results" }

        table = Tallboy.table do
          columns(header: true) do
            add "score", width: 8, align: :right
            add "file", width: 40
            add "heading"
          end
          results.each do |search_result|
            row [search_result.score.round(4).to_s, search_result.chunk.file_path, search_result.chunk.heading || "(top)"]
          end
        end
        puts table
      rescue ex : Indexer::EmbedderError
        handle_error(ex)
      ensure
        store.try(&.close)
      end
    end

    # Prints a summary of the current index: version, database path, file count,
    # chunk count, and the configured Ollama endpoint.
    class Status < Admiral::Command
      include CLIErrorHandling
      define_help description: "Show index status"

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"

      def run
        store : Store::SQLite? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        store = Store::SQLite.new(config.db_path, vec0: config.search.backend != "qdrant")
        files = store.list_files

        puts "mnemodoc-server #{MnemodocServer.version}"
        puts "DB: #{config.db_path}"
        puts "Files indexed: #{files.size}"
        puts "Chunks: #{store.chunk_count}"
        puts "Ollama: #{config.ollama.host} (#{config.ollama.model})"
      ensure
        store.try(&.close)
      end
    end

    # Removes a single file and all its associated chunks from the SQLite store.
    class Delete < Admiral::Command
      include CLIErrorHandling
      define_help description: "Remove a file from the index"

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
      define_argument path : String, description: "File path to remove", required: true # ameba:disable Lint/UselessAssign

      def run
        store : Store::SQLite? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        store = Store::SQLite.new(config.db_path, vec0: config.search.backend != "qdrant")
        resolved = store.indexed_path_for(arguments.path)
        if resolved.nil?
          # Distinct from the success path: a no-op, never a misleading "deleted" INFO.
          Log.debug { "delete skipped: '#{arguments.path}' not found in index" }
          puts "Not found in index: #{arguments.path}"
        else
          # Chunk count captured before deletion (CASCADE wipes the rows) so the
          # audit line mirrors the crawler's and the MCP delete tool's style.
          chunk_count = store.chunk_ids_for_file(resolved).size
          store.delete_file(resolved)
          Log.info { "deleted #{resolved} (#{chunk_count} chunks, manual removal via CLI)" }
          puts "Deleted: #{resolved}"
        end
      ensure
        store.try(&.close)
      end
    end

    # Resolves which role to adopt for the current files/task/query and prints
    # the role's markdown to stdout. This is the command-line counterpart of the
    # get_project_context MCP tool: both channels share one Roles::Selector
    # (built via Selector.from_config), so role selection has a single source of
    # truth. The mechanical PreToolUse hook uses this command because it runs
    # outside an MCP session and so cannot call the tool.
    class Context < Admiral::Command
      include CLIErrorHandling
      define_help description: "Select and print the role to adopt for the current context"

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
      define_flag files : Array(String), long: "files", description: "Path of a file being worked on (repeatable)"    # ameba:disable Lint/UselessAssign
      define_flag task : String, long: "task", default: "", description: "Kind of task (debug, implement, refactor…)" # ameba:disable Lint/UselessAssign
      define_flag query : String, long: "query", default: "", description: "The user's current request or question"   # ameba:disable Lint/UselessAssign

      def run
        embedder : Indexer::Embedder? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        embedder = Indexer::Embedder.new(config.ollama)
        selector = Roles::Selector.from_config(config, embedder)
        selection = selector.select(flags.files.to_a, flags.task, flags.query)
        # Audit trail for role injection, written to server.log_file (never stdout,
        # which the PreToolUse hook consumes as the role markdown).
        Log.for("mnemodoc-server.context").info {
          "role=#{selection.role.name} reason=#{selection.reason.inspect}" \
          " files=#{flags.files.to_a.inspect} task=#{flags.task.inspect}" \
          " query=#{flags.query.inspect}"
        }
        # The role markdown goes to stdout verbatim so the hook injects it as-is.
        puts selection.role.content
      rescue ex : Roles::NoRolesError | Roles::NeedSignalError | File::Error | Indexer::EmbedderError
        handle_error(ex)
      ensure
        embedder.try(&.close)
      end
    end

    # Prints the application version and the full Crystal compiler description,
    # useful for bug reports and build reproducibility checks.
    class Info < Admiral::Command
      define_help description: "Show version and build info"
      define_flag licenses : Bool, description: "Print bundled third-party license texts", default: false # ameba:disable Lint/UselessAssign

      def run
        puts "version: #{MnemodocServer.version}"
        puts
        puts "crystal:"
        puts Crystal::DESCRIPTION

        if flags.licenses
          MnemodocServer::Licenses.files.each do |file|
            puts
            puts "=== #{file.path} ==="
            puts file.gets_to_end
          end
        end
      end
    end

    register_sub_command serve, Serve, description: "Start the MCP server"
    register_sub_command index, Index, description: "Index a file or directory"
    register_sub_command search, Search, description: "Search the index"
    register_sub_command status, Status, description: "Show index status"
    register_sub_command delete, Delete, description: "Remove a file from the index"
    register_sub_command context, Context, description: "Select and print the role for the current context"
    register_sub_command info, Info, description: "Show version and build info"

    # Prints the top-level help text when no subcommand is given.
    def run
      puts help
    end
  end
end
