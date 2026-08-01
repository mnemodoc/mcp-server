module MnemodocServer
  module Indexer
    module Format
      # LibreOffice/ODF text (.odt) handler. Reads content.xml and walks it:
      # a <text:h> is a heading whose level is its explicit text:outline-level
      # attribute; a <text:p> is a body paragraph. Cleaner than docx because
      # ODF encodes the level directly.
      class Odt < Zipped
        # .odt plus the Writer template variant (.ott), same content.xml structure.
        EXTENSIONS = %w(.odt .ott)

        def parse(zip : Compress::Zip::File) : Sectionizer
          xml = read_entry(zip, "content.xml")
          return Sectionizer.new unless xml
          sectionize_document(XML.parse(xml))
        end

        # Builds Sections from a parsed ODF text document. Public so the flat-XML
        # variant (.fodt) can reuse the same walk on a non-zipped document.
        def sections_from_document(node : XML::Node) : Array(Section)
          sectionize_document(node).sections
        end

        # The same walk, handing back the sectionizer so the outline and the
        # extracted text come from the pass that built the sections.
        def sectionize_document(node : XML::Node) : Sectionizer
          sz = Sectionizer.new
          walk(node, sz)
          sz
        end

        # Walks the DOM; <text:h> opens a heading, <text:p> adds body text, and
        # neither is descended into (their text is read via XML#content). Other
        # container elements are recursed.
        private def walk(node : XML::Node, sz : Sectionizer) : Nil
          node.children.each do |child|
            next unless child.element?
            case child.name
            when "h"
              text = child.content.strip
              sz.heading(heading_level(child), text) unless text.empty?
            when "p"
              text = child.content.strip
              sz.text(text) unless text.empty?
            else
              walk(child, sz)
            end
          end
        end

        # The heading's outline level (defaults to 1 when the attribute is
        # missing or non-numeric).
        private def heading_level(node : XML::Node) : Int32
          node["outline-level"]?.try(&.to_i?) || 1
        end
      end
    end
  end
end
