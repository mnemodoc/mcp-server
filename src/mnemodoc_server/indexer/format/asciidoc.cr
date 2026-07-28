module MnemodocServer
  module Indexer
    module Format
      # AsciiDoc handler. Headings are leading-equals lines (`=` document
      # title, `==` section, `===` subsection…); level is the `=` count. We
      # only parse structure, not the full AsciiDoc syntax.
      class AsciiDoc < Handler
        EXTENSIONS = %w(.adoc .asciidoc)

        def initialize(@assembler : ChunkAssembler)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          content = read_text(path)
          @assembler.assemble(path, parse_sections(content), content, mtime)
        rescue ex : File::Error | DocumentTooLarge
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        end

        private def parse_sections(content : String) : Array(Section)
          sz = Sectionizer.new
          fence = FenceTracker.asciidoc
          content.each_line do |line|
            stripped = line.strip
            if fence.delimiter?(line) || fence.inside?
              sz.text(line.chomp)
              next
            end
            if match = stripped.match(/^(=+)\s+.+/)
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
