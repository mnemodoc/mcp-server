module MnemodocServer
  module Tools
    # MCP tool that removes a single file and all its chunks from the SQLite index.
    # Validates that the file is currently indexed before attempting deletion,
    # returning an error when the path is not found.
    class Delete
      Log = ::Log.for("mnemodoc-server.tools.delete")

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
        if resolved.nil?
          # Distinct from the success path: a no-op, never a misleading "deleted" INFO.
          Log.debug { "delete skipped: '#{path}' not found in index" }
          raise MCP::ToolError.new("file not found in index: #{path}")
        end

        # Captured before deletion (CASCADE wipes the chunk rows) so the audit line
        # can report how many chunks were removed, mirroring the crawler's style.
        chunk_count = @store.chunk_ids_for_file(resolved).size
        deleted = @store.delete_file(resolved)
        raise MCP::ToolError.new("delete returned 0 rows for: #{resolved}") if deleted == 0

        Log.info { "deleted #{resolved} (#{chunk_count} chunks, manual removal via MCP tool)" }

        MCP::ToolResult.new(
          structured_content: JSON::Any.new({"deleted" => JSON::Any.new(resolved)} of String => JSON::Any),
        )
      end
    end
  end
end
