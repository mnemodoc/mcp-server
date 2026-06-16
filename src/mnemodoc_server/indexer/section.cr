module MnemodocServer
  module Indexer
    # A normalized document section produced by a format handler: a heading
    # (nil for preamble text before the first heading), the parent heading it
    # nests under, and the raw body text. The ChunkAssembler turns these into
    # search Chunks.
    struct Section
      getter heading : String?
      getter parent_heading : String?
      getter body : String

      def initialize(@heading : String?, @parent_heading : String?, @body : String)
      end
    end
  end
end
