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

        def extract(path : String, mtime : Int64) : Document
          sz = @odp.sectionize_document(XML.parse(read_text(path)))
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
          Log.warn { "flat-odf parse failed for #{path}: #{ex.message}" }
          Document.empty
        end
      end
    end
  end
end
