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
        elsif config.server.daemon?
          # Default stdio path: proxy to (or auto-spawn) the per-project daemon.
          MnemodocServer::DaemonProxy.new(config, flags.config).run
        else
          # Daemon disabled: serve stdio standalone in this process.
          MnemodocServer.serve_stdio(config)
        end
      rescue ex : Indexer::EmbedderError
        handle_error(ex)
      ensure
        MnemodocServer.close_log_file!
      end
    end

    # Crawls and indexes a file or directory, computing Ollama embeddings for
    # each Markdown chunk and persisting them to the SQLite store.
    # Files whose mtime has not changed since the last run are skipped.
    class Index < Admiral::Command
      include CLIErrorHandling
      include CLIOutput
      define_help description: "Index a file or directory"

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
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
        embedder = Indexer::Embedder.new(config.ollama)
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
        index_result = crawler.run(store, embedder, sf, concurrency: config.index.concurrency)
        store.embedding_model = config.ollama.model
        # Summary audit line, parity with the Serve background-indexing path.
        Log.info { "indexing: #{index_result[:indexed]} indexed, #{index_result[:skipped]} skipped, #{index_result[:pruned]} pruned" }
        payload = {
          indexed: index_result[:indexed],
          skipped: index_result[:skipped],
          pruned:  index_result[:pruned],
          failed:  index_result[:failed],
        }
        emit(payload, json: flags.json, quiet: flags.quiet) do
          puts "Indexed: #{index_result[:indexed]} files, skipped: #{index_result[:skipped]} (up to date), pruned: #{index_result[:pruned]}"
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

        store = MnemodocServer.open_store(config)
        embedder = Indexer::Embedder.new(config.ollama)

        query_vec = embedder.embed_batch([arguments.query]).first
        hybrid = MnemodocServer::Search::Hybrid.new(config.search, MnemodocServer.qdrant_index(config))
        results = hybrid.search(arguments.query, query_vec, store)
        # Diagnostic trace for tuning relevance; off at the default info level.
        Log.debug { "query=#{arguments.query.inspect} mode=#{flags.mode} top_k=#{flags.top} → #{results.size} results" }

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

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
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
          puts "mnemodoc-server #{MnemodocServer.version}"
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

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
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

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
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

      define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
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
        selection = selector.select(input.files, input.task, input.query)
        # Audit trail for role injection, written to server.log_file (never stdout,
        # which the PreToolUse hook consumes as the role markdown). Fixed format:
        # every field is always present (empty when absent) so log parsing stays
        # stable across flags-only and hook-stdin modes.
        Log.for("mnemodoc-server.context").info {
          "event=#{input.event} role=#{selection.role.name} reason=#{selection.reason.inspect}" \
          " session=#{input.session_id} agent=#{input.agent_label.inspect}" \
          " files=#{input.files.inspect} task=#{input.task.inspect} query=#{input.query.inspect}"
        }
        Log.for("mnemodoc-server.context").debug {
          "transcript=#{input.transcript_path.inspect} cwd=#{input.cwd.inspect}"
        }
        # The role markdown goes to stdout verbatim so the hook injects it as-is.
        # Exception: on UserPromptSubmit (query channel), an undecided prompt that
        # only resolves to the default role would pollute every turn with the
        # generalist context, so we stay silent. The audit line above is still
        # written, keeping the trace even when stdout is suppressed. The files
        # channel (PreToolUse) always prints, covering cross-cutting edits.
        suppressed = suppress_default_for_query?(input, selection)

        # Under --json the payload is always emitted, `suppressed` carrying what
        # the text mode expresses by staying silent — an empty stdout would be
        # indistinguishable from a failure. The hook never passes --json, so the
        # verbatim-markdown contract above is untouched.
        if flags.json
          puts({
            role:       selection.role.name,
            reason:     selection.reason,
            default:    selection.default?,
            suppressed: suppressed,
            candidates: selection.candidates.map { |candidate| {name: candidate.name, score: candidate.score} },
            content:    selection.role.content,
          }.to_json)
        else
          puts selection.role.content unless suppressed
        end
      rescue ex : Roles::NoRolesError | Roles::NeedSignalError | File::Error | Indexer::EmbedderError | Hooks::UnknownClientError
        handle_error(ex, json: flags.json)
      ensure
        embedder.try(&.close)
      end

      # True when stdout must stay empty: a UserPromptSubmit event whose selection
      # is the default-role fallback. Other events (PreToolUse) and decisive
      # domain matches always print.
      private def suppress_default_for_query?(input : Hooks::HookInput, selection : Roles::Selection) : Bool
        input.event == "UserPromptSubmit" && selection.default?
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

        payload = {
          version:  MnemodocServer.version,
          crystal:  Crystal::DESCRIPTION,
          licenses: licenses,
        }
        emit(payload, json: flags.json, quiet: false) do
          puts "version: #{MnemodocServer.version}"
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

        define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
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

        define_flag config : String, long: "config", short: "c", default: ".mnemodoc.yml", description: "Path to config file"
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

    register_sub_command serve, Serve, description: "Start the MCP server"
    register_sub_command index, Index, description: "Index a file or directory"
    register_sub_command search, Search, description: "Search the index"
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
