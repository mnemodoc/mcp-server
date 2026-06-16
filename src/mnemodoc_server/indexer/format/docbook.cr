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

        def extract(path : String, mtime : Int64) : Array(Chunk)
          sections = NestedXml.sections(XML.parse(File.read(path)), SECTIONS, TITLES, PARAGRAPHS)
          @assembler.assemble(path, sections, "", mtime)
        rescue ex : File::Error
          Log.warn { "read failed for #{path}: #{ex.message}" }
          [] of Chunk
        rescue ex
          Log.warn { "docbook parse failed for #{path}: #{ex.message}" }
          [] of Chunk
        end
      end
    end
  end
end
