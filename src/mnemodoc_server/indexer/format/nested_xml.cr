module MnemodocServer
  module Indexer
    module Format
      # Builds Sections from a nested-section XML document (DocBook, DITA,
      # FictionBook…). Entering a section-container element increases the heading
      # depth; a title element emits a heading at the current depth; a paragraph
      # element emits body text. Matching is on local element names only, so it
      # is namespace-agnostic. Title and paragraph elements are not descended
      # into (their text is read in one go via XML#content).
      module NestedXml
        def self.sections(root : XML::Node, sections : Set(String), titles : Set(String), paragraphs : Set(String)) : Array(Section)
          sz = Sectionizer.new
          walk(root, depth: 0, sz: sz, sections: sections, titles: titles, paragraphs: paragraphs)
          sz.sections
        end

        # Depth-first walk; section containers deepen the level, titles open a
        # heading at the current depth, paragraphs add body text.
        private def self.walk(node : XML::Node, depth : Int32, sz : Sectionizer, sections : Set(String), titles : Set(String), paragraphs : Set(String)) : Nil
          node.children.each do |child|
            next unless child.element?
            name = child.name
            if titles.includes?(name)
              text = child.content.strip
              sz.heading(depth < 1 ? 1 : depth, text) unless text.empty?
            elsif paragraphs.includes?(name)
              text = child.content.strip
              sz.text(text) unless text.empty?
            elsif sections.includes?(name)
              walk(child, depth: depth + 1, sz: sz, sections: sections, titles: titles, paragraphs: paragraphs)
            else
              walk(child, depth: depth, sz: sz, sections: sections, titles: titles, paragraphs: paragraphs)
            end
          end
        end
      end
    end
  end
end
