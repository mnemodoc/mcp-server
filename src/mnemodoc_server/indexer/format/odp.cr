module MnemodocServer
  module Indexer
    module Format
      # LibreOffice/ODF presentation (.odp) handler. Reads content.xml and
      # gathers the text of every paragraph (<text:p>) across all slides. Slides
      # are not hierarchical, so the whole deck becomes one headingless section
      # that the assembler token-splits (the same treatment as .pptx).
      class Odp < Zipped
        # .odp plus the Impress template variant (.otp), same content.xml structure.
        EXTENSIONS = %w(.odp .otp)

        def parse(zip : Compress::Zip::File) : Array(Section)
          xml = read_entry(zip, "content.xml")
          return [] of Section unless xml
          sections_from_document(XML.parse(xml))
        end

        # Builds Sections from a parsed ODF presentation document. Public so the
        # flat-XML variant (.fodp) can reuse the same walk on a non-zipped file.
        def sections_from_document(node : XML::Node) : Array(Section)
          parts = [] of String
          gather_paragraphs(node, parts)
          combined = parts.join("\n")
          combined.empty? ? [] of Section : [Section.new(nil, nil, combined)]
        end

        # Recursively collects the text of every <text:p> element, without
        # descending into one (its runs are read in one go via XML#content).
        private def gather_paragraphs(node : XML::Node, parts : Array(String)) : Nil
          node.children.each do |child|
            next unless child.element?
            if child.name == "p"
              text = child.content.strip
              parts << text unless text.empty?
            else
              gather_paragraphs(child, parts)
            end
          end
        end
      end
    end
  end
end
