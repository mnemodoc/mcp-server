module MnemodocServer
  module Indexer
    module Format
      # Tracks whether the line being parsed sits inside a verbatim block.
      #
      # Every line-based markup here recognises headings by a leading marker —
      # `#` for Markdown, `*` for Org, `=` for AsciiDoc — and every one of them
      # also has blocks where those markers are ordinary characters: a shell
      # comment, a bullet in a code sample, an equals sign in a config snippet.
      # Without this state the parsers cut such a block in two, left an orphan
      # opening delimiter in one chunk, and indexed a line of code as a section
      # title.
      #
      # Two shapes are covered. A symmetric delimiter (Markdown's ```, AsciiDoc's
      # ----) opens and closes with the same pattern; a paired one (Org's
      # `#+BEGIN_`/`#+END_`) uses two. Nesting is deliberately not modelled: none
      # of these formats nests blocks of the same kind, and a tracker that
      # counted depth would mis-handle an unbalanced delimiter far worse than
      # one that simply toggles.
      class FenceTracker
        # Markdown and MDX: ``` or ~~~, indented or not.
        MARKDOWN = /^\s*(```|~~~)/

        # AsciiDoc listing and literal blocks: four or more dashes or dots.
        ASCIIDOC = /^\s*(-{4,}|\.{4,})\s*$/

        # Org blocks: #+BEGIN_SRC, #+BEGIN_EXAMPLE, #+BEGIN_QUOTE…
        ORG_OPEN  = /^\s*#\+BEGIN_/i
        ORG_CLOSE = /^\s*#\+END_/i

        getter? inside : Bool = false

        def initialize(@open : Regex, @close : Regex? = nil)
        end

        def self.markdown : self
          new(MARKDOWN)
        end

        def self.asciidoc : self
          new(ASCIIDOC)
        end

        def self.org : self
          new(ORG_OPEN, ORG_CLOSE)
        end

        # Feeds one line to the state machine and reports whether it is itself a
        # delimiter. A delimiter is never a heading, so callers treat both it and
        # anything `inside?` as plain text.
        def delimiter?(line : String) : Bool
          if @inside
            return false unless (@close || @open).matches?(line)
            @inside = false
            true
          else
            return false unless @open.matches?(line)
            @inside = true
            true
          end
        end
      end
    end
  end
end
