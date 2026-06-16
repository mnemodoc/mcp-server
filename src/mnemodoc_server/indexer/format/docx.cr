module MnemodocServer
  module Indexer
    module Format
      # Word (.docx) handler. Reads word/document.xml and walks its paragraphs
      # (<w:p>): a paragraph's text is the concatenation of its runs (exposed by
      # XML#content), and its heading level comes from the <w:pStyle> val
      # attribute. English ("Heading2") and French ("Titre2") style names are
      # recognized; other/custom styles degrade to body text.
      class Docx < Zipped
        # .docx plus macro-enabled (.docm) and template (.dotx/.dotm) variants,
        # which share the same word/document.xml structure.
        EXTENSIONS = %w(.docx .docm .dotx .dotm)

        # A heading paragraph style: "Heading2"/"Titre2" -> level 2.
        HEADING = /\A(?:heading|titre)\s*([1-9])\z/i
        # A document title style -> level 1.
        TITLE = /\A(?:title|titre)\z/i

        def parse(zip : Compress::Zip::File) : Array(Section)
          xml = read_entry(zip, "word/document.xml")
          return [] of Section unless xml
          sz = Sectionizer.new
          walk(XML.parse(xml), sz)
          sz.sections
        end

        # Walks the DOM; each <w:p> is a paragraph (not descended into further),
        # everything else is recursed so paragraphs inside tables are found.
        private def walk(node : XML::Node, sz : Sectionizer) : Nil
          node.children.each do |child|
            next unless child.element?
            if child.name == "p"
              emit_paragraph(child, sz)
            else
              walk(child, sz)
            end
          end
        end

        # Classifies one paragraph as a heading (by style) or body text.
        private def emit_paragraph(paragraph : XML::Node, sz : Sectionizer) : Nil
          text = paragraph.content.strip
          return if text.empty?
          style = paragraph_style(paragraph)
          if style && (match = HEADING.match(style))
            sz.heading(match[1].to_i, text)
          elsif style && TITLE.matches?(style)
            sz.heading(1, text)
          else
            sz.text(text)
          end
        end

        # Finds the paragraph's <w:pStyle> val attribute, or nil.
        private def paragraph_style(paragraph : XML::Node) : String?
          find_element(paragraph, "pStyle").try &.["val"]?
        end

        # Returns the first descendant element with the given local name, or nil.
        private def find_element(node : XML::Node, local_name : String) : XML::Node?
          node.children.each do |child|
            next unless child.element?
            return child if child.name == local_name
            if found = find_element(child, local_name)
              return found
            end
          end
          nil
        end
      end
    end
  end
end
