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

        def extract(path : String, mtime : Int64) : Array(Chunk)
          sections = NestedXml.sections(XML.parse(File.read(path)), SECTIONS, TITLES, PARAGRAPHS)
          @assembler.assemble(path, sections, "", mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        rescue ex
          Log.warn { "dita parse failed for #{path}: #{ex.message}" }
          [] of Chunk
        end
      end
    end
  end
end
