module MnemodocServer
  module Indexer
    module Format
      # Plain-text handler: no heading detection. The whole file becomes one
      # preamble that the assembler token-splits. Also the registry's fallback
      # for files named explicitly in `paths:` with an unknown extension.
      class Plain < Handler
        EXTENSIONS = %w(.txt .text)

        def initialize(@assembler : ChunkAssembler)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          content = File.read(path)
          @assembler.assemble(path, [] of Section, content, mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        end
      end
    end
  end
end
