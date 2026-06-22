module MnemodocServer
  module Indexer
    module Format
      # Maps file extensions to format handlers and applies the dispatch rules:
      # a discovered file is filtered by extension; a file named explicitly in
      # `paths:` falls back to plain text when its extension is unknown. PDF is
      # registered only when enabled and pdftotext is available.
      class Registry
        Log = ::Log.for("mnemodoc-server.indexer.format.registry")

        def initialize(config : Config, pdf_available : Bool = !Process.find_executable("pdftotext").nil?)
          @handlers = {} of String => Handler
          assembler = ChunkAssembler.new(config.chunking)
          markdown = Markdown.new(assembler)
          @plain = Plain.new(assembler)

          register(Markdown::EXTENSIONS, markdown)
          register(Org::EXTENSIONS, Org.new(assembler))
          register(AsciiDoc::EXTENSIONS, AsciiDoc.new(assembler))
          register(Rst::EXTENSIONS, Rst.new(assembler))
          html = Html.new(assembler)
          register(Html::EXTENSIONS, html)
          register(Notebook::EXTENSIONS, Notebook.new(markdown, assembler))
          register(Plain::EXTENSIONS, @plain)
          register(Docx::EXTENSIONS, Docx.new(assembler))
          odt = Odt.new(assembler)
          register(Odt::EXTENSIONS, odt)
          register(Pptx::EXTENSIONS, Pptx.new(assembler))
          register(Epub::EXTENSIONS, Epub.new(assembler, html))
          odp = Odp.new(assembler)
          register(Odp::EXTENSIONS, odp)
          register(Fodt::EXTENSIONS, Fodt.new(assembler, odt))
          register(Fodp::EXTENSIONS, Fodp.new(assembler, odp))
          register(DocBook::EXTENSIONS, DocBook.new(assembler))
          register(Dita::EXTENSIONS, Dita.new(assembler))
          register(FictionBook::EXTENSIONS, FictionBook.new(assembler))

          if config.index.pdf?
            if pdf_available
              register(Pdf::EXTENSIONS, Pdf.new(assembler))
            else
              Log.warn { "index.pdf is enabled but pdftotext was not found in PATH; PDF files will be skipped" }
            end
          end
        end

        # Returns the handler for a path, applying the discovered/named rule.
        def for(path : String, explicit : Bool) : Handler?
          ext = File.extname(path).downcase
          @handlers[ext]? || (explicit ? @plain : nil)
        end

        # True when the extension has a dedicated handler (used by the glob).
        def supported?(ext : String) : Bool
          @handlers.has_key?(ext.downcase)
        end

        # All registered extensions.
        def extensions : Set(String)
          @handlers.keys.to_set
        end

        private def register(exts : Array(String), handler : Handler) : Nil
          exts.each { |ext| @handlers[ext] = handler }
        end
      end
    end
  end
end
