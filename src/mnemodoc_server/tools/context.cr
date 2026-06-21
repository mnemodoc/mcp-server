module MnemodocServer
  module Tools
    # MCP tool that returns which role Claude should adopt given the current
    # files, task, and query. Selection logic lives in Roles::Selector; this
    # tool parses the args, formats the ToolResult, and maps failures to errors.
    class Context
      Log = ::Log.for("mnemodoc-server.tools.context")

      def initialize(@selector : Roles::Selector)
      end

      # Optional args: "files" (array of strings), "task" (string), "query"
      # (string). Returns a ToolResult with structured_content (role/reason/
      # candidates) and the role's markdown as a text block.
      def call(args : Hash(String, JSON::Any), progress : MCP::Progress? = nil) : MCP::ToolResult
        a = MCP::Arguments.new(args)
        files = a.string_array?("files") || [] of String
        task = a.string?("task") || ""
        query = a.string?("query") || ""

        selection = @selector.select(files, task, query)

        # Audit trail for role injection, mirroring the `context` CLI command so
        # both channels leave the same trace in server.log_file.
        Log.info { "selected role=#{selection.role.name} reason=#{selection.reason.inspect} (via MCP tool)" }

        candidates_data = selection.candidates.map do |candidate|
          JSON::Any.new({
            "name"  => JSON::Any.new(candidate.name),
            "score" => JSON::Any.new(candidate.score.to_i64),
          } of String => JSON::Any)
        end

        structured = {
          "role"       => JSON::Any.new(selection.role.name),
          "reason"     => JSON::Any.new(selection.reason),
          "candidates" => JSON::Any.new(candidates_data),
        } of String => JSON::Any

        # The role's markdown is the primary text content; structured_content
        # carries the machine-readable metadata (role name, reason, candidates).
        MCP::ToolResult.new(
          content: [MCP::TextContent.new(selection.role.content).as(MCP::Content)],
          structured_content: JSON::Any.new(structured),
        )
      rescue Roles::NoRolesError
        raise MCP::ToolError.new("no roles configured in context section")
      rescue Roles::NeedSignalError
        raise MCP::ToolError.new("need at least one of files/task/query (no default set)")
      rescue ex : File::Error
        raise MCP::ToolError.new("role file not found: #{ex.message}")
      rescue ex : Indexer::EmbedderError
        raise MCP::ToolError.new("semantic selection failed: #{ex.message}")
      end
    end
  end
end
