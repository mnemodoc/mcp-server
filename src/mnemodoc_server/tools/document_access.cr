module MnemodocServer
  module Tools
    # Shared front door for the two document tools: resolves the path the way
    # delete_file does, loads the stored document, and decides whether it still
    # matches the file on disk.
    #
    # Staleness is reported, never repaired. This runs in a read path an agent
    # expects to be instant, and repairing would mean an embedding call and a
    # write — work the daemon's watcher already does, on its own schedule.
    module DocumentAccess
      record Loaded,
        file : String,
        text : String,
        line_count : Int32,
        verbatim : Bool,
        stale : Bool,
        warnings : Array(String)

      private def load_document(store : Store::SQLite, path : String) : Loaded
        resolved = store.indexed_path_for(path)
        raise MCP::ToolError.new("file not found in index: #{path}") if resolved.nil?

        document = store.document_for(resolved)
        if document.nil?
          raise MCP::ToolError.new(
            "no stored document for #{resolved}: it was indexed before document text was stored — re-index it to read it"
          )
        end

        freshness = freshness_of(store, resolved)
        Loaded.new(
          file: resolved, text: document[:text], line_count: document[:line_count],
          verbatim: document[:verbatim], stale: freshness[:stale], warnings: freshness[:warnings],
        )
      end

      # Compares the file's mtime with the one recorded at index time. A missing
      # file counts as stale too: what is served no longer describes anything on
      # disk, and the caller deserves to know which of the two situations it is.
      private def freshness_of(store : Store::SQLite, resolved : String) : {stale: Bool, warnings: Array(String)}
        warnings = [] of String
        unless File.file?(resolved)
          warnings << "#{resolved} is no longer on disk; the content returned comes from the index"
          return {stale: true, warnings: warnings}
        end
        return {stale: false, warnings: warnings} if store.file_indexed?(
                                                       resolved, mtime: File.info(resolved).modification_time.to_unix)
        warnings << "#{resolved} changed on disk since it was indexed; the content returned is the indexed revision"
        {stale: true, warnings: warnings}
      end

      # The payload fields both tools share, so neither can drift from the other
      # on what it reports about the document it just served.
      private def document_fields(document : Loaded) : Hash(String, JSON::Any)
        fields = {
          "file"       => JSON::Any.new(document.file),
          "line_count" => JSON::Any.new(document.line_count.to_i64),
          "verbatim"   => JSON::Any.new(document.verbatim),
          "stale"      => JSON::Any.new(document.stale),
        } of String => JSON::Any
        unless document.warnings.empty?
          fields["warnings"] = JSON::Any.new(document.warnings.map { |warning| JSON::Any.new(warning) })
        end
        fields
      end
    end
  end
end
