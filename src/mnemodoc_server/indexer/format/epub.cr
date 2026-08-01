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

        def parse(zip : Compress::Zip::File) : Sectionizer
          book = Sectionizer.new
          chapter_names(zip).each do |name|
            content = read_entry(zip, name)
            next unless content
            begin
              # Absorbed rather than concatenated: each chapter is parsed on its
              # own sectionizer, so its outline is numbered from 1, and only the
              # book knows how many lines came before it.
              book.absorb(@html.sectionize(content))
            rescue ex
              Log.warn { "skipping epub chapter #{name}: #{ex.message}" }
            end
          end
          book
        end

        # Chapter entry names in reading order.
        #
        # The book states that order in its OPF spine, and it is not the
        # filenames': ch10 sorts before ch2 alphabetically. Chunks carry the
        # document's sequence, so the wrong order attaches a passage to the
        # wrong neighbourhood — and, with merge_preamble_into_first_section, to
        # the wrong chapter entirely. Falls back to alphabetical when the
        # package cannot be read, which is what it always did.
        private def chapter_names(zip : Compress::Zip::File) : Array(String)
          alphabetical = zip.entries.map(&.filename).select(&.matches?(CHAPTER)).sort!
          spine_names(zip, alphabetical) || alphabetical
        end

        # Resolves META-INF/container.xml -> the OPF package -> <spine>, mapping
        # each itemref back to a manifest href, and keeps only entries that are
        # really in the archive. Returns nil when anything is missing.
        private def spine_names(zip : Compress::Zip::File, known : Array(String)) : Array(String)?
          container = read_entry(zip, "META-INF/container.xml")
          return nil unless container
          opf_path = XML.parse(container).xpath_nodes("//*[local-name()='rootfile']")
            .first?.try(&.["full-path"]?)
          return nil unless opf_path
          opf = read_entry(zip, opf_path)
          return nil unless opf

          package = XML.parse(opf)
          hrefs = {} of String => String
          package.xpath_nodes("//*[local-name()='item']").each do |item|
            id = item["id"]?
            href = item["href"]?
            hrefs[id] = href if id && href
          end

          base = File.dirname(opf_path)
          ordered = package.xpath_nodes("//*[local-name()='itemref']").compact_map do |ref|
            idref = ref["idref"]?
            href = idref.try { |key| hrefs[key]? }
            next unless href
            candidate = base == "." ? href : File.join(base, href)
            known.includes?(candidate) ? candidate : nil
          end
          ordered.empty? ? nil : ordered
        rescue ex
          Log.warn { "unreadable epub spine, falling back to filename order: #{ex.message}" }
          nil
        end
      end
    end
  end
end
