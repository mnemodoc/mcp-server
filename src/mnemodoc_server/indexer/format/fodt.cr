module MnemodocServer
  module Indexer
    module Format
      # Flat ODF text (.fodt) handler. A flat-ODF file is a single, un-zipped XML
      # document with the same content model as .odt's content.xml, so this reads
      # the file directly and reuses the Odt walk. Never raises on IO/XML errors.
      class Fodt < Handler
        EXTENSIONS = %w(.fodt)

        def initialize(@assembler : ChunkAssembler, @odt : Odt)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          sections = @odt.sections_from_document(XML.parse(File.read(path)))
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
