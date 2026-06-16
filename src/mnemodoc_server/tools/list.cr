module MnemodocServer
  module Tools
    # MCP tool that lists all files currently present in the SQLite index,
    # along with per-file metadata such as modification time, index timestamp,
    # and chunk count. Supports optional prefix filtering to narrow results
    # to a specific directory subtree.
    class List
      def initialize(@store : Store::SQLite)
      end

      # Returns a ToolResult with structured_content containing all indexed files
      # as an array under the "files" key. Optional arg: "prefix" (String) —
      # when provided, only files whose path starts with that prefix are included.
      # Ignores the progress reporter (listing is not long-running).
      def call(args : Hash(String, JSON::Any), progress : MCP::Progress? = nil) : MCP::ToolResult
        a = MCP::Arguments.new(args)
        prefix = a.string?("prefix") || ""
        files = @store.list_files
        files = files.select(&.path.starts_with?(prefix)) unless prefix.empty?

        files_data = files.map do |file_info|
          JSON::Any.new({
            "path"        => JSON::Any.new(file_info.path),
            "mtime"       => JSON::Any.new(file_info.mtime),
            "indexed_at"  => JSON::Any.new(file_info.indexed_at),
            "chunk_count" => JSON::Any.new(file_info.chunk_count),
          } of String => JSON::Any)
        end

        MCP::ToolResult.new(
          structured_content: JSON::Any.new({"files" => JSON::Any.new(files_data)} of String => JSON::Any)
        )
      end
    end
  end
end
