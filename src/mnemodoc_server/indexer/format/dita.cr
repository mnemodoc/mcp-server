module MnemodocServer
  module Indexer
    module Format
      # DITA handler. DITA topics are structured documentation XML: a
      # <topic>/<concept>/<task>/<reference> (or nested <section>) holds a
      # <title> and <p> body. Heading level follows nesting depth. Reads the file
      # directly (a DITA topic is a plain XML file). Never raises.
      #
      # Only `.dita` topics are handled; `.ditamap` is intentionally excluded —
      # a map carries <topicref> references, not prose, so it has nothing to index.
      class Dita < Handler
        EXTENSIONS = %w(.dita)

        SECTIONS   = Set{"topic", "concept", "task", "reference", "section"}
        TITLES     = Set{"title"}
        PARAGRAPHS = Set{"p", "shortdesc"}

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
          Log.warn { "dita parse failed for #{path}: #{ex.message}" }
          Document.empty
        end
      end
    end
  end
end
