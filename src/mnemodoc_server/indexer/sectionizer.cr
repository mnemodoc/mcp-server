module MnemodocServer
  module Indexer
    # Accumulates headings and text into a list of Sections, resolving each
    # heading's parent as the nearest preceding heading of strictly smaller
    # level (a heading stack). Text emitted before the first heading becomes a
    # preamble section with a nil heading. Shared by all line/DOM-based handlers.
    #
    # It is also the single capture point for the document's outline and, for
    # handlers whose text does not exist as a file, for the text itself: it is
    # the one place that sees every heading with its level and every body line,
    # in order.
    class Sectionizer
      def initialize
        @sections = [] of Section
        @stack = [] of {level: Int32, text: String}
        @heading = nil.as(String?)
        @parent = nil.as(String?)
        @body = IO::Memory.new
        @outline = [] of OutlineEntry
        @normalized = IO::Memory.new
        @line_no = 0
      end

      # Opens a new section at the given level; closes the current one first.
      #
      # source_line, when given, is the heading's true line in the file the
      # handler read, and wins over the internal counter — which numbers the
      # text this class accumulates, and would otherwise drift from the file
      # wherever a handler drops or rewrites lines (frontmatter, RST adornments).
      def heading(level : Int32, text : String, source_line : Int32? = nil) : Nil
        flush
        emit(text)
        while !@stack.empty? && @stack.last[:level] >= level
          @stack.pop
        end
        @parent = @stack.last?.try(&.[:text])
        @heading = text
        @stack << {level: level, text: text}
        # Recorded even when the section that follows turns out to be blank: a
        # heading with nothing but sub-headings under it is still a place in the
        # document, and the outline describes the document, not the chunks.
        @outline << OutlineEntry.new(level, text, source_line || @line_no)
      end

      # Appends a line of body text to the current section.
      def text(line : String) : Nil
        emit(line)
        @body << line << '\n'
      end

      # Returns all sections, flushing the final pending one.
      def sections : Array(Section)
        flush
        @sections
      end

      # The document's plan, in document order.
      def outline : Array(OutlineEntry)
        @outline
      end

      # Every line this sectionizer was given, headings included, in order. What
      # a handler stores when the file it read is not itself the document text.
      def normalized_text : String
        @normalized.to_s
      end

      # Appends another sectionizer's whole result to this one, shifting its
      # outline by the lines already accumulated here. What a container format
      # made of several parsed parts — an EPUB's chapters — uses to end up with
      # one document text and one outline that agree on their line numbers.
      def absorb(other : Sectionizer) : Nil
        flush
        offset = @line_no
        other_sections = other.sections
        other_text = other.normalized_text
        @normalized << other_text
        @line_no += other_text.lines.size
        @sections.concat(other_sections)
        other.outline.each do |entry|
          @outline << OutlineEntry.new(entry.level, entry.title, entry.start_line + offset)
        end
      end

      # Appends one line to the accumulated text and advances the counter, so
      # @line_no is always the number of the line just written.
      private def emit(line : String) : Nil
        @line_no += 1
        @normalized << line << '\n'
      end

      # Emits the pending section unless its body is blank.
      private def flush : Nil
        content = @body.to_s.strip
        @sections << Section.new(@heading, @parent, content) unless content.empty?
        @body = IO::Memory.new
      end
    end
  end
end
