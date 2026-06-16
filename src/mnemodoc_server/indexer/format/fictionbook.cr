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

        def extract(path : String, mtime : Int64) : Array(Chunk)
          sections = NestedXml.sections(XML.parse(File.read(path)), SECTIONS, TITLES, PARAGRAPHS)
          @assembler.assemble(path, sections, "", mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        rescue ex
          Log.warn { "fictionbook parse failed for #{path}: #{ex.message}" }
          [] of Chunk
        end
      end
    end
  end
end
