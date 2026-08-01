module MnemodocServer
  module Indexer
    module Format
      # FictionBook (.fb2) handler. FB2 is an XML e-book format: nested <section>
      # elements each hold a <title> and <p> paragraphs. Heading level follows
      # section nesting depth. Reads the file directly (FB2 is a plain XML file).
      # Never raises.
      class FictionBook < Handler
        EXTENSIONS = %w(.fb2)

        SECTIONS   = Set{"section"}
        TITLES     = Set{"title"}
        PARAGRAPHS = Set{"p"}

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
          Log.warn { "fictionbook parse failed for #{path}: #{ex.message}" }
          Document.empty
        end
      end
    end
  end
end
