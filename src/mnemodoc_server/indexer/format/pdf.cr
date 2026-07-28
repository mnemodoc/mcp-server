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

        # Wall-clock bound on one conversion. Process.run has no timeout of its
        # own, so without this a converter that never returns parks the worker
        # fiber for good — index.concurrency such files and the run stops, with
        # nothing logged to explain the silence.
        DEFAULT_TIMEOUT = 60.seconds

        def initialize(@assembler : ChunkAssembler, @command : String = "pdftotext",
                       @timeout : Time::Span = DEFAULT_TIMEOUT)
        end

        def extract(path : String, mtime : Int64) : Array(Chunk)
          text = run_pdftotext(path)
          return [] of Chunk if text.nil?
          @assembler.assemble(path, [] of Section, text, mtime)
        end

        # Runs `<command> <path> -` and returns stdout, or nil on any failure.
        private def run_pdftotext(path : String) : String?
          output = IO::Memory.new
          process = Process.new(@command, args: [path, "-"], output: output, error: Process::Redirect::Close)
          # Waiting happens in a fiber so the timer can win the race. There is
          # no interruptible wait to select on otherwise, and a converter stuck
          # on a malformed file would hold the worker indefinitely.
          finished = Channel(Process::Status).new(1)
          spawn { finished.send(process.wait) }

          status = select
          when result = finished.receive
            result
          when timeout(@timeout)
            Log.warn { "pdftotext timed out after #{@timeout.total_seconds}s for #{path}" }
            process.terminate(graceful: false) rescue nil
            # Deliberately not waiting again: the point of the timeout
            # is to stop waiting. The reaping fiber completes on its
            # own into the buffered channel.
            return nil
          end

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
