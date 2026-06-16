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

      # Builds chunks for one file. An empty sections list means the handler
      # found no headings: the whole raw_content is treated as a single
      # preamble section so it still gets token-aware splitting.
      def assemble(file_path : String, sections : Array(Section), raw_content : String, mtime : Int64) : Array(Chunk)
        effective = sections.empty? ? [Section.new(nil, nil, raw_content)] : sections
        chunks = [] of Chunk
        effective.each { |section| emit_section(file_path, section, mtime, chunks) }
        chunks
      end

      # Appends one or more Chunks for a section; drops TOC and blank sections.
      private def emit_section(file_path : String, section : Section, mtime : Int64, chunks : Array(Chunk)) : Nil
        heading = section.heading
        return if heading && toc_heading?(heading)
        text = section.body.strip
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

      # True for navigational table-of-contents headings (no retrieval value).
      private def toc_heading?(heading : String) : Bool
        !(/(table des matières|table of contents|sommaire)/i =~ heading).nil?
      end
    end
  end
end
