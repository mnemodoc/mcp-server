module MnemodocServer
  module Indexer
    # Generic, format-agnostic core: turns normalized Sections into search
    # Chunks. Owns the token budget, oversized-section splitting, and TOC
    # filtering. Extracted from the former Chunker so every format handler
    # shares the exact same chunk-construction behavior.
    class ChunkAssembler
      Log = ::Log.for("mnemodoc-server.indexer.chunk-assembler")

      # Soft cap (estimated tokens) above which a section is split further.
      # Kept well below nomic-embed-text's ~2048 limit for estimate margin.
      MAX_TOKENS = 1200

      # Inline-link patterns, grouped by markup family. Detection is applied
      # PER FILE EXTENSION (see link_patterns_for) so one format's grammar never
      # leaks into another's — e.g. RST/AsciiDoc syntaxes must not strip a
      # Markdown line. Only line-based formats whose handler feeds raw source
      # markup into bodies have patterns; DOM/Office formats (HTML, .docx, .odt,
      # EPUB, …) flatten links to plain text before chunking, so the strip is a
      # correct no-op for them.

      # Markdown inline link: [text](url).
      MARKDOWN_LINKS = [/\[[^\]]*\]\([^)]*\)/]

      # Org-mode bracketed links: [[url][description]] and [[url]].
      ORG_LINKS = [
        /\[\[[^\]]+\]\[[^\]]+\]\]/,
        /\[\[[^\]]+\]\]/,
      ]

      # AsciiDoc: link:/xref: macros, labelled and bare URLs, and <<anchor>>
      # cross-references. Scoped to .adoc/.asciidoc only, so the broad bare-URL
      # and <<…>> forms cannot strip a Markdown/Org line.
      ASCIIDOC_LINKS = [
        /link:[^\[]+\[[^\]]*\]/,
        /xref:[^\[]+\[[^\]]*\]/,
        /https?:\/\/[^\[\s]+\[[^\]]*\]/,
        /https?:\/\/[^\s\[]+/,
        /<<[^>]+>>/,
      ]

      # reStructuredText backtick references: `text <url>`_ and `text`_ (one or
      # two trailing underscores). The bare word_ reference form is deliberately
      # excluded — it matches any identifier ending in an underscore and would
      # over-strip lines of snake_case tokens; navigation bars use the backtick
      # forms above.
      RST_LINKS = [
        /`[^<`]+<[^>]*>`__?/,
        /`[^`]+`__?/,
      ]

      # Separators allowed around links on a navigation line: whitespace plus the
      # common breadcrumb glue (em dash, hyphen, middle dot, pipe, arrows).
      SEPARATOR_PATTERN = /[[:space:]—\-·|←→]/

      # Optional behaviours default to off (back-compatible) when no config given.
      def initialize(@chunking : ChunkingConfig = ChunkingConfig.from_yaml(""))
      end

      # True when, after removing the given markup's inline links and the allowed
      # separators, nothing but blank remains — i.e. the line is pure navigation.
      # `patterns` are the link regexes for the file's format (see
      # link_patterns_for), so one syntax never strips another format's line. A
      # blank line is not link-only (false): blanks are handled by the sectionizer.
      def self.link_only_line?(line : String, patterns : Array(Regex) = MARKDOWN_LINKS) : Bool
        return false if line.strip.empty?
        stripped = patterns.reduce(line) { |acc, pattern| acc.gsub(pattern, "") }
        stripped.gsub(SEPARATOR_PATTERN, "").blank?
      end

      # Selects the link patterns to strip for a file, by extension, so each
      # format is matched only against its own grammar. Unknown/DOM/plain
      # extensions fall back to Markdown's unambiguous [text](url) pattern, which
      # is a harmless no-op when no such link is present.
      def self.link_patterns_for(file_path : String) : Array(Regex)
        ext = File.extname(file_path).downcase
        return ORG_LINKS if ext.in?(Format::Org::EXTENSIONS)
        return ASCIIDOC_LINKS if ext.in?(Format::AsciiDoc::EXTENSIONS)
        return RST_LINKS if ext.in?(Format::Rst::EXTENSIONS)
        MARKDOWN_LINKS
      end

      # Builds chunks for one file. An empty sections list means the handler
      # found no headings: the whole raw_content is treated as a single
      # preamble section so it still gets token-aware splitting.
      def assemble(file_path : String, sections : Array(Section), raw_content : String, mtime : Int64) : Array(Chunk)
        effective = sections.empty? ? [Section.new(nil, nil, raw_content)] : sections
        effective = merge_preamble(effective) if @chunking.merge_preamble_into_first_section?
        chunks = [] of Chunk
        effective.each { |section| emit_section(file_path, section, mtime, chunks) }
        chunks
      end

      # Folds a leading preamble section (heading nil) into the first real
      # section so a lone breadcrumb/description never becomes its own chunk.
      # No-op unless there is a preamble followed by at least one section.
      private def merge_preamble(sections : Array(Section)) : Array(Section)
        return sections if sections.size < 2
        preamble = sections.first
        return sections unless preamble.heading.nil?
        first = sections[1]
        merged = Section.new(first.heading, first.parent_heading, "#{preamble.body}\n\n#{first.body}")
        [merged] + sections[2..]
      end

      # Appends one or more Chunks for a section; drops TOC and blank sections.
      private def emit_section(file_path : String, section : Section, mtime : Int64, chunks : Array(Chunk)) : Nil
        heading = section.heading
        return if heading && toc_heading?(heading)
        body = @chunking.strip_link_only_lines? ? strip_link_only_lines(section.body, file_path) : section.body
        text = body.strip
        return if text.empty?

        tokens = estimate_tokens(text)
        if tokens > MAX_TOKENS
          emit_split_section(file_path, heading, text, section.parent_heading, mtime, chunks)
        else
          chunks << Chunk.new(
            file_path: file_path,
            heading: heading,
            parent_heading: section.parent_heading,
            content: text,
            embedding: [] of Float32,
            token_count: tokens,
            mtime: mtime
          )
        end
      end

      # Emits hard-split pieces for an oversized section body.
      private def emit_split_section(file_path : String, heading : String?, text : String, parent : String?, mtime : Int64, chunks : Array(Chunk)) : Nil
        hard_split(text).each_with_index do |part, i|
          piece_heading = heading.nil? ? nil : (i == 0 ? heading : "#{heading} (suite)")
          chunks << Chunk.new(
            file_path: file_path,
            heading: piece_heading,
            parent_heading: parent,
            content: part.strip,
            embedding: [] of Float32,
            token_count: estimate_tokens(part),
            mtime: mtime
          )
        end
      end

      # Splits text into pieces each within MAX_TOKENS: reduce to atomic units
      # that individually fit, then greedily pack them back together.
      private def hard_split(text : String) : Array(String)
        pieces = pack(atomic_units(text))
        pieces.empty? ? [text] : pieces
      end

      # Breaks text into units within MAX_TOKENS, descending in granularity:
      # paragraphs, then lines, then fixed character windows.
      private def atomic_units(text : String) : Array(String)
        units = [] of String
        text.split(/\n\n+/).each do |para|
          if estimate_tokens(para) <= MAX_TOKENS
            units << para
          else
            para.each_line do |line|
              if estimate_tokens(line) <= MAX_TOKENS
                units << line
              else
                slice_by_chars(line, units)
              end
            end
          end
        end
        units
      end

      # Slices an oversized line into fixed character windows.
      private def slice_by_chars(line : String, units : Array(String)) : Nil
        pos = 0
        while pos < line.size
          units << line[pos, MAX_TOKENS]
          pos += MAX_TOKENS
        end
      end

      # Greedily concatenates units into pieces within MAX_TOKENS.
      # Uses the actual joined token count (not a running sum) so that newline
      # separators between units never push a piece silently over the budget.
      private def pack(units : Array(String)) : Array(String)
        result = [] of String
        current = [] of String
        units.each do |unit|
          candidate = current + [unit]
          if estimate_tokens(candidate.join("\n")) > MAX_TOKENS && !current.empty?
            result << current.join("\n")
            current = [unit]
          else
            current << unit
          end
        end
        result << current.join("\n") unless current.empty?
        result
      end

      # Conservative token estimate: max of word-based and char-based so dense
      # content (tables, code) cannot silently exceed the model context.
      private def estimate_tokens(text : String) : Int32
        word_based = (text.split(/\s+/).size * 1.3).to_i
        char_based = (text.size / 3.0).to_i
        Math.max(word_based, char_based)
      end

      # Drops pure-navigation lines (links + separators only) from a body, using
      # the file's format-specific link patterns. Keeps blank lines and any line
      # carrying real text. Joined with "\n"; the caller strips the result, so
      # collapsed edge newlines don't matter.
      private def strip_link_only_lines(body : String, file_path : String) : String
        patterns = ChunkAssembler.link_patterns_for(file_path)
        body.each_line.reject { |line| ChunkAssembler.link_only_line?(line, patterns) }.join('\n')
      end

      # True for navigational table-of-contents headings (no retrieval value).
      private def toc_heading?(heading : String) : Bool
        !(/(table des matières|table of contents|sommaire)/i =~ heading).nil?
      end
    end
  end
end
