module MnemodocServer
  module Indexer
    # One entry of a document's plan: a heading, the nesting level the
    # sectionizer resolved for it, and the line it starts on.
    #
    # start_line indexes the Document's own text, never the file on disk. A
    # handler that reads a text file passes the true source line; one that
    # builds its text by extraction lets the sectionizer number what it emits.
    struct OutlineEntry
      getter level : Int32
      getter title : String
      getter start_line : Int32

      def initialize(@level : Int32, @title : String, @start_line : Int32)
      end
    end

    # What a format handler produces for one file: the document text, whether
    # that text is the file verbatim, the plan, and the chunks to embed.
    #
    # verbatim is false whenever text is an extraction — a .docx, a notebook's
    # synthesised markdown, an HTML DOM walk. It is what lets a reader say
    # whether the line numbers it returns are the ones in the user's editor or a
    # numbering private to MnemoDoc.
    struct Document
      getter text : String
      getter? verbatim : Bool
      getter outline : Array(OutlineEntry)
      getter chunks : Array(Chunk)

      def initialize(@text : String, @verbatim : Bool, @outline : Array(OutlineEntry), @chunks : Array(Chunk))
      end

      # What every failure path returns, in place of the empty chunk array
      # handlers used to hand back.
      def self.empty : Document
        new(text: "", verbatim: false, outline: [] of OutlineEntry, chunks: [] of Chunk)
      end

      # Lines of `text`, not of the file: for an extracted document only `text`
      # exists to count.
      def line_count : Int32
        @text.lines.size
      end
    end
  end
end
