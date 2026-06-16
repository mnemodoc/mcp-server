module MnemodocServer
  module Indexer
    module Format
      # PDF handler: shells out to pdftotext (an external, opt-in dependency)
      # and treats the extracted text as plain content. Any failure — missing
      # binary, non-zero exit, corrupt file — yields no chunks instead of
      # raising, so PDF never aborts the indexing run. The command is
      # injectable for testing.
      class Pdf < Handler
        EXTENSIONS = %w(.pdf)

        def initialize(@assembler : ChunkAssembler, @command : String = "pdftotext")
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          text = run_pdftotext(path)
          return [] of Chunk if text.nil?
          @assembler.assemble(path, [] of Section, text, mtime)
        end

        # Runs `<command> <path> -` and returns stdout, or nil on any failure.
        private def run_pdftotext(path : String) : String?
          output = IO::Memory.new
          status = Process.run(@command, args: [path, "-"], output: output, error: Process::Redirect::Close)
          unless status.success?
            Log.warn { "pdftotext failed for #{path} (exit #{status.exit_code})" }
            return nil
          end
          output.to_s
        rescue ex
          Log.warn { "pdftotext error for #{path}: #{ex.message}" }
          nil
        end
      end
    end
  end
end
