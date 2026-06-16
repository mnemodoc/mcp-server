module MnemodocServer
  module Indexer
    module Format
      # Flat ODF presentation (.fodp) handler. A flat-ODF file is a single,
      # un-zipped XML document with the same content model as .odp's content.xml,
      # so this reads the file directly and reuses the Odp walk. Never raises.
      class Fodp < Handler
        EXTENSIONS = %w(.fodp)

        def initialize(@assembler : ChunkAssembler, @odp : Odp)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          sections = @odp.sections_from_document(XML.parse(File.read(path)))
          @assembler.assemble(path, sections, "", mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        rescue ex
          Log.warn { "flat-odf parse failed for #{path}: #{ex.message}" }
          [] of Chunk
        end
      end
    end
  end
end
