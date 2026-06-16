module MnemodocServer
  module Indexer
    # Accumulates headings and text into a list of Sections, resolving each
    # heading's parent as the nearest preceding heading of strictly smaller
    # level (a heading stack). Text emitted before the first heading becomes a
    # preamble section with a nil heading. Shared by all line/DOM-based handlers.
    class Sectionizer
      def initialize
        @sections = [] of Section
        @stack = [] of {level: Int32, text: String}
        @heading = nil.as(String?)
        @parent = nil.as(String?)
        @body = IO::Memory.new
      end

      # Opens a new section at the given level; closes the current one first.
      def heading(level : Int32, text : String) : Nil
        flush
        while !@stack.empty? && @stack.last[:level] >= level
          @stack.pop
        end
        @parent = @stack.last?.try(&.[:text])
        @heading = text
        @stack << {level: level, text: text}
      end

      # Appends a line of body text to the current section.
      def text(line : String) : Nil
        @body << line << '\n'
      end

      # Returns all sections, flushing the final pending one.
      def sections : Array(Section)
        flush
        @sections
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
