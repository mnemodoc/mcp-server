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

        def extract(path : String, mtime : Int64) : Document
          sz = sectionize(read_text(path))
          # verbatim is false even though the file is text on disk: the parser
          # walks the DOM and never learns which source line an <h2> sat on, so
          # it cannot honour the "start_line indexes the file" side of the
          # invariant. It numbers its own extraction instead.
          Document.new(
            text: sz.normalized_text,
            verbatim: false,
            outline: sz.outline,
            chunks: @assembler.assemble(path, sz.sections, sz.normalized_text, mtime),
          )
        rescue ex : File::Error | DocumentTooLarge
          Log.warn { "read failed for #{path}: #{ex.message}" }
          Document.empty
        rescue ex
          Log.warn { "html parse failed for #{path}: #{ex.message}" }
          Document.empty
        end

        # Parses an HTML document into Sections by walking the DOM and opening a
        # section at each <h1>..<h6>. Public so Format::Epub can reuse HTML
        # parsing for an EPUB's XHTML chapters.
        def parse_sections(content : String) : Array(Section)
          sectionize(content).sections
        end

        # The same walk, handing back the sectionizer so a caller that needs the
        # outline and the extracted text gets both from one pass. Public for the
        # same reason as parse_sections: an EPUB parses chapter by chapter.
        def sectionize(content : String) : Sectionizer
          document = XML.parse_html(content)
          sz = Sectionizer.new
          visit(document, sz)
          sz
        end

        # Depth-first walk feeding headings and text into the Sectionizer.
        private def visit(node : XML::Node, sz : Sectionizer) : Nil
          node.children.each do |child|
            if child.element?
              name = child.name.downcase
              next if SKIP_TAGS.includes?(name)
              if (match = name.match(HEADING)) && !child.content.strip.empty?
                sz.heading(match[1].to_i, child.content.strip)
              else
                visit(child, sz)
              end
            elsif child.element? && child.name.downcase.matches?(HEADING)
              # An empty <h2> is not a section title. Recorded as "" it still
              # opened a section, so the text after it stopped being preamble
              # and there was nothing left for merge_preamble to fold in.
              visit(child, sz)
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
