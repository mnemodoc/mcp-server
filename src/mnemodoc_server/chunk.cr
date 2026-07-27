module MnemodocServer
  # A single indexed section of a Markdown file, carrying its text, the
  # heading hierarchy it belongs to, and the embedding vector used for
  # semantic search. The embedding is empty until the embedder fills it in.
  struct Chunk
    getter file_path : String
    getter heading : String?
    getter parent_heading : String?
    getter content : String
    getter embedding : Array(Float32)
    getter token_count : Int32
    getter mtime : Int64
    # The `chunks.id` this came from, set only by the store's readers. Nil for a
    # chunk that has not been persisted yet (everything the indexer builds), so
    # it identifies a chunk but cannot be relied on to exist. Search fusion uses
    # it as the key that tells two chunks apart: file path and heading do not,
    # since one file routinely holds several chunks under the same heading.
    getter id : Int64?

    def initialize(
      @file_path : String,
      @heading : String?,
      @parent_heading : String?,
      @content : String,
      @embedding : Array(Float32),
      @token_count : Int32,
      @mtime : Int64,
      @id : Int64? = nil,
    )
    end
  end

  # Metadata about an indexed file, returned by the list_files tool and the
  # status command. Aggregates the file's mtime, last index time, and how
  # many chunks it currently contributes to the index.
  struct FileInfo
    getter path : String
    getter mtime : Int64
    getter indexed_at : Int64
    getter chunk_count : Int32

    def initialize(@path, @mtime, @indexed_at, @chunk_count)
    end
  end
end
