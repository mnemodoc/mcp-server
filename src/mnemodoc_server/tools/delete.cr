module MnemodocServer
  module Tools
    # MCP tool that removes a single file and all its chunks from the SQLite index.
    # Validates that the file is currently indexed before attempting deletion,
    # returning an error when the path is not found.
    class Delete
      def initialize(@store : Store::SQLite)
      end

      # Deletes the indexed file identified by the required "path" argument.
      # Resolves the given path to the actual stored absolute path via
      # indexed_path_for (exact → expanded → unique-suffix). Returns a ToolResult
      # with structured_content {deleted: resolved_path} on success, or raises
      # MCP::ToolError when the path is missing, unresolvable, or ambiguous.
      # Ignores the progress reporter (deletion is not long-running).
      def call(args : Hash(String, JSON::Any), progress : MCP::Progress? = nil) : MCP::ToolResult
        path = MCP::Arguments.new(args).require_string("path")

        resolved = @store.indexed_path_for(path)
        raise MCP::ToolError.new("file not found in index: #{path}") if resolved.nil?

        deleted = @store.delete_file(resolved)
        raise MCP::ToolError.new("delete returned 0 rows for: #{resolved}") if deleted == 0

        MCP::ToolResult.new(
          structured_content: JSON::Any.new({"deleted" => JSON::Any.new(resolved)} of String => JSON::Any),
        )
      end
    end
  end
end
