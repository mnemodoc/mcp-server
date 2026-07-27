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
          document = build_markdown(read_text(path))
          @assembler.assemble(path, @markdown.parse_sections(document), document, mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        rescue ex : JSON::ParseException
          Log.warn { "invalid notebook json for #{path}: #{ex.message}" }
          [] of Chunk
        end

        # Converts notebook cells into one Markdown string.
        #
        # Every lookup goes through `as_h?`/`as_a?` first: `JSON::Any#[]?` is not
        # the lenient accessor it looks like, it raises on a receiver that is
        # neither a hash nor nil. A file that is valid JSON without being a
        # notebook — an array at the root, a string, a `cells` list holding
        # anything but objects — would otherwise take the handler out with a
        # bare Exception that no rescue here matches.
        private def build_markdown(raw : String) : String
          root = JSON.parse(raw).as_h?
          return "" unless root
          io = IO::Memory.new
          cells = root["cells"]?.try(&.as_a?) || [] of JSON::Any
          cells.each do |raw_cell|
            cell = raw_cell.as_h?
            next unless cell
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
        private def source_of(cell : Hash(String, JSON::Any)) : String
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
