module MnemodocServer
  module Indexer
    module Format
      # DocBook handler. DocBook is a structured documentation XML vocabulary:
      # nested <section>/<chapter>/<sect1..5> containers each hold a <title> and
      # <para> body. Heading level follows nesting depth. Reads the file directly
      # (DocBook is a plain XML file, not an archive). Never raises.
      class DocBook < Handler
        EXTENSIONS = %w(.dbk .docbook)

        SECTIONS = Set{"book", "article", "part", "chapter", "preface", "appendix",
                       "section", "sect1", "sect2", "sect3", "sect4", "sect5"}
        TITLES     = Set{"title"}
        PARAGRAPHS = Set{"para", "simpara"}

        def initialize(@assembler : ChunkAssembler)
        end

        def extract(path : String, mtime : Int64) : Document
          sz = NestedXml.sectionize(XML.parse(read_text(path)), SECTIONS, TITLES, PARAGRAPHS)
          # verbatim is false: the file is XML markup, and the document is the
          # prose the walk pulled out of it.
          Document.new(
            text: sz.normalized_text,
            verbatim: false,
            outline: sz.outline,
            chunks: @assembler.assemble(path, sz.sections, sz.normalized_text, mtime),
          )
        rescue ex : File::Error | DocumentTooLarge
          Log.warn { "read failed for #{path}: #{ex.message}" }
          Document.empty
        rescue ex
          Log.warn { "docbook parse failed for #{path}: #{ex.message}" }
          Document.empty
        end
      end
    end
  end
end
