module MnemodocServer
  module Indexer
    module Format
      # PowerPoint (.pptx) handler. Reads ppt/slides/slideN.xml in numeric order
      # and gathers each slide's text runs (<a:t>). Slides are not hierarchical,
      # so the whole deck becomes one headingless section that the assembler
      # token-splits (the same treatment as plain text and PDF).
      class Pptx < Zipped
        # .pptx plus macro-enabled (.pptm), template (.potx/.potm) and slideshow
        # (.ppsx/.ppsm) variants, which share the same ppt/slides structure.
        EXTENSIONS = %w(.pptx .pptm .potx .potm .ppsx .ppsm)

        SLIDE = /\Appt\/slides\/slide(\d+)\.xml\z/

        def parse(zip : Compress::Zip::File) : Array(Section)
          texts = slide_names(zip).compact_map do |name|
            read_entry(zip, name).try { |xml| slide_text(xml) }
          end
          combined = texts.reject(&.empty?).join("\n\n")
          combined.empty? ? [] of Section : [Section.new(nil, nil, combined)]
        end

        # Slide part names sorted by their numeric index.
        private def slide_names(zip : Compress::Zip::File) : Array(String)
          zip.entries.map(&.filename)
            .select!(&.matches?(SLIDE))
            .sort_by! { |name| SLIDE.match!(name)[1].to_i }
        end

        # All <a:t> run texts in one slide, newline-joined.
        private def slide_text(xml : String) : String
          parts = [] of String
          gather_text(XML.parse(xml), parts)
          parts.join("\n")
        end

        # Recursively collects the text of every <a:t> element.
        private def gather_text(node : XML::Node, parts : Array(String)) : Nil
          node.children.each do |child|
            next unless child.element?
            if child.name == "t"
              text = child.content.strip
              parts << text unless text.empty?
            else
              gather_text(child, parts)
            end
          end
        end
      end
    end
  end
end
