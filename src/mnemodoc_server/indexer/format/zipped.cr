require "compress/zip"

module MnemodocServer
  module Indexer
    module Format
      # Shared base for document formats stored as a ZIP archive of XML parts
      # (OOXML docx/pptx, ODF odt, EPUB). Owns opening the archive and the
      # never-raise contract; subclasses implement `parse` to turn the open
      # archive into normalized Sections. Pure stdlib (Compress::Zip + XML),
      # so these formats need no external tool and are indexed by default.
      abstract class Zipped < Handler
        def initialize(@assembler : ChunkAssembler)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          sections = Compress::Zip::File.open(path) { |zip| parse(zip) }
          @assembler.assemble(path, sections, "", mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        rescue ex
          Log.warn { "zip/xml parse failed for #{path}: #{ex.message}" }
          [] of Chunk
        end

        # Builds normalized Sections from the open archive. Implementations read
        # the relevant entries and walk their XML; they may assume the archive is
        # open and need not rescue (the base turns any error into an empty result).
        abstract def parse(zip : Compress::Zip::File) : Array(Section)

        # Reads one archive entry as a string, or nil if absent.
        private def read_entry(zip : Compress::Zip::File, name : String) : String?
          zip[name]?.try &.open(&.gets_to_end)
        end
      end
    end
  end
end
