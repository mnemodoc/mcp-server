module MnemodocServer
  module Tools
    # MCP tool returning a document's plan: every heading with its level, where
    # it starts and how long it runs. The cheap first call that tells an agent
    # where to aim read_document, instead of loading a whole file to find out.
    class Outline
      include DocumentAccess

      Log = ::Log.for("mnemodoc-server.tools.outline")

      def initialize(@store : Store::SQLite)
      end

      # Required arg: "path". Ignores the progress reporter (reading the plan is
      # not long-running).
      def call(args : Hash(String, JSON::Any), progress : MCP::Progress? = nil) : MCP::ToolResult
        document = load_document(@store, MCP::Arguments.new(args).require_string("path"))
        entries = @store.outline_for(document.file)

        sections = entries.map_with_index do |entry, index|
          # A section runs until the next one starts; the last runs to the end
          # of the document. Derived rather than stored, so a partial write can
          # never leave an end_line contradicting the next start_line.
          next_start = entries[index + 1]?.try(&.start_line) || (document.line_count + 1)
          end_line = next_start - 1
          JSON::Any.new({
            "level"      => JSON::Any.new(entry.level.to_i64),
            "title"      => JSON::Any.new(entry.title),
            "start_line" => JSON::Any.new(entry.start_line.to_i64),
            "end_line"   => JSON::Any.new(end_line.to_i64),
            # What lets the agent decide whether the section fits one read.
            "lines" => JSON::Any.new((end_line - entry.start_line + 1).to_i64),
          } of String => JSON::Any)
        end

        structured = document_fields(document)
        structured["sections"] = JSON::Any.new(sections)

        # At info, like every other tool: see the note in Tools::Read.
        Log.info { "outline #{document.file} → #{sections.size} sections" }
        MCP::ToolResult.new(structured_content: JSON::Any.new(structured))
      end
    end
  end
end
