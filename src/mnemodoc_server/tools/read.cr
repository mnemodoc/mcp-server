module MnemodocServer
  module Tools
    # MCP tool returning a numbered window of a stored document — the middle
    # ground between the passages query_documents returns and re-reading the
    # whole file. The agent widens around a passage that came back cut short, or
    # reads the section outline_document pointed it at.
    #
    # It serves the copy stored at index time, not the file: that copy is what
    # the returned passages were built from, so widening around one of them can
    # never land on a different revision.
    class Read
      include DocumentAccess

      Log = ::Log.for("mnemodoc-server.tools.read")

      # Chosen, not measured: a chunk caps at ChunkAssembler::MAX_TOKENS (1200),
      # and a read must comfortably exceed one chunk without approaching a whole
      # document. Both are revisable from use; nothing else depends on either.
      DEFAULT_LIMIT =  200
      MAX_LIMIT     = 2000

      def initialize(@store : Store::SQLite)
      end

      # Required arg: "path". Optional: "offset" (1-based, default 1) and
      # "limit" (default DEFAULT_LIMIT, capped at MAX_LIMIT).
      #
      # Out-of-range bounds are clamped rather than rejected, as query_documents
      # does with top_k, and an offset past the end returns nothing with eof set
      # instead of an error: probing the end of a document is a reasonable thing
      # to do. Ignores the progress reporter (reading is not long-running).
      def call(args : Hash(String, JSON::Any), progress : MCP::Progress? = nil) : MCP::ToolResult
        a = MCP::Arguments.new(args)
        document = load_document(@store, a.require_string("path"))

        offset = (a.int?("offset").try(&.to_i) || 1).clamp(1, Int32::MAX)
        limit = (a.int?("limit").try(&.to_i) || DEFAULT_LIMIT).clamp(1, MAX_LIMIT)

        lines = document.text.lines
        window = offset > lines.size ? [] of String : lines[(offset - 1), limit]
        # One pre-numbered string rather than an array of {line, text} objects:
        # the array would triple the token cost of a read for information the
        # prefix already carries, and saving tokens is what this tool is for.
        content = String.build do |io|
          window.each_with_index do |line, index|
            io << (offset + index).to_s.rjust(4) << '\t' << line.chomp << '\n'
          end
        end

        structured = document_fields(document)
        structured["offset"] = JSON::Any.new(offset.to_i64)
        structured["limit"] = JSON::Any.new(limit.to_i64)
        structured["returned"] = JSON::Any.new(window.size.to_i64)
        structured["eof"] = JSON::Any.new(offset + window.size > lines.size)
        structured["content"] = JSON::Any.new(content)

        # At info, like every other tool: a read is documentation actually
        # served, which is exactly what an audit of usage needs to see.
        Log.info { "read #{document.file} offset=#{offset} limit=#{limit} → #{window.size} lines" }
        MCP::ToolResult.new(structured_content: JSON::Any.new(structured))
      end
    end
  end
end
