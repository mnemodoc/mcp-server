module MnemodocServer
  module Indexer
    module Format
      # EPUB handler. An EPUB is a ZIP of XHTML chapters; this reuses the HTML
      # handler's section parsing on each chapter (sorted by filename) and
      # concatenates the results. A single malformed chapter is skipped rather
      # than failing the whole book.
      class Epub < Zipped
        EXTENSIONS = %w(.epub)

        CHAPTER = /\.x?html?\z/i

        def initialize(@assembler : ChunkAssembler, @html : Html)
        end

        def parse(zip : Compress::Zip::File) : Array(Section)
          sections = [] of Section
          chapter_names(zip).each do |name|
            content = read_entry(zip, name)
            next unless content
            begin
              sections.concat(@html.parse_sections(content))
            rescue ex
              Log.warn { "skipping epub chapter #{name}: #{ex.message}" }
            end
          end
          sections
        end

        # XHTML/HTML chapter entry names, sorted by filename.
        private def chapter_names(zip : Compress::Zip::File) : Array(String)
          zip.entries.map(&.filename).select(&.matches?(CHAPTER)).sort!
        end
      end
    end
  end
end
