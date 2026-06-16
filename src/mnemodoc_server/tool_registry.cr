module MnemodocServer
  # Builds an MCP::Server populated with mnemodoc's five tools, all sharing one
  # Embedder (so the HTTP connection pool is reused across query and ingest).
  # The shared embedder is returned alongside so the caller can drain it on shutdown.
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
        description: "Search the indexed documentation. Returns relevant chunks matching the query.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: true),
        schema: {
          type:       "object",
          properties: {
            query: {type: "string", description: "The search query"},
            top_k: {type: "integer", description: "Number of results (default: 5)"},
            mode:  {type: "string", enum: ["hybrid", "semantic", "keyword"], description: "Search mode"},
          },
          required: ["query"],
        }) { |args, progress| with_advisories(query.call(args, progress)) }

      server.tool("ingest_path",
        description: "Index a file or directory into the search index.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: false),
        schema: {
          type:       "object",
          properties: {path: {type: "string", description: "File or directory path to index"}},
          required:   ["path"],
        }) { |args, progress| with_advisories(ingest.call(args, progress)) }

      server.tool("list_files",
        description: "List all indexed files with metadata.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: true),
        schema: {
          type:       "object",
          properties: {prefix: {type: "string", description: "Filter by path prefix"}},
        }) { |args, progress| with_advisories(list.call(args, progress)) }

      server.tool("delete_file",
        description: "Remove a file from the search index.",
        annotations: MCP::ToolAnnotations.new(destructive_hint: true),
        schema: {
          type:       "object",
          properties: {path: {type: "string", description: "File path to remove"}},
          required:   ["path"],
        }) { |args, progress| with_advisories(delete.call(args, progress)) }

      server.tool("status",
        description: "Get server status: chunk count, file count, Ollama config, version.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: true),
        schema: {type: "object", properties: {} of String => String}) { |args, progress| with_advisories(status.call(args, progress)) }

      server.tool("get_project_context",
        description: "Select the role to adopt based on current files, task, and query. Returns the role's instructions to follow.",
        annotations: MCP::ToolAnnotations.new(read_only_hint: true),
        output_schema: {
          type:       "object",
          properties: {
            role:       {type: "string", description: "Role name selected"},
            reason:     {type: "string", description: "Why this role was selected"},
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
        }) { |args, progress| with_advisories(context.call(args, progress)) }

      {server: server, embedder: embedder}
    end

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
