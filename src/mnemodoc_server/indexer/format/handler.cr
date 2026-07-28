module MnemodocServer
  module Indexer
    module Format
      # A format strategy: owns reading a file AND parsing it into Chunks.
      # The crawler dispatches to a Handler via the Registry and knows nothing
      # about the underlying format. Implementations MUST NOT raise on content
      # or IO errors: log a warning and return an empty array instead.
      # Raised when a document exceeds index.max_file_size. Handlers turn it
      # into an empty result, like any other unreadable input.
      class DocumentTooLarge < Exception
        def initialize(path : String)
          super("#{path} exceeds index.max_file_size")
        end
      end

      abstract class Handler
        Log = ::Log.for("mnemodoc-server.indexer.format")

        # Largest document this handler will read whole, in bytes. The registry
        # sets it from index.max_file_size on every handler it builds. Held per
        # instance, not per class: two configurations coexist in one process —
        # the daemon and the proxy's in-process fallback — and a class-level
        # value would have them overwrite each other's limit.
        DEFAULT_MAX_BYTES = 10_i64 * 1024 * 1024

        property max_bytes : Int64 = DEFAULT_MAX_BYTES

        abstract def extract(path : String, mtime : Int64) : Array(Chunk)

        # True when the file is larger than we are willing to hold in memory.
        # Handlers read whole documents, so without this a stray dump in an
        # indexed directory is resident in full, once per concurrent worker.
        protected def too_large?(path : String) : Bool
          limit = @max_bytes
          return false if limit <= 0
          size = File.size(path)
          return false if size <= limit
          Log.warn { "skipping #{path}: #{size} bytes exceeds index.max_file_size (#{limit})" }
          true
        end

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
          raise DocumentTooLarge.new(path) if too_large?(path)
          File.read(path, encoding: "UTF-8", invalid: :skip)
        end
      end
    end
  end
end
