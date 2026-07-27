module MnemodocServer
  module Indexer
    module Format
      # Markdown / MDX handler. Splits a document along its #, ## and ###
      # headings, stripping a leading YAML frontmatter block.
      # MDX flows through unchanged (JSX is treated as text).
      class Markdown < Handler
        # Markdown plus common aliases and Markdown-based document formats
        # (Quarto .qmd, R Markdown .rmd), all parsed as Markdown.
        EXTENSIONS = %w(.md .markdown .mdx .mkd .mdown .mdwn .markdn .mdtext .mmd .qmd .rmd)

        def initialize(@assembler : ChunkAssembler)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          content = strip_frontmatter(read_text(path))
          @assembler.assemble(path, parse_sections(content), content, mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        end

        # Parses Markdown text into Sections. Public so Format::Notebook can
        # reuse Markdown heading semantics for notebook markdown cells.
        def parse_sections(content : String) : Array(Section)
          sz = Sectionizer.new
          fence = FenceTracker.markdown
          content.each_line do |line|
            stripped = line.strip
            # A delimiter, and everything it encloses, is text whatever it looks
            # like: the markers that open a heading are ordinary characters in a
            # code sample.
            if fence.delimiter?(line) || fence.inside?
              sz.text(line.chomp)
              next
            end
            # Level 1 counts as a heading, like Org's `*` and AsciiDoc's `=`.
            # Excluding it dropped the document title into the preamble, which
            # produced a chunk whose whole content was that title line.
            if match = stripped.match(/^(###|##|#)\s+.+/)
              sz.heading(match[1].size, stripped)
            else
              sz.text(line.chomp)
            end
          end
          sz.sections
        end

        # Drops a leading YAML frontmatter block delimited by `---` lines.
        #
        # The rejoin has to name its separator: `String#lines` chomps, so
        # joining the remainder without one welds the whole document into a
        # single line — headings stop being headings and words from adjacent
        # lines run together, silently, for every file carrying frontmatter.
        private def strip_frontmatter(content : String) : String
          lines = content.lines
          return content unless lines.first?.try(&.strip) == "---"
          end_idx = lines.index(1) { |line| line.strip == "---" }
          return content unless end_idx
          return content unless frontmatter?(lines[1...end_idx].join("\n"))
          lines[(end_idx + 1)..].join("\n")
        end

        # Tells a frontmatter block from the prose between two horizontal rules.
        # Both open the document with `---`, and only one of them is metadata to
        # drop: frontmatter is YAML, and specifically a mapping, where prose
        # parses as a plain scalar or not at all. An empty block counts, since
        # `---` immediately followed by `---` carries no prose to lose.
        private def frontmatter?(block : String) : Bool
          return true if block.blank?
          !YAML.parse(block).as_h?.nil?
        rescue YAML::ParseException
          false
        end
      end
    end
  end
end
