module MnemodocServer
  module Usage
    # One recorded call: when it happened, who made it, what it did, and which
    # indexed documents it served. Serialised to JSON for both transports, so
    # the socket and the spool file carry exactly the same shape.
    struct UsageEvent
      include JSON::Serializable

      getter at : Int64
      getter source : String
      getter action : String
      getter query : String?
      getter result_count : Int32
      getter elapsed_ms : Int32?
      getter session : String?
      getter agent : String?
      getter files : Array(String)

      def initialize(
        @at : Int64, @source : String, @action : String, @query : String?,
        @result_count : Int32, @elapsed_ms : Int32?, @session : String?,
        @agent : String?, @files : Array(String),
      )
      end

      # The indexed documents a tool result served, by two rules rather than a
      # per-tool table: a payload carrying `chunks` yields each chunk's `file`,
      # one carrying `file` yields that one, and anything else yields nothing.
      #
      # An unknown shape returning an empty list is the point: a tool added
      # later records its call without attributing documents, instead of
      # breaking the call it is observing.
      #
      # Deduplicated, because several passages routinely come from one document.
      # Naming it once per passage made "served N times" count passages here and
      # calls on the CLI side, so one figure meant two different things.
      def self.files_from(result : MCP::ToolResult) : Array(String)
        structured = result.structured_content.try(&.as_h?)
        return [] of String unless structured

        if chunks = structured["chunks"]?.try(&.as_a?)
          return chunks.compact_map { |chunk| chunk.as_h?.try(&.["file"]?).try(&.as_s?) }.uniq!
        end
        if file = structured["file"]?.try(&.as_s?)
          return [file]
        end
        [] of String
      end

      # What the call returned, which is not how many documents it touched:
      # three passages from one file is three results. Derived from the payload
      # rather than from the file list so the count means the same thing here as
      # it does when a CLI subcommand reports its own result size.
      #
      # Zero is load-bearing: the misses view keys on it, so only a genuinely
      # empty answer may read as zero.
      def self.result_count_from(result : MCP::ToolResult) : Int32
        structured = result.structured_content.try(&.as_h?)
        return 0 unless structured

        if chunks = structured["chunks"]?.try(&.as_a?)
          return chunks.size
        end
        structured["file"]?.try(&.as_s?) ? 1 : 0
      end
    end
  end
end
