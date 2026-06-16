require "xml"

module MnemodocServer
  module Indexer
    module Format
      # HTML handler. Walks the parsed DOM, opening a section at each <h1>..<h6>
      # (level = heading number) and accumulating visible text. Non-content
      # elements (script/style/nav/head) are skipped.
      class Html < Handler
        EXTENSIONS = %w(.html .htm .xhtml)

        SKIP_TAGS = Set{"script", "style", "nav", "head"}
        HEADING   = /\Ah([1-6])\z/

        def initialize(@assembler : ChunkAssembler)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          @assembler.assemble(path, parse_sections(File.read(path)), "", mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        rescue ex
          Log.warn { "html parse failed for #{path}: #{ex.message}" }
          [] of Chunk
        end

        # Parses an HTML document into Sections by walking the DOM and opening a
        # section at each <h1>..<h6>. Public so Format::Epub can reuse HTML
        # parsing for an EPUB's XHTML chapters.
        def parse_sections(content : String) : Array(Section)
          document = XML.parse_html(content)
          sz = Sectionizer.new
          visit(document, sz)
          sz.sections
        end

        # Depth-first walk feeding headings and text into the Sectionizer.
        private def visit(node : XML::Node, sz : Sectionizer) : Nil
          node.children.each do |child|
            if child.element?
              name = child.name.downcase
              next if SKIP_TAGS.includes?(name)
              if match = name.match(HEADING)
                sz.heading(match[1].to_i, child.content.strip)
              else
                visit(child, sz)
              end
            elsif child.text?
              text = child.content.strip
              sz.text(text) unless text.empty?
            end
          end
        end
      end
    end
  end
end
