require "json"

module MnemodocServer
  module Indexer
    module Format
      # Jupyter notebook handler. Flattens the notebook into a pseudo-Markdown
      # document — markdown cells verbatim, code cells fenced — then reuses the
      # Markdown handler's section parsing, so code blocks naturally attach to
      # the heading that precedes them.
      class Notebook < Handler
        EXTENSIONS = %w(.ipynb)

        def initialize(@markdown : Markdown, @assembler : ChunkAssembler)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          document = build_markdown(File.read(path))
          @assembler.assemble(path, @markdown.parse_sections(document), document, mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        rescue ex : JSON::ParseException
          Log.warn { "invalid notebook json for #{path}: #{ex.message}" }
          [] of Chunk
        end

        # Converts notebook cells into one Markdown string.
        private def build_markdown(raw : String) : String
          json = JSON.parse(raw)
          io = IO::Memory.new
          cells = json["cells"]?.try(&.as_a?) || [] of JSON::Any
          cells.each do |cell|
            source = source_of(cell)
            next if source.strip.empty?
            case cell["cell_type"]?.try(&.as_s?)
            when "markdown"
              io << source << "\n\n"
            when "code"
              io << "```\n" << source << "\n```\n\n"
            end
          end
          io.to_s
        end

        # nbformat stores `source` as either a string or an array of line strings.
        private def source_of(cell : JSON::Any) : String
          source = cell["source"]?
          return "" unless source
          if array = source.as_a?
            array.join { |line| line.as_s? || "" }
          else
            source.as_s? || ""
          end
        end
      end
    end
  end
end
