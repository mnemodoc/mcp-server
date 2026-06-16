module MnemodocServer
  module Indexer
    module Format
      # Org-mode handler. Headings are leading-star lines (`*`, `**`, `***`…);
      # the level is the star count. The full heading line is kept as text.
      class Org < Handler
        EXTENSIONS = %w(.org)

        def initialize(@assembler : ChunkAssembler)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          content = File.read(path)
          @assembler.assemble(path, parse_sections(content), content, mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        end

        private def parse_sections(content : String) : Array(Section)
          sz = Sectionizer.new
          content.each_line do |line|
            stripped = line.strip
            if match = stripped.match(/^(\*+)\s+.+/)
              sz.heading(match[1].size, stripped)
            else
              sz.text(line.chomp)
            end
          end
          sz.sections
        end
      end
    end
  end
end
