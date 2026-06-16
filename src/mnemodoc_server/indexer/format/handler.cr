module MnemodocServer
  module Indexer
    module Format
      # A format strategy: owns reading a file AND parsing it into Chunks.
      # The crawler dispatches to a Handler via the Registry and knows nothing
      # about the underlying format. Implementations MUST NOT raise on content
      # or IO errors: log a warning and return an empty array instead.
      abstract class Handler
        Log = ::Log.for("mnemodoc-server.indexer.format")

        abstract def extract(path : String, mtime : Int64) : Array(Chunk)
      end
    end
  end
end
