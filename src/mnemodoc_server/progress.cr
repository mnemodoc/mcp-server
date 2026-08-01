module MnemodocServer
  # Reports the progress of a long run as a sequence of named phases.
  #
  # Both the destination and the terminal decision are injected rather than
  # read from STDERR here: the caller is the only place that knows whether the
  # output is a terminal, a pipe or a log file, and a reporter that consulted
  # the process's own streams could not be tested without a terminal attached
  # to the spec runner.
  #
  # Colours are written by hand for the same reason — `Colorize.enabled?` is a
  # process-wide flag derived from STDOUT and STDERR, so it would make the
  # rendering depend on how the suite happens to be invoked.
  class Progress
    # Width of the bar in characters. Fixed rather than derived from the
    # terminal width: the width is only reachable through an ioctl, and a bar
    # that stays put is easier to read than one that reflows on resize.
    BAR_WIDTH = 25

    FILLED = '█'
    EMPTY  = '░'

    private DIM   = "\e[2m"
    private GREEN = "\e[32m"
    private RESET = "\e[0m"

    # Clears from the cursor to the end of the line, so a shorter update can
    # never leave the tail of a longer one behind.
    private CLEAR_LINE = "\r\e[K"

    @label : String?
    @total : Int32?

    def initialize(@io : IO, @tty : Bool)
      @label = nil
      @total = nil
    end

    # Opens a phase. A nil total means the denominator is not known yet — the
    # scan cannot know how many files it will find until it has found them —
    # and the phase then reports a running count instead of a fraction.
    def start(label : String, total : Int32? = nil) : Nil
      @label = label
      @total = total

      unless @tty
        @io.puts "#{label}..."
        return
      end

      # Nothing to do is a legitimate outcome: say so once instead of drawing
      # a bar that is complete before it is displayed.
      if total && total <= 0
        done
        return
      end

      render(0)
    end

    # Reports that `count` units of the current phase are complete.
    def advance(count : Int32) : Nil
      return unless @label
      return unless @tty

      render(count)
    end

    # Closes the current phase, keeping only its label: a screen full of
    # finished bars carries no more information than a list of finished steps.
    # A no-op when no phase is open, since callers close from an ensure block
    # on paths that may have failed before starting one.
    def done : Nil
      label = @label
      return unless label
      @label = nil
      @total = nil

      return unless @tty

      @io << CLEAR_LINE << GREEN << "✓" << RESET << " " << label << " — done\n"
      @io.flush
    end

    private def render(count : Int32) : Nil
      label = @label
      return unless label

      @io << CLEAR_LINE << "· " << label
      if total = @total
        @io << "  "
        draw_bar(count, total)
        @io << "  " << percent(count, total) << "%"
      else
        @io << " — " << count << " found"
      end
      @io.flush
    end

    private def draw_bar(count : Int32, total : Int32) : Nil
      filled = (BAR_WIDTH * count / total).round.to_i.clamp(0, BAR_WIDTH)
      @io << FILLED.to_s * filled
      @io << DIM << EMPTY.to_s * (BAR_WIDTH - filled) << RESET
    end

    # Guarded against a zero total, which `start` normally closes before any
    # rendering happens — but `advance` is reachable from a caller holding its
    # own count.
    private def percent(count : Int32, total : Int32) : Int32
      return 100 if total <= 0
      (100 * count / total).round.to_i.clamp(0, 100)
    end

    # Turns the crawler's two reporters into the two phases of a run.
    #
    # The crawler knows nothing of phases: it reports a running count while it
    # scans, then a fraction while it indexes, and never says the scan is over.
    # The first indexing callback IS that signal, so the switch happens here
    # rather than in the crawler, which would otherwise have to carry a notion
    # of display it has no business knowing about.
    #
    # A nil reporter makes the whole thing inert, so the CLI can build it
    # unconditionally and let --json / --quiet decide by passing nil.
    class Indexing
      SCAN_LABEL  = "Scanning files"
      INDEX_LABEL = "Indexing files"

      def initialize(@progress : Progress?)
        @scanning = false
        @indexing = false
      end

      # Reports files found. Opens the scan phase on first use.
      def scan : Proc(Int32, Nil)?
        progress = @progress
        return nil unless progress

        ->(found : Int32) do
          unless @scanning
            @scanning = true
            progress.start(SCAN_LABEL)
          end
          progress.advance(found)
        end
      end

      # Reports files processed against the total to process. Its first call
      # closes the scan phase, since it is the only signal that scanning ended.
      def index : Proc(Int32, Int32, String, Nil)?
        progress = @progress
        return nil unless progress

        ->(processed : Int32, total : Int32, _path : String) do
          unless @indexing
            @indexing = true
            progress.done
            progress.start(INDEX_LABEL, total: total)
          end
          progress.advance(processed)
        end
      end

      # Closes whatever is still open. When every file was already up to date
      # the crawler never fires the indexing callback at all, and the run must
      # still read as finished rather than leave the scan phase hanging.
      def finish : Nil
        progress = @progress
        return unless progress

        unless @indexing
          @indexing = true
          progress.done
          progress.start(INDEX_LABEL, total: 0)
        end
        progress.done
      end
    end
  end
end
