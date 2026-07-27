module MnemodocServer
  # Builds an MCP::Server populated with mnemodoc's six tools, all sharing one
  # Embedder (so the HTTP connection pool is reused across query and ingest).
  # The shared embedder is returned alongside so the caller can drain it on shutdown.
  #
  # A note on the tool descriptions below: they are not documentation. They are
  # injected verbatim into the model's context alongside every other available
  # tool, and are the only text it weighs when deciding whether to call this
  # tool, a generic Grep/Read, or nothing. They therefore state *when* to call
  # each tool, not only what it does — and, where a costly follow-up habit
  # exists (re-reading a file whose passages were just returned), they close it
  # explicitly while leaving a stated escape hatch.
  module ToolRegistry
    # Instantiates the tools, registers them with their JSON Schemas on a fresh
    # MCP::Server, and returns the server plus the shared embedder.
    def self.build(config : Config, store : Store::SQLite, qdrant_index : Store::QdrantIndex? = nil) : {server: MCP::Server, embedder: Indexer::Embedder}
      embedder = Indexer::Embedder.new(config.ollama)
      query = Tools::Query.new(config, store, embedder, qdrant_index)
      ingest = Tools::Ingest.new(config, store, embedder)
      list = Tools::List.new(store)
      delete = Tools::Delete.new(store)
      status = Tools::Status.new(config, store)

      context = Tools::Context.new(Roles::Selector.from_config(config, embedder))

      server = MCP::Server.new(name: "mnemodoc-server", version: MnemodocServer.version)

      server.tool("query_documents",
        description: "Search this project's indexed documentation. Call this FIRST — before grepping, before opening a documentation file, and before answering from general knowledge — whenever the question touches this project's conventions, architecture, setup, workflows or domain rules. Hybrid semantic + keyword search returns the matching passages verbatim, with their file path and heading. Treat returned passages as already read: do not re-open the same file to confirm them, unless you need surrounding context the passages do not carry.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: true),
        schema: {
          type:       "object",
          properties: {
            query: {type: "string", description: "The search query"},
            top_k: {type: "integer", description: "Number of results (default: 5)"},
            mode:  {type: "string", enum: ["hybrid", "semantic", "keyword"], description: "Search mode"},
          },
          required: ["query"],
        }) { |args, progress| guarded { query.call(args, progress) } }

      server.tool("ingest_path",
        description: "Add a file or directory to the documentation index. Call it after creating or substantially rewriting a document, or to index a path outside the configured `paths`. Indexing is incremental — files whose mtime has not changed are skipped — so re-running on a directory is cheap and safe.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: false),
        schema: {
          type:       "object",
          properties: {path: {type: "string", description: "File or directory path to index"}},
          required:   ["path"],
        }) { |args, progress| guarded { ingest.call(args, progress) } }

      server.tool("list_files",
        description: "List the documentation files currently indexed, with their mtime, index time and chunk count. Use it to find out which documents exist before searching, or to diagnose a query_documents search that returned nothing you expected — a file absent from this list, or indexed before its last edit, explains the miss.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: true),
        schema: {
          type:       "object",
          properties: {prefix: {type: "string", description: "Filter by path prefix"}},
        }) { |args, progress| guarded { list.call(args, progress) } }

      server.tool("delete_file",
        description: "Remove a document and all its passages from the index. Call it when a file has been deleted or moved and stale passages still surface in search results. It only touches the index — the file on disk is left alone.",
        annotations: MCP::ToolAnnotations.new(destructive_hint: true),
        schema: {
          type:       "object",
          properties: {path: {type: "string", description: "File path to remove"}},
          required:   ["path"],
        }) { |args, progress| guarded { delete.call(args, progress) } }

      server.tool("status",
        description: "Report the index's health: file and chunk counts, database path, the configured Ollama endpoint and embedding model, and the server version. Call it when searches behave unexpectedly — an empty index, or an embedding model that no longer matches the one the stored vectors were built with, accounts for most surprising results.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: true),
        schema: {type: "object", properties: {} of String => String}) { |args, progress| guarded { status.call(args, progress) } }

      # Only offered when the project actually declares roles. Its description
      # tells the model to call it before every edit, so advertising it in a
      # project with no `context:` section bought one round-trip and one error
      # per edit, for the whole session.
      register_context_tool(server, context) unless config.context.roles.empty?

      {server: server, embedder: embedder}
    end

    private def self.register_context_tool(server, context) : Nil
      server.tool("get_project_context",
        description: "Select which project role and conventions to adopt for the files, task and question at hand, and return that role's instructions. Call it BEFORE writing or modifying code in this project: the returned markdown carries the conventions that apply here and takes precedence over generic defaults. Pass whichever of files/task/query you have — the selection degrades gracefully when some are missing.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: true),
        output_schema: {
          type:       "object",
          properties: {
            role:       {type: "string", description: "Role name selected"},
            reason:     {type: "string", description: "Why this role was selected"},
            score:      {type: "integer", description: "Rule score of the selected role (0 when it is the default fallback)"},
            candidates: {
              type:  "array",
              items: {
                type:       "object",
                properties: {
                  name:  {type: "string"},
                  score: {type: "integer"},
                },
              },
            },
          },
        },
        schema: {
          type:       "object",
          properties: {
            files: {type: "array", items: {type: "string"}, description: "Paths of files currently being worked on"},
            task:  {type: "string", description: "Kind of task (debug, implement, refactor…)"},
            query: {type: "string", description: "The user's current request or question"},
          },
        }) { |args, progress| guarded { context.call(args, progress) } }
    end

    # Runs a tool, unless this invocation resolved to no project at all.
    #
    # A single globally registered server is launched in whatever directory a
    # client session opens, so it routinely lands outside any MnemoDoc project.
    # Every tool then answers the same way, before touching the store: an empty
    # result would read to the agent as "the documentation says nothing on
    # this", which is a different — and wrong — statement. It is not an error
    # either: the agent should fall back to its own file tools, not treat the
    # call as broken.
    private def self.guarded(& : -> MCP::ToolResult) : MCP::ToolResult
      return with_advisories(yield) if MnemodocServer.project_initialized?

      with_advisories(MCP::ToolResult.new(
        content: [MCP::TextContent.new(UNINITIALIZED_MESSAGE)] of MCP::Content,
        structured_content: JSON::Any.new({
          "project_initialized" => JSON::Any.new(false),
          "message"             => JSON::Any.new(UNINITIALIZED_MESSAGE),
        } of String => JSON::Any),
        is_error: false,
      ))
    end

    UNINITIALIZED_MESSAGE = "This directory belongs to no MnemoDoc project, so there is no documentation index to search. " \
                            "This is not a failure and not an empty result: nothing has been indexed here yet. " \
                            "Use your own file tools for now, and run `mnemodoc-server init` at the project root to index it."

    # Merges active server advisories into a tool result's structured_content
    # warnings (union with any per-call warnings the tool already set), so every
    # response surfaces them where the MCP agent reads and relays them. Returns
    # the result unchanged when there is nothing to add.
    private def self.with_advisories(result : MCP::ToolResult) : MCP::ToolResult
      existing = result.structured_content
        .try(&.["warnings"]?).try(&.as_a?).try(&.map(&.as_s)) || [] of String
      warnings = existing + MnemodocServer.advisories
      return result if warnings.empty?

      structured = result.structured_content.try(&.as_h?).try(&.dup) || {} of String => JSON::Any
      structured["warnings"] = JSON::Any.new(warnings.map { |warning| JSON::Any.new(warning) })
      MCP::ToolResult.new(
        content: result.content,
        structured_content: JSON::Any.new(structured),
        is_error: result.is_error?,
      )
    end
  end
end
