module MnemodocServer
  module Indexer
    module Format
      # reStructuredText handler. A title is a text line followed by an
      # adornment line (a run of one repeated punctuation character at least
      # as long as the title). RST assigns heading levels by the order in
      # which each adornment character first appears in the document.
      class Rst < Handler
        EXTENSIONS = %w(.rst)

        # The punctuation characters RST permits as section adornments.
        SECTION_CHARS = "=-`:'\"~^_*+#.!$%&(),/;<>?@[\\]{|}"

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
          levels = {} of Char => Int32
          lines = content.split('\n')
          i = 0
          while i < lines.size
            title = lines[i]
            underline = i + 1 < lines.size ? lines[i + 1] : ""
            adornment = underline_char(underline)
            if adornment && !title.strip.empty? && underline.rstrip.size >= title.strip.size
              level = (levels[adornment] ||= levels.size + 1)
              sz.heading(level, title.strip)
              i += 2
            else
              sz.text(title)
              i += 1
            end
          end
          sz.sections
        end

        # Returns the adornment character if the line is a non-empty run of a
        # single permitted punctuation character, else nil.
        private def underline_char(line : String) : Char?
          stripped = line.rstrip
          return nil if stripped.empty?
          first = stripped[0]
          return nil unless SECTION_CHARS.includes?(first)
          return nil unless stripped.each_char.all?(&.==(first))
          first
        end
      end
    end
  end
end
