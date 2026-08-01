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

        def extract(path : String, mtime : Int64) : Document
          content = read_text(path)
          sz = sectionize(content)
          Document.new(
            text: content,
            verbatim: true,
            outline: sz.outline,
            chunks: @assembler.assemble(path, sz.sections, content, mtime),
          )
        rescue ex : File::Error | DocumentTooLarge
          Log.warn { "read failed for #{path}: #{ex.message}" }
          Document.empty
        end

        private def sectionize(content : String) : Sectionizer
          sz = Sectionizer.new
          fence = FenceTracker.asciidoc
          line_no = 0
          content.each_line do |line|
            line_no += 1
            stripped = line.strip
            if fence.delimiter?(line) || fence.inside?
              sz.text(line.chomp)
              next
            end
            if match = stripped.match(/^(=+)\s+.+/)
              sz.heading(match[1].size, stripped, source_line: line_no)
            else
              sz.text(line.chomp)
            end
          end
          sz
        end
      end
    end
  end
end
