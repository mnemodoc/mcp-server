module MnemodocServer
  module Tools
    # MCP tool that reports the current health and configuration of the server.
    # Useful for clients to verify connectivity, inspect the active Ollama model,
    # and confirm how many documents are in the index without performing a search.
    class Status
      Log = ::Log.for("mnemodoc-server.tools.status")

      def initialize(@config : Config, @store : Store::SQLite)
      end

      # Returns a ToolResult with structured_content containing a snapshot of
      # server state: version, chunk and file counts, Ollama host and model,
      # active search mode, and the SQLite database path.
      # Takes no arguments; ignores the progress reporter.
      def call(args : Hash(String, JSON::Any), progress : MCP::Progress? = nil) : MCP::ToolResult
        structured = {
          "status"      => JSON::Any.new("ok"),
          "version"     => JSON::Any.new(MnemodocServer.version),
          "chunk_count" => JSON::Any.new(@store.chunk_count),
          "file_count"  => JSON::Any.new(@store.file_count),
          "ollama_host" => JSON::Any.new(@config.ollama.host),
          "model"       => JSON::Any.new(@config.ollama.model),
          "search_mode" => JSON::Any.new(@config.search.mode),
          "db_path"     => JSON::Any.new(@config.db_path),
        } of String => JSON::Any
        # Audit line at info, like every other tool: see the note in Tools::List.
        Log.info { "status: #{@store.file_count} files, #{@store.chunk_count} chunks" }

        MCP::ToolResult.new(structured_content: JSON::Any.new(structured))
      end
    end
  end
end
