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

        # Reads a document as text, dropping byte sequences that are not valid
        # UTF-8 instead of carrying them into the String.
        #
        # `File.read` without an encoding hands back the bytes as they are, so a
        # latin-1 file — an ordinary thing in an older French corpus — yields a
        # String that looks fine until the first regex, which raises
        # `ArgumentError: Regex match error`. Since the handlers are the only
        # place that reads documents, decoding once here is what keeps that byte
        # from reaching a heading matcher or the token estimator.
        #
        # Dropping the offending bytes loses the accent rather than the file:
        # "Café" indexes as "Caf". Valid UTF-8 passes through untouched, accents
        # included — the alternative, `String#scrub`, would stud the index with
        # replacement characters instead.
        protected def read_text(path : String) : String
          File.read(path, encoding: "UTF-8", invalid: :skip)
        end
      end
    end
  end
end
