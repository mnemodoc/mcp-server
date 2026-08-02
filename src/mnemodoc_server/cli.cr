module MnemodocServer
  # Mixin that reports an error and exits with status 1. Under --json the
  # message is emitted as a JSON object, still on stderr and never on stdout:
  # stdout then only ever carries results, so a consumer parsing it cannot
  # mistake a failure for data.
  module CLIErrorHandling
    private def handle_error(ex : Exception, json : Bool = false) : NoReturn
      if json
        STDERR.puts({"error" => ex.message.to_s}.to_json)
      else
        STDERR.puts "Error: #{ex.message}"
      end
      exit 1
    end
  end

  # Mixin routing a subcommand's result to one of three outputs: the JSON
  # payload, the human-readable text, or nothing at all under --quiet (where
  # the exit code carries the outcome instead).
  #
  # Payloads evolve additively — fields may be added, never removed or renamed —
  # so consumers keep working without a schema version to negotiate.
  module CLIOutput
    private def emit(payload, *, json : Bool, quiet : Bool, &human : -> Nil) : Nil
      return if quiet
      if json
        puts payload.to_json
      else
        human.call
      end
    end
  end

  # Mixin building the progress reporter for the commands that crawl.
  #
  # Progress is a courtesy to a human watching a long run, so it goes to
  # stderr — stdout carries results and nothing else — and it is switched off
  # entirely wherever the output is meant for a program: under --json and
  # under --quiet.
  #
  # Off a terminal it is not suppressed but degraded: each phase is stated
  # once, with no bar, no percentage and no control character, so a CI log
  # still shows the run is alive without being filled with carriage returns.
  #
  # The TTY decision is taken here, once, and injected: the reporter itself
  # never consults the process's streams, which is what makes it testable.
  #
  # Progress and the log may both be headed for stderr, and only one of them
  # can own it — a bar that rewrites its line and an entry written over it
  # leave neither readable. Three cases, in order:
  #
  # - the log goes somewhere else (a file, stdout): nothing can collide, so
  #   both run untouched;
  # - the log is at debug or trace on stderr: the detail was explicitly asked
  #   for, so it keeps the stream and there is no bar at all;
  # - otherwise: the bar owns the stream and info-level entries are held back
  #   until it comes down, warnings and errors still passing through.
  module CLIProgress
    private def with_indexing_progress(json : Bool, quiet : Bool, &)
      reporter = build_progress(json, quiet)
      # Only a bar rewriting its own line can be trampled: off a terminal the
      # rendering is plain, nothing collides, and the log stays whole.
      MnemodocServer.hush_log! if reporter && STDERR.tty? && log_shares_stderr?
      phases = Progress::Indexing.new(reporter)
      begin
        yield phases
      ensure
        # Closes whatever phase is still open, including on the way out of a
        # failure: a half-drawn bar left above an error message would read as
        # if the run were still going.
        phases.finish
        MnemodocServer.release_log!
      end
    end

    private def build_progress(json : Bool, quiet : Bool) : Progress?
      return nil if json || quiet
      return nil if verbose_log_on_stderr?
      Progress.new(STDERR, tty: STDERR.tty?)
    end

    private def log_shares_stderr? : Bool
      MnemodocServer.config.server.log_file.downcase.in?("stderr", "")
    end

    # Deliberately not conditioned on a terminal: whoever asked for debug asked
    # for the log, and the answer should not depend on where it is being read.
    # It also keeps the rule reachable from a spec, which a TTY-only branch
    # would not be.
    private def verbose_log_on_stderr? : Bool
      return false unless log_shares_stderr?
      severity = ::Log::Severity.parse?(MnemodocServer.config.server.log_level)
      return false unless severity
      severity < ::Log::Severity::Info
    end
  end

  # Root Admiral command that registers all subcommands.
  # Prints the help text when invoked without a subcommand.
  class CLI < Admiral::Command
    define_version MnemodocServer.version_line
    define_help description: "mnemodoc-server — MCP server for documentation search"

    # Starts the MCP server in either stdio or HTTP/SSE mode.
    # Stdio is the default and is required for Claude Code; SSE is used by
    # Cursor and other HTTP-capable MCP clients.
    # The store is closed in the ensure block even if the transport raises.
    class Serve < Admiral::Command
      include CLIErrorHandling
      define_help description: "Start the MCP server (stdio or SSE)"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      define_flag stdio : Bool, long: "stdio", default: false, description: "Use stdio transport (for Claude Code)" # ameba:disable Lint/UselessAssign
      define_flag sse : Bool, long: "sse", default: false, description: "Use HTTP/SSE transport"                    # ameba:disable Lint/UselessAssign
      define_flag port : Int32, long: "port", default: 0, description: "SSE port override (0 = use config)"         # ameba:disable Lint/UselessAssign
      define_flag host : String, long: "host", default: "", description: "SSE bind address override (e.g. 0.0.0.0)" # ameba:disable Lint/UselessAssign
      # Internal flag: run as the per-project daemon serving over the UNIX socket.
      # Not intended for direct use — launched programmatically by the proxy (lot 5).
      define_flag daemon : Bool, long: "daemon", default: false, description: "Internal: run as the per-project daemon (UNIX socket)" # ameba:disable Lint/UselessAssign

      def run
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config

        if flags.port > 0
          config.server.sse_port = flags.port
        end
        unless flags.host.empty?
          config.server.sse_host = flags.host
        end

        # Daemon mode: own the project index and serve over the UNIX socket.
        # Checked first so --daemon takes precedence over --stdio/--sse.
        if flags.daemon
          MnemodocServer::Daemon.new(config).run
          return
        end

        # SSE must be explicitly requested with --sse.
        if !flags.stdio && flags.sse
          MnemodocServer.serve_sse(config)
        elsif config.server.daemon? && MnemodocServer.project_initialized?
          # Default stdio path: proxy to (or auto-spawn) the per-project daemon.
          # The daemon is spawned with the *resolved* config path, not the raw
          # flag, so it loads this project rather than re-running discovery from
          # the working directory it happens to inherit.
          MnemodocServer::DaemonProxy.new(config, MnemodocServer.config_file).run
        else
          # Daemon disabled, or no project here at all. In the latter case there
          # is nothing for a daemon to own, and spawning one would create the
          # very index directory the marker is meant to withhold.
          MnemodocServer.serve_stdio(config)
        end
      rescue ex : Indexer::EmbedderError
        handle_error(ex)
      ensure
        MnemodocServer.close_log_file!
      end
    end

    # Registers MnemoDoc with an MCP client — once, globally. Per-project setup
    # is `init`'s job; this command only has to be run again when the binary
    # moves.
    class InstallCommand < Admiral::Command
      include CLIErrorHandling
      define_help description: "Register mnemodoc-server with an MCP client"

      # The only client whose full wiring — MCP entry plus both hooks — is
      # documented and verified here. Others are rejected by name rather than
      # written blind.
      TARGETS = %w(claude)

      # ameba:disable Lint/UselessAssign
      define_flag target : String, long: "target", default: "claude", description: "Client to configure (claude)"
      # ameba:disable Lint/UselessAssign
      define_flag yes : Bool, long: "yes", short: "y", default: false, description: "Do not ask for confirmation"
      # ameba:disable Lint/UselessAssign
      define_flag print_config : Bool, long: "print-config", default: false, description: "Show every change without writing anything"
      # ameba:disable Lint/UselessAssign
      define_flag no_hooks : Bool, long: "no-hooks", default: false, description: "Register the MCP server only; add no hooks"
      # ameba:disable Lint/UselessAssign
      define_flag no_permissions : Bool, long: "no-permissions", default: false, description: "Do not pre-approve the read-only tools"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"
      # ameba:disable Lint/UselessAssign
      define_flag quiet : Bool, long: "quiet", default: false, description: "Print nothing; report through the exit code"

      def run
        installer = build_installer
        changes = installer.plan

        if flags.print_config
          print_plan(changes)
          return
        end

        unless flags.yes
          print_plan(changes)
          print "Apply? [y/N] "
          answer = gets.try(&.strip.downcase)
          unless answer == "y" || answer == "yes"
            puts "Nothing written." unless flags.quiet
            return
          end
        end

        installer.apply
        report(changes.keys)
      rescue ex : Install::UnreadableTarget
        handle_error(ex, json: flags.json)
      end

      # Builds the installer, rejecting an unknown target by name rather than
      # writing a configuration shape nobody verified.
      private def build_installer : Install::ClaudeCode
        unless TARGETS.includes?(flags.target)
          handle_error(Exception.new("unknown target '#{flags.target}'; known targets: #{TARGETS.join(", ")}"), json: flags.json)
        end
        Install::ClaudeCode.new(
          binary: Process.executable_path || "mnemodoc-server",
          hooks: !flags.no_hooks,
          permissions: !flags.no_permissions,
        )
      end

      # Shows the full resulting content of every file, not a summary: a dry run
      # that under-reports invites trust it has not earned.
      private def print_plan(changes : Hash(String, String)) : Nil
        return if flags.quiet
        changes.each do |path, content|
          puts "########## #{path}"
          puts content
        end
      end

      private def report(paths : Array(String)) : Nil
        return if flags.quiet
        if flags.json
          puts({installed: true, files: paths}.to_json)
        else
          puts "Registered mnemodoc with Claude Code:"
          paths.each { |path| puts "  #{path}" }
          puts "Run `mnemodoc-server init` in a project to index it."
        end
      end
    end

    # Undoes what `install` wrote, and only that.
    class UninstallCommand < Admiral::Command
      include CLIErrorHandling
      define_help description: "Remove mnemodoc-server from an MCP client's configuration"

      # ameba:disable Lint/UselessAssign
      define_flag target : String, long: "target", default: "claude", description: "Client to clean up (claude)"
      # ameba:disable Lint/UselessAssign
      define_flag yes : Bool, long: "yes", short: "y", default: false, description: "Do not ask for confirmation"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"
      # ameba:disable Lint/UselessAssign
      define_flag quiet : Bool, long: "quiet", default: false, description: "Print nothing; report through the exit code"

      def run
        unless InstallCommand::TARGETS.includes?(flags.target)
          handle_error(Exception.new("unknown target '#{flags.target}'; known targets: #{InstallCommand::TARGETS.join(", ")}"), json: flags.json)
        end

        unless flags.yes
          print "Remove mnemodoc from Claude Code's configuration? [y/N] "
          answer = gets.try(&.strip.downcase)
          unless answer == "y" || answer == "yes"
            puts "Nothing changed." unless flags.quiet
            return
          end
        end

        Install::ClaudeCode.new(binary: Process.executable_path || "mnemodoc-server").remove
        return if flags.quiet
        if flags.json
          puts({uninstalled: true}.to_json)
        else
          puts "Removed mnemodoc from Claude Code's configuration."
        end
      rescue ex : Install::UnreadableTarget
        handle_error(ex, json: flags.json)
      end
    end

    # Turns the current directory into a MnemoDoc project: creates the marker,
    # generates a configuration from what is actually there, and builds the
    # first index.
    #
    # This is the only command that creates the marker. Everything on the
    # serving path deliberately refuses to, so that a server registered once and
    # globally cannot sprout an index in every directory a session opens in.
    class Init < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      include CLIProgress
      define_help description: "Initialise a MnemoDoc project in the current directory"

      # ameba:disable Lint/UselessAssign
      define_flag force : Bool, long: "force", default: false, description: "Regenerate .mnemodoc.yml even if one exists"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"
      # ameba:disable Lint/UselessAssign
      define_flag quiet : Bool, long: "quiet", default: false, description: "Print nothing; report through the exit code"

      def run
        # Declared up front so the ensure block can close it even when the
        # bootstrap below raises before a store is ever opened.
        # ameba:disable Lint/UselessAssign
        store : Store::SQLite? = nil
        project = Project.initialize_at(Dir.current, force: flags.force)

        # Load through the normal bootstrap so the first index runs against
        # exactly the configuration every later invocation will see.
        MnemodocServer.init_app!(project[:config])
        config = MnemodocServer.config
        store = MnemodocServer.open_store(config)
        started_at = Time.instant
        indexed = index_project(config, store)
        elapsed = Time.instant - started_at

        payload = {
          project:        project[:project],
          config:         project[:config],
          config_written: project[:config_written],
          paths:          project[:paths],
          files_indexed:  indexed,
          elapsed_ms:     elapsed.total_milliseconds.round.to_i,
        }
        emit(payload, json: flags.json, quiet: flags.quiet) do
          puts "Initialised MnemoDoc project at #{project[:project]}"
          puts "  paths:   #{project[:paths].join(", ")}"
          puts "  config:  #{project[:config]}#{project[:config_written] ? "" : " (kept as it was)"}"
          puts "  indexed: #{indexed} file(s) in #{MnemodocServer.format_duration(elapsed)}"
        end
      rescue ex : Indexer::EmbedderError
        handle_error(ex, json: flags.json)
      ensure
        store.try(&.close)
      end

      # Runs the first crawl. Embedding failures are already tolerated by the
      # crawler, so a project can be initialised before Ollama is up and filled
      # in later — the marker and the configuration are the durable part.
      private def index_project(config : Config, store : Store::SQLite) : Int32
        embedder = Indexer::Embedder.new(config.ollama)
        registry = Indexer::Format::Registry.new(config)
        qi = MnemodocServer.qdrant_index(config)
        qi.try { |index| MnemodocServer.ensure_qdrant!(index, store) }
        crawler = Indexer::Crawler.new(config.resolved_paths, registry, config.exclude, qdrant_index: qi)
        result = with_indexing_progress(json: flags.json, quiet: flags.quiet) do |phases|
          crawler.run(store, embedder, SingleFlight.new, concurrency: config.index.concurrency,
            progress: phases.index, scan_progress: phases.scan)
        end
        store.embedding_model = config.ollama.model
        embedder.close
        result[:indexed]
      end
    end

    # Removes the project marker, and only that. The generated configuration
    # stays: it is the versionable half of a project, while the index is local
    # and rebuildable by re-running `init`.
    class Uninit < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      define_help description: "Remove the MnemoDoc project marker from the current directory"

      # ameba:disable Lint/UselessAssign
      define_flag yes : Bool, long: "yes", short: "y", default: false, description: "Do not ask for confirmation"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"
      # ameba:disable Lint/UselessAssign
      define_flag quiet : Bool, long: "quiet", default: false, description: "Print nothing; report through the exit code"

      def run
        root = MnemodocServer.discover_project(Dir.current)
        unless root
          handle_error(Exception.new("no MnemoDoc project found at or above #{Dir.current}"), json: flags.json)
        end

        unless flags.yes
          print "Remove the index at #{File.join(root, MnemodocServer::PROJECT_MARKER)}? [y/N] "
          answer = gets.try(&.strip.downcase)
          unless answer == "y" || answer == "yes"
            emit({removed: false, project: root}, json: flags.json, quiet: flags.quiet) { puts "Left untouched." }
            return
          end
        end

        Project.remove_marker(root)
        emit({removed: true, project: root}, json: flags.json, quiet: flags.quiet) do
          puts "Removed the index at #{File.join(root, MnemodocServer::PROJECT_MARKER)}; #{File.join(root, ".mnemodoc.yml")} was kept."
        end
      end
    end

    # Crawls and indexes a file or directory, computing Ollama embeddings for
    # each Markdown chunk and persisting them to the SQLite store.
    # Files whose mtime has not changed since the last run are skipped.
    class Index < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      include CLIProgress
      define_help description: "Index a file or directory"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"
      # ameba:disable Lint/UselessAssign
      define_flag quiet : Bool, long: "quiet", default: false, description: "Print nothing; report through the exit code"
      define_argument path : String, description: "File or directory to index", required: true # ameba:disable Lint/UselessAssign

      def run
        store : Store::SQLite? = nil
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        store = MnemodocServer.open_store(config)
        embedder = Indexer::Embedder.new(config.ollama, idle_connections: config.index.concurrency)
        registry = Indexer::Format::Registry.new(config)
        sf = SingleFlight.new
        qi = MnemodocServer.qdrant_index(config)

        # The crawler handles a file or a directory directly.
        expanded = File.expand_path(arguments.path)
        crawler = Indexer::Crawler.new([expanded], registry, config.exclude, qdrant_index: qi)
        # Purging only makes sense when what follows rebuilds the whole index.
        # Here the crawl covers one path, so clearing would empty the index,
        # refill that path, and record the new model — erasing the mark that
        # would have made the next full crawl rebuild the rest. Indexing without
        # clearing is no better: it mixes vectors from two models in one index.
        if store.model_mismatch?(config.ollama.model)
          stored = store.embedding_model || "unknown"
          handle_error(
            Exception.new(
              "index was built with embedding model '#{stored}' and the configuration now uses " \
              "'#{config.ollama.model}': every stored vector is stale. Delete #{config.db_path} " \
              "to rebuild from scratch."),
            json: flags.json)
        end
        qi.try { |index| MnemodocServer.ensure_qdrant!(index, store) }
        started_at = Time.instant
        index_result = with_indexing_progress(json: flags.json, quiet: flags.quiet) do |phases|
          crawler.run(store, embedder, sf, concurrency: config.index.concurrency,
            progress: phases.index, scan_progress: phases.scan)
        end
        elapsed = Time.instant - started_at
        store.embedding_model = config.ollama.model
        # Summary audit line, parity with the Serve background-indexing path.
        Log.info { "indexing: #{index_result[:indexed]} indexed, #{index_result[:skipped]} skipped, #{index_result[:pruned]} pruned" }
        payload = {
          indexed:    index_result[:indexed],
          skipped:    index_result[:skipped],
          pruned:     index_result[:pruned],
          failed:     index_result[:failed],
          elapsed_ms: elapsed.total_milliseconds.round.to_i,
        }
        emit(payload, json: flags.json, quiet: flags.quiet) do
          puts "Indexed: #{index_result[:indexed]} files, skipped: #{index_result[:skipped]} (up to date), pruned: #{index_result[:pruned]} — #{MnemodocServer.format_duration(elapsed)}"
          puts "Failed to embed: #{index_result[:failed]} chunk(s)" if index_result[:failed] > 0
        end

        # A run that embedded nothing at all, having tried, is a failure — the
        # usual cause being an unreachable Ollama. It used to exit 0 with
        # "Indexed: 0 files", and under --quiet with no output whatsoever, so a
        # deployment script reading the exit code believed the index current.
        # A run with simply nothing to do still succeeds.
        if index_result[:failed] > 0 && index_result[:indexed] == 0
          message = "nothing could be indexed (#{index_result[:failed]} chunk(s) failed to embed)"
          # Same shape as every other CLI failure: JSON on stderr under --json,
          # plain text otherwise, and stdout left to carry the counters.
          unless flags.quiet
            STDERR.puts(flags.json ? {"error" => message}.to_json : "Error: #{message}")
          end
          exit 1
        end
      rescue ex : Indexer::EmbedderError
        handle_error(ex, json: flags.json)
      ensure
        store.try(&.close)
      end
    end

    # Runs a hybrid search query against the local index. Prints a formatted
    # table for manual exploration, or the full results — chunk bodies included,
    # which the table omits — as JSON for programmatic use.
    class Search < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      define_help description: "Search the index from the terminal"

      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the results as JSON, including chunk bodies"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      define_flag mode : String, long: "mode", default: "hybrid", description: "Search mode: hybrid|semantic|keyword" # ameba:disable Lint/UselessAssign
      define_flag top : Int32, long: "top", default: 5, description: "Number of results"                              # ameba:disable Lint/UselessAssign
      define_argument query : String, description: "Search query", required: true                                     # ameba:disable Lint/UselessAssign

      def run
        store : Store::SQLite? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        config.search.mode = flags.mode
        config.search.top_k = flags.top

        store = MnemodocServer.open_store(config)
        embedder = Indexer::Embedder.new(config.ollama)

        query_vec = embedder.embed_batch([arguments.query]).first
        hybrid = MnemodocServer::Search::Hybrid.new(config.search, MnemodocServer.qdrant_index(config))
        results = hybrid.search(arguments.query, query_vec, store)
        # Diagnostic trace for tuning relevance; off at the default info level.
        Log.debug { "query=#{arguments.query.inspect} mode=#{flags.mode} top_k=#{flags.top} → #{results.size} results" }

        # Not deduplicated here: the recorder does it for every caller, which is
        # what keeps this surface and the MCP one reporting the same figure.
        Usage::Recorder.record(config, source: "cli", action: "query_documents",
          query: arguments.query, result_count: results.size, elapsed_ms: nil,
          files: results.map(&.chunk.file_path))

        payload = {
          query: arguments.query,
          mode:  flags.mode,
          top_k: flags.top,
          # Same key names and rounding as the query_documents MCP tool, so both
          # surfaces speak one vocabulary.
          results: results.map do |search_result|
            {
              file:           search_result.chunk.file_path,
              heading:        search_result.chunk.heading,
              parent_heading: search_result.chunk.parent_heading,
              content:        search_result.chunk.content,
              score:          search_result.score.round(4),
              # Calibrated cosine, comparable across queries — unlike score,
              # which is a rank artifact. nil for a keyword-only match.
              similarity: search_result.similarity.try(&.round(4)),
            }
          end,
        }
        # The table is built inside the human branch so --json never pays for
        # rendering it.
        emit(payload, json: flags.json, quiet: false) do
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
        end
      rescue ex : Indexer::EmbedderError
        handle_error(ex, json: flags.json)
      ensure
        store.try(&.close)
      end
    end

    # Prints a summary of the current index: version, database path, file count,
    # chunk count, and the configured Ollama endpoint.
    class Status < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      define_help description: "Show index status"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"

      def run
        store : Store::SQLite? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        store = MnemodocServer.open_store(config)
        files = store.list_files

        chunks = store.chunk_count
        payload = {
          version: MnemodocServer.version,
          db_path: config.db_path,
          files:   files.size,
          chunks:  chunks,
          ollama:  {host: config.ollama.host, model: config.ollama.model},
        }
        emit(payload, json: flags.json, quiet: false) do
          puts MnemodocServer.version_line
          puts "DB: #{config.db_path}"
          puts "Files indexed: #{files.size}"
          puts "Chunks: #{chunks}"
          puts "Ollama: #{config.ollama.host} (#{config.ollama.model})"
        end
      ensure
        store.try(&.close)
      end
    end

    # Removes a single file and all its associated chunks from the SQLite store.
    class Delete < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      define_help description: "Remove a file from the index"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"
      # ameba:disable Lint/UselessAssign
      define_flag quiet : Bool, long: "quiet", default: false, description: "Print nothing; report through the exit code"
      define_argument path : String, description: "File path to remove", required: true # ameba:disable Lint/UselessAssign

      def run
        store : Store::SQLite? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        store = MnemodocServer.open_store(config)
        resolved = store.indexed_path_for(arguments.path)
        if resolved.nil?
          # Distinct from the success path: a no-op, never a misleading "deleted" INFO.
          Log.debug { "delete skipped: '#{arguments.path}' not found in index" }
          # Exit code stays 0, as before the flags existed: changing it would
          # silently break any current caller.
          emit({found: false, path: arguments.path}, json: flags.json, quiet: flags.quiet) do
            puts "Not found in index: #{arguments.path}"
          end
        else
          # Chunk count captured before deletion (CASCADE wipes the rows) so the
          # audit line mirrors the crawler's and the MCP delete tool's style.
          chunk_count = store.chunk_ids_for_file(resolved).size
          store.delete_file(resolved)
          Log.info { "deleted #{resolved} (#{chunk_count} chunks, manual removal via CLI)" }
          emit({found: true, path: resolved, chunks: chunk_count}, json: flags.json, quiet: flags.quiet) do
            puts "Deleted: #{resolved}"
          end
        end
      ensure
        store.try(&.close)
      end
    end

    # Prints an indexed document's heading plan. The command-line counterpart of
    # the outline_document MCP tool, which it delegates to outright so the two
    # surfaces cannot answer differently.
    class Outline < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      define_help description: "Print an indexed document's heading plan"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the plan as JSON"
      define_argument path : String, description: "Path of an indexed file", required: true # ameba:disable Lint/UselessAssign

      def run
        store : Store::SQLite? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        opened = store = MnemodocServer.open_store(config)

        result = Tools::Outline.new(opened).call(
          {"path" => JSON::Any.new(arguments.path)} of String => JSON::Any
        )
        Usage::Recorder.record_tool(config, source: "cli", action: "outline_document",
          result: result, query: nil, elapsed_ms: nil)
        payload = result.structured_content || JSON::Any.new({} of String => JSON::Any)

        emit(payload, json: flags.json, quiet: false) do
          payload["sections"].as_a.each do |section|
            # Two spaces per level below the first, so the plan reads as the
            # nesting it describes.
            indent = "  " * (section["level"].as_i - 1)
            puts "#{section["start_line"]}\t#{indent}#{section["title"]} (#{section["lines"]} lines)"
          end
          payload["warnings"]?.try(&.as_a.each { |warning| STDERR.puts warning.as_s })
        end
      rescue ex : MCP::ToolError
        handle_error(ex, json: flags.json)
      ensure
        store.try(&.close)
      end
    end

    # Prints a numbered window of an indexed document, served from the index
    # rather than from the file. The command-line counterpart of the
    # read_document MCP tool, delegating to it for the same reason as `outline`.
    class Read < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      define_help description: "Print numbered lines of an indexed document"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the window as JSON"
      # ameba:disable Lint/UselessAssign
      define_flag offset : Int32, long: "offset", default: 1, description: "1-based first line to print"
      # ameba:disable Lint/UselessAssign
      define_flag limit : Int32, long: "limit", default: 200, description: "Maximum lines to print (max 2000)"
      define_argument path : String, description: "Path of an indexed file", required: true # ameba:disable Lint/UselessAssign

      def run
        store : Store::SQLite? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        opened = store = MnemodocServer.open_store(config)

        result = Tools::Read.new(opened).call({
          "path"   => JSON::Any.new(arguments.path),
          "offset" => JSON::Any.new(flags.offset.to_i64),
          "limit"  => JSON::Any.new(flags.limit.to_i64),
        } of String => JSON::Any)
        Usage::Recorder.record_tool(config, source: "cli", action: "read_document",
          result: result, query: nil, elapsed_ms: nil)
        payload = result.structured_content || JSON::Any.new({} of String => JSON::Any)

        emit(payload, json: flags.json, quiet: false) do
          print payload["content"].as_s
          # Staleness is the one thing a human reading raw lines cannot see, so
          # it goes to stderr rather than into the content carried by stdout.
          payload["warnings"]?.try(&.as_a.each { |warning| STDERR.puts warning.as_s })
        end
      rescue ex : MCP::ToolError
        handle_error(ex, json: flags.json)
      ensure
        store.try(&.close)
      end
    end

    # Reads the usage journal back: how the documentation is actually being
    # used, which the server log can show but not answer, since "which documents
    # never served" is a join rather than a grep.
    #
    # Four views, one at a time. Merging them would leave the payload with no
    # stable schema, so passing more than one is refused rather than combined.
    class UsageCommand < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      define_help description: "Report how the documentation is being used"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the report as JSON"
      define_flag days : Int32, long: "days", default: 0, description: "Window in days (default: usage.retention_days)"
      # ameba:disable Lint/UselessAssign
      define_flag documents : Bool, long: "documents", default: false, description: "Per document, most served first"
      # ameba:disable Lint/UselessAssign
      define_flag unused : Bool, long: "unused", default: false, description: "Indexed documents never served in the window"
      # ameba:disable Lint/UselessAssign
      define_flag misses : Bool, long: "misses", default: false, description: "Calls that returned nothing"

      def run
        store : Store::SQLite? = nil
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config

        selected = [flags.documents, flags.unused, flags.misses].count(true)
        raise ArgumentError.new("pass at most one view: --documents, --unused or --misses") if selected > 1

        opened = store = MnemodocServer.open_store(config)
        # Drains the spool first. Only the daemon imports it otherwise, so a
        # project used from the CLI alone — or running with server.daemon:
        # false — would report zeros forever while the file kept growing. The
        # rename inside import_spool makes this safe against a daemon importing
        # at the same moment: whoever renames first takes the batch.
        Usage::Collector.new(config, opened).import_spool
        days = flags.days > 0 ? flags.days : config.usage.retention_days
        since = Time.utc.to_unix - (days.to_i64 * 86_400)

        if flags.documents
          emit_documents(opened, since, days)
        elsif flags.unused
          emit_unused(opened, since, days)
        elsif flags.misses
          emit_misses(opened, since, days)
        else
          emit_summary(opened, since, days)
        end
      rescue ex : ArgumentError
        handle_error(ex, json: flags.json)
      ensure
        store.try(&.close)
      end

      private def emit_summary(store : Store::SQLite, since : Int64, days : Int32) : Nil
        summary = store.usage.summary(since)
        payload = {days: days, events: summary[:events], documents: summary[:documents],
                   silent_hooks: summary[:silent_hooks],
                   by_source: summary[:by_source], by_action: summary[:by_action]}
        emit(payload, json: flags.json, quiet: false) do
          puts "Window: #{days} days"
          puts "Calls: #{summary[:events]}"
          puts "Documents served: #{summary[:documents]}"
          puts "Hook stayed silent: #{summary[:silent_hooks]} time(s)"
          summary[:by_action].each { |action, count| puts "  #{action}: #{count}" }
        end
      end

      private def emit_documents(store : Store::SQLite, since : Int64, days : Int32) : Nil
        rows = store.usage.documents(since)
        payload = {days: days, documents: rows.map { |row|
          {path: row[:path], served: row[:served], last_at: row[:last_at]}
        }}
        emit(payload, json: flags.json, quiet: false) do
          rows.each { |row| puts "#{row[:served]}\t#{row[:path]}" }
        end
      end

      private def emit_unused(store : Store::SQLite, since : Int64, days : Int32) : Nil
        verdict = store.usage.unused(since)
        payload = {days: days, unused: verdict[:unused], too_recent: verdict[:too_recent]}
        emit(payload, json: flags.json, quiet: false) do
          verdict[:unused].each { |path| puts path }
          unless verdict[:too_recent].empty?
            puts "(indexed less than #{days} days ago, too recent to judge:)"
            verdict[:too_recent].each { |path| puts "  #{path}" }
          end
        end
      end

      private def emit_misses(store : Store::SQLite, since : Int64, days : Int32) : Nil
        rows = store.usage.misses(since)
        payload = {days: days, misses: rows.map { |row|
          {at: row[:at], source: row[:source], action: row[:action], query: row[:query]}
        }}
        emit(payload, json: flags.json, quiet: false) do
          rows.each { |row| puts "#{row[:source]}\t#{row[:action]}\t#{row[:query]}" }
        end
      end
    end

    # Resolves which role to adopt for the current files/task/query and prints
    # the role's markdown to stdout. This is the command-line counterpart of the
    # get_project_context MCP tool: both channels share one Roles::Selector
    # (built via Selector.from_config), so role selection has a single source of
    # truth. The mechanical PreToolUse hook uses this command because it runs
    # outside an MCP session and so cannot call the tool.
    # Injects the single most relevant documentation passage before the agent
    # reasons, so a passage reaches it whether or not it thinks to search.
    #
    # It runs synchronously ahead of every user message, which sets two hard
    # rules. It stays silent unless the best passage clears
    # `hook.similarity_threshold` — a cosine, comparable across queries, unlike
    # the fused score which is a rank artifact. And it never gets in the way:
    # unparseable input, unreachable Ollama, empty index, missing config all
    # print nothing and exit 0, because a hook that errors in front of the user
    # on an unrelated turn is worse than one that says nothing.
    class PromptHook < Admiral::Command
      define_help description: "Read a client hook payload on stdin and inject the best matching passage"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      # ameba:disable Lint/UselessAssign
      define_flag client : String, long: "client", default: "claude-code", description: "Hook client adapter (default claude-code)"

      def run
        store : Store::SQLite? = nil
        embedder : Indexer::Embedder? = nil

        payload = STDIN.gets_to_end
        return if payload.strip.empty?

        hook = Hooks::Registry.for(flags.client).parse(JSON.parse(payload))
        prompt = hook.query
        return if prompt.strip.empty?

        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        store = MnemodocServer.open_store(config)
        embedder = Indexer::Embedder.new(config.ollama)

        query_vec = embedder.embed_batch([prompt]).first
        results = MnemodocServer::Search::Hybrid.new(config.search, MnemodocServer.qdrant_index(config))
          .search(prompt, query_vec, store)

        chosen = MnemodocServer::Search::HookSelection.choose(results,
          similarity_threshold: config.hook.similarity_threshold,
          margin_threshold: config.hook.margin_threshold,
          max_passages: config.hook.max_passages)

        # Recorded before the early return, deliberately: a hook that chose to
        # stay silent is the event the usage summary reports as the silence
        # rate, and returning first would make it unobservable.
        Usage::Recorder.record(config, source: "hook", action: "prompt_hook",
          query: prompt, result_count: chosen.size, elapsed_ms: nil,
          files: chosen.map(&.chunk.file_path),
          session: hook.session_id, agent: hook.agent_label.presence)

        return if chosen.empty?

        Log.for("mnemodoc-server.prompt-hook").info {
          "injected #{chosen.size} passage(s): #{chosen.map(&.chunk.file_path).join(", ")}"
        }
        chosen.each { |passage| print_passage(passage) }
      rescue
        # Deliberately catch everything: this runs in the user's critical path
        # and has no business surfacing any failure of ours to them.
      ensure
        embedder.try(&.close)
        store.try(&.close)
      end

      # Framed and attributed so the model can tell this from the user's own
      # words, and can cite or discount it knowing where it came from.
      private def print_passage(result : MnemodocServer::Search::SearchResult) : Nil
        heading = result.chunk.heading.try(&.lstrip.lstrip('#').strip)
        source = File.basename(result.chunk.file_path)
        source += " › #{heading}" if heading && !heading.empty?

        puts "<project-documentation source=#{source.inspect}>"
        puts "Retrieved from this project's indexed documentation because it matches the request."
        puts
        puts result.chunk.content
        puts "</project-documentation>"
      end
    end

    class Context < Admiral::Command
      include CLIErrorHandling
      define_help description: "Select and print the role to adopt for the current context"

      define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
      define_flag files : Array(String), long: "files", description: "Path of a file being worked on (repeatable)"                                               # ameba:disable Lint/UselessAssign
      define_flag task : String, long: "task", default: "", description: "Kind of task (debug, implement, refactor…)"                                            # ameba:disable Lint/UselessAssign
      define_flag query : String, long: "query", default: "", description: "The user's current request or question"                                              # ameba:disable Lint/UselessAssign
      define_flag hook_stdin : Bool, long: "hook-stdin", default: false, description: "Read the client hook JSON from stdin and derive files/task/query from it" # ameba:disable Lint/UselessAssign
      define_flag client : String, long: "client", default: "claude-code", description: "Hook client adapter used with --hook-stdin (default claude-code)"       # ameba:disable Lint/UselessAssign
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the selection as JSON instead of the role markdown"

      def run
        embedder : Indexer::Embedder? = nil # ameba:disable Lint/UselessAssign
        MnemodocServer.init_app!(flags.config)
        config = MnemodocServer.config
        embedder = Indexer::Embedder.new(config.ollama)
        selector = Roles::Selector.from_config(config, embedder)
        input = resolve_input
        # Nothing to select on: say nothing. Exit 0 keeps the hook contract, so
        # this log line is the only trace the case leaves — see
        # `signalless_hook?` for why the default role is the wrong answer here.
        signalless = signalless_hook?(input)
        if signalless
          Log.for("mnemodoc-server.context").info {
            "event=#{input.event} hook stdin carried no signal (no files, task or query); nothing injected"
          }
          # --json exists so an empty stdout is never mistaken for a failure, so
          # that mode still reports, with `suppressed` carrying the decision.
          return unless flags.json
        end
        selection = selector.select(input.files, input.task, input.query)
        # Audit trail for role injection, written to server.log_file (never
        # stdout, which carries the hook payload). Fixed format: every field is
        # always present (empty when absent) so log parsing stays stable across
        # flags-only and hook-stdin modes.
        # The user's own words are NOT on this line. It runs at the default
        # level, and `server.log_file` is often a real file that outlives the
        # session — a prompt carrying a token or a customer name would be
        # written there in clear and stay. The length is enough to correlate an
        # entry with a turn; the text itself moves down to debug, which an
        # operator turns on deliberately and briefly.
        Log.for("mnemodoc-server.context").info {
          "event=#{input.event} role=#{selection.role.name} reason=#{selection.reason.inspect}" \
          " session=#{input.session_id} agent=#{input.agent_label.inspect}" \
          " files=#{input.files.size} task=#{input.task.inspect} query_len=#{input.query.size}"
        }
        Log.for("mnemodoc-server.context").debug {
          "transcript=#{input.transcript_path.inspect} cwd=#{input.cwd.inspect}" \
          " files=#{input.files.inspect} query=#{input.query.inspect}"
        }
        # Two reasons to stay silent, both keeping the audit line above: the
        # input carried no signal at all, or — on UserPromptSubmit alone — an
        # undecided prompt resolved to the default role, which would spend
        # context on the generalist role every single turn. The files channel
        # (PreToolUse) always emits, covering cross-cutting edits.
        suppressed = signalless || suppress_for_query?(input, selection, config)

        # Under --json the payload is always emitted, `suppressed` carrying what
        # the text mode expresses by staying silent — an empty stdout would be
        # indistinguishable from a failure. This is a diagnostic format for a
        # human or a script; the hook never passes --json, and the envelope
        # below must never leak into it.
        if flags.json
          puts({
            role:       selection.role.name,
            reason:     selection.reason,
            default:    selection.default?,
            score:      selection.score,
            suppressed: suppressed,
            candidates: selection.candidates.map { |candidate| {name: candidate.name, score: candidate.score} },
            content:    selection.role.content,
          }.to_json)
        elsif !suppressed
          emit_role(input, selection.role.content)
        end
      rescue ex : Roles::NoRolesError | Roles::NeedSignalError | File::Error | Indexer::EmbedderError | Hooks::UnknownClientError
        handle_error(ex, json: flags.json)
      ensure
        embedder.try(&.close)
      end

      # Writes the role in the shape the reader of this stream actually accepts.
      #
      # A PreToolUse hook's stdout does NOT reach the model: the client sends it
      # to its debug journal and drops it. For that event, context is only read
      # from `hookSpecificOutput.additionalContext`, so the markdown has to be
      # wrapped — printing it raw computes a role, prints it, and throws it
      # away, with no error anywhere to show for it.
      #
      # Every other case is the opposite. UserPromptSubmit stdout IS the
      # injected context, and a human running the command in a terminal wants
      # the markdown, not an envelope. Raw text therefore stays the default,
      # including for an event this code does not know.
      private def emit_role(input : Hooks::HookInput, content : String) : Nil
        if input.event == "PreToolUse"
          puts({hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: content}}.to_json)
        else
          puts content
        end
      end

      # True when --hook-stdin yielded nothing to select on: no file, no task,
      # no query. The test is the absence of signal rather than the kind of
      # failure, which is what makes it cover the three ways of getting here —
      # empty stdin, malformed JSON, and a well-formed payload for an event the
      # adapter does not handle. All three used to reach `Selector#select` with
      # every channel empty, land on its `context.default` fallback, and print
      # the generalist role with exit 0: a context nobody asked for, plausible
      # enough to be believed.
      #
      # The guard belongs here and not in `Selector`, whose fallback is correct
      # and serves callers that did ask (the get_project_context tool). And it
      # is confined to --hook-stdin: a human invoking `context` with no flags
      # asked for the default role and still gets it.
      private def signalless_hook?(input : Hooks::HookInput) : Bool
        flags.hook_stdin && input.files.empty? && input.task.empty? && input.query.empty?
      end

      # True when stdout must stay empty. Two reasons, both confined to the
      # UserPromptSubmit event: the selection is the default-role fallback, or
      # its rule score falls short of `context.min_query_score`.
      #
      # Silence, rather than the default role, is the point: this runs before
      # every user message, and injecting a generalist role on each turn spends
      # context on a prompt that gave no reason to think it needed one.
      #
      # Other events are untouched. A PreToolUse edit names a file, which is a
      # strong and unambiguous signal, so it always emits.
      private def suppress_for_query?(input : Hooks::HookInput, selection : Roles::Selection,
                                      config : Config) : Bool
        return false unless input.event == "UserPromptSubmit"
        selection.default? || selection.score < config.context.min_query_score
      end

      # Builds the selection inputs. Without --hook-stdin this is just the flags
      # (the historical behaviour). With --hook-stdin the client adapter parses
      # the piped JSON and its fields take precedence; the flags fill any gap.
      private def resolve_input : Hooks::HookInput
        unless flags.hook_stdin
          return Hooks::HookInput.new(files: flags.files.to_a, task: flags.task, query: flags.query)
        end

        # Unknown client is a wiring fault: let it raise to the rescue below.
        adapter = Hooks::Registry.for(flags.client)
        raw = STDIN.gets_to_end
        hook = begin
          adapter.parse(JSON.parse(raw))
        rescue JSON::ParseException
          Log.for("mnemodoc-server.context").debug {
            "hook stdin was empty or not valid JSON; falling back to flags"
          }
          Hooks::HookInput.new
        end
        merge(hook)
      end

      # Merges a parsed hook payload over the flags: a payload field wins when
      # present/non-empty, otherwise the corresponding flag is used.
      private def merge(hook : Hooks::HookInput) : Hooks::HookInput
        Hooks::HookInput.new(
          event: hook.event,
          files: hook.files.empty? ? flags.files.to_a : hook.files,
          task: hook.task.empty? ? flags.task : hook.task,
          query: hook.query.empty? ? flags.query : hook.query,
          session_id: hook.session_id,
          agent_id: hook.agent_id,
          agent_type: hook.agent_type,
          transcript_path: hook.transcript_path,
          cwd: hook.cwd,
        )
      end
    end

    # Prints the application version and the full Crystal compiler description,
    # useful for bug reports and build reproducibility checks.
    class Info < Admiral::Command
      include CLIOutput
      define_help description: "Show version and build info"
      define_flag licenses : Bool, description: "Print bundled third-party license texts", default: false
      # ameba:disable Lint/UselessAssign
      define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"

      def run
        # Read once: the baked-in license files are IO objects, so a second pass
        # over them would come back empty.
        licenses = flags.licenses ? MnemodocServer::Licenses.files.map { |file| {path: file.path, text: file.gets_to_end} } : nil

        # The provenance is decomposed here rather than folded into one string,
        # which is the whole difference between this command and the `--version`
        # banner: the banner is harvested by a fleet inventory and must stay on
        # one line, this is read by a human chasing down which build answered.
        # `version` is therefore the bare shard version, the rest standing on
        # its own field.
        payload = {
          version:  MnemodocServer::VERSION,
          commit:   MnemodocServer.commit,
          tag:      MnemodocServer.git_tag,
          built:    MnemodocServer::BUILT_AT,
          target:   MnemodocServer::TARGET,
          crystal:  Crystal::DESCRIPTION,
          licenses: licenses,
        }
        emit(payload, json: flags.json, quiet: false) do
          puts "version: #{MnemodocServer::VERSION}"
          puts "commit:  #{MnemodocServer.commit}"
          puts "tag:     #{MnemodocServer.git_tag}"
          puts "built:   #{MnemodocServer::BUILT_AT}"
          puts "target:  #{MnemodocServer::TARGET}"
          puts
          puts "crystal:"
          puts Crystal::DESCRIPTION

          licenses.try &.each do |license|
            puts
            puts "=== #{license[:path]} ==="
            puts license[:text]
          end
        end
      end
    end

    # Inspects and stops the per-project daemon. Both subcommands rely on the
    # liveness probe rather than the pid file alone: a hard-killed daemon leaves
    # its pid file behind, and that pid may since have been reused by an
    # unrelated process.
    class Daemon < Admiral::Command
      include CLIErrorHandling
      define_help description: "Inspect or stop the per-project daemon"

      # Reports whether a daemon is reachable on the project's socket, and with
      # what pid. Never signals anything.
      class Status < Admiral::Command
        include CLIErrorHandling
        include CLIOutput
        define_help description: "Show whether the project's daemon is running"

        define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
        # ameba:disable Lint/UselessAssign
        define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"
        # ameba:disable Lint/UselessAssign
        define_flag quiet : Bool, long: "quiet", default: false, description: "Print nothing; report through the exit code"

        # Exits 1 when no daemon is running, in the manner of `systemctl
        # is-active`, so `--quiet` is usable in a shell test. This command is
        # new, so no existing caller depends on the previous exit code.
        def run
          MnemodocServer.init_app!(flags.config)
          config = MnemodocServer.config

          enabled = config.server.daemon?
          running = enabled && MnemodocServer.daemon_healthy?(config)
          pid = running ? MnemodocServer.daemon_pid(config) : nil

          payload = {
            daemon_enabled: enabled,
            socket:         config.daemon_socket_path,
            running:        running,
            pid:            pid,
          }
          emit(payload, json: flags.json, quiet: flags.quiet) do
            unless enabled
              puts "Daemon mode is disabled (server.daemon: false); `serve --stdio` runs standalone."
              next
            end

            puts "Socket: #{config.daemon_socket_path}"
            if running
              puts "Status: running"
              puts "PID: #{pid || "unknown (pid file missing)"}"
            else
              puts "Status: not running"
            end
          end

          exit 1 unless running
        rescue ex : File::Error
          handle_error(ex, json: flags.json)
        end
      end

      # Stops the daemon with SIGTERM, then waits for the socket to stop
      # answering. Cleans up stale files instead of signalling when no daemon
      # is reachable, and never escalates to SIGKILL.
      class Stop < Admiral::Command
        include CLIErrorHandling
        include CLIOutput
        define_help description: "Stop the project's daemon"

        define_flag config : String, long: "config", short: "c", default: "", description: "Path to config file (default: discover the nearest .mnemodoc project)"
        # ameba:disable Lint/UselessAssign
        define_flag timeout : Int32, long: "timeout", default: 10, description: "Seconds to wait for the daemon to exit"
        # ameba:disable Lint/UselessAssign
        define_flag json : Bool, long: "json", default: false, description: "Emit the result as JSON"
        # ameba:disable Lint/UselessAssign
        define_flag quiet : Bool, long: "quiet", default: false, description: "Print nothing; report through the exit code"

        def run
          MnemodocServer.init_app!(flags.config)
          config = MnemodocServer.config

          # Probing before signalling is what keeps us from killing an unrelated
          # process that inherited a dead daemon's pid. The remaining window —
          # the daemon dying between this probe and the signal — is accepted.
          unless MnemodocServer.daemon_healthy?(config)
            File.delete?(config.daemon_socket_path)
            File.delete?(config.daemon_pid_path)
            emit({stopped: false, pid: nil, reason: "not running; cleaned up stale socket and pid file"},
              json: flags.json, quiet: flags.quiet) do
              puts "Daemon is not running; cleaned up stale socket and pid file."
            end
            return
          end

          pid = MnemodocServer.daemon_pid(config)
          if pid.nil?
            handle_error(
              Exception.new("daemon is running but #{config.daemon_pid_path} is missing; cannot determine its pid"),
              json: flags.json)
          end

          Process.signal(Signal::TERM, pid)
          unless MnemodocServer.await_daemon_exit(config, flags.timeout.seconds)
            handle_error(
              Exception.new("daemon (pid #{pid}) did not exit within #{flags.timeout}s; not escalating to SIGKILL"),
              json: flags.json)
          end

          emit({stopped: true, pid: pid, reason: "signalled and exited"},
            json: flags.json, quiet: flags.quiet) do
            puts "Daemon stopped (pid #{pid})."
          end
        rescue ex : File::Error | RuntimeError
          handle_error(ex, json: flags.json)
        end
      end

      register_sub_command status, Status, description: "Show whether the project's daemon is running"
      register_sub_command stop, Stop, description: "Stop the project's daemon"

      # Without this, invoking `daemon` with no subcommand raises Admiral's
      # bare "Invalid subcommand:" error instead of showing what is available.
      def run
        puts help
      end
    end

    register_sub_command install, InstallCommand, description: "Register mnemodoc with an MCP client"
    register_sub_command uninstall, UninstallCommand, description: "Remove mnemodoc from an MCP client"
    register_sub_command init, Init, description: "Initialise a MnemoDoc project here"
    register_sub_command uninit, Uninit, description: "Remove the project marker"
    register_sub_command serve, Serve, description: "Start the MCP server"
    register_sub_command index, Index, description: "Index a file or directory"
    register_sub_command search, Search, description: "Search the index"
    register_sub_command outline, Outline, description: "Print a document's heading plan"
    register_sub_command read, Read, description: "Print numbered lines of a document"
    register_sub_command usage, UsageCommand, description: "Report how the documentation is being used"
    register_sub_command status, Status, description: "Show index status"
    register_sub_command delete, Delete, description: "Remove a file from the index"
    register_sub_command context, Context, description: "Select and print the role for the current context"
    register_sub_command info, Info, description: "Show version and build info"
    register_sub_command "prompt-hook", PromptHook, description: "Inject the best matching passage for a user prompt (client hook)"
    register_sub_command daemon, Daemon, description: "Inspect or stop the per-project daemon"

    # Prints the top-level help text when no subcommand is given.
    def run
      puts help
    end
  end
end
