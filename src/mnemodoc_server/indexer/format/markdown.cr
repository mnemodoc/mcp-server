module MnemodocServer
  module Indexer
    module Format
      # Markdown / MDX handler. Splits a document along its ## (level 2) and
      # ### (level 3) headings, stripping a leading YAML frontmatter block.
      # MDX flows through unchanged (JSX is treated as text).
      class Markdown < Handler
        # Markdown plus common aliases and Markdown-based document formats
        # (Quarto .qmd, R Markdown .rmd), all parsed as Markdown.
        EXTENSIONS = %w(.md .markdown .mdx .mkd .mdown .mdwn .markdn .mdtext .mmd .qmd .rmd)

        def initialize(@assembler : ChunkAssembler)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          content = strip_frontmatter(File.read(path))
          @assembler.assemble(path, parse_sections(content), content, mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        end

        # Parses Markdown text into Sections. Public so Format::Notebook can
        # reuse Markdown heading semantics for notebook markdown cells.
        def parse_sections(content : String) : Array(Section)
          sz = Sectionizer.new
          content.each_line do |line|
            stripped = line.strip
            if match = stripped.match(/^(###|##)\s+.+/)
              sz.heading(match[1] == "###" ? 3 : 2, stripped)
            else
              sz.text(line.chomp)
            end
          end
          sz.sections
        end

        # Drops a leading YAML frontmatter block delimited by `---` lines.
        private def strip_frontmatter(content : String) : String
          return content unless content.starts_with?("---")
          lines = content.lines
          end_idx = lines.index(1) { |line| line.strip == "---" }
          return content unless end_idx
          lines[(end_idx + 1)..].join
        end
      end
    end
  end
end
