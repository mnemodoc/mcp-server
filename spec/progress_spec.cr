require "./spec_helper"

Spectator.describe MnemodocServer::Progress do
  let(io) { IO::Memory.new }

  # A pipe, a CI job or a log file must never receive the in-place rewriting:
  # carriage returns and escape sequences turn a log into noise. The plain
  # rendering states each phase once and says nothing more.
  describe "without a terminal" do
    let(reporter) { MnemodocServer::Progress.new(io, tty: false) }

    it "emits one line per phase and no control sequences" do
      reporter.start("Scanning files")
      reporter.advance(12)
      reporter.done
      reporter.start("Indexing files", total: 4)
      reporter.advance(2)
      reporter.done

      output = io.to_s
      expect(output).not_to contain("\r")
      expect(output).not_to contain("\e[")
      expect(output.lines).to eq(["Scanning files...", "Indexing files..."])
    end
  end

  describe "with a terminal" do
    let(reporter) { MnemodocServer::Progress.new(io, tty: true) }

    # Every update overwrites the line it just wrote, so a long run occupies
    # one line rather than scrolling the terminal away.
    it "rewrites its line in place" do
      reporter.start("Indexing files", total: 10)
      reporter.advance(1)

      expect(io.to_s.lines(chomp: false).size).to eq(1)
      io.to_s.split("\r").reject(&.empty?).each do |update|
        expect(update).to start_with("\e[K")
      end
    end

    # The scan cannot know its denominator before it has finished scanning,
    # so it reports what it has found rather than a fraction of nothing.
    it "shows a growing count when the total is unknown" do
      reporter.start("Scanning files")
      reporter.advance(7)
      reporter.advance(31)

      output = io.to_s
      expect(output).to contain("Scanning files — 7 found")
      expect(output).to contain("Scanning files — 31 found")
      expect(output).not_to contain("%")
      expect(output).not_to contain(MnemodocServer::Progress::FILLED)
    end

    it "draws a fixed-width bar and a percentage when the total is known" do
      reporter.start("Indexing files", total: 200)
      reporter.advance(50)

      last = io.to_s.split("\r").last
      expect(last).to contain(" 25%")
      expect(last.count(MnemodocServer::Progress::FILLED)).to eq(MnemodocServer::Progress::BAR_WIDTH // 4)
      expect(last.count(MnemodocServer::Progress::FILLED) + last.count(MnemodocServer::Progress::EMPTY))
        .to eq(MnemodocServer::Progress::BAR_WIDTH)
    end

    it "reads 0% at the start and 100% at the total" do
      reporter.start("Indexing files", total: 8)
      expect(io.to_s.split("\r").last).to contain(" 0%")
      reporter.advance(8)
      expect(io.to_s.split("\r").last).to contain(" 100%")
    end

    # A finished phase keeps only what stays useful: the terminal is left
    # holding a list of completed steps, not a wall of full bars.
    it "drops the bar when the phase closes" do
      reporter.start("Indexing files", total: 8)
      reporter.advance(8)
      reporter.done

      last = io.to_s.split("\r").last
      expect(last).to contain("Indexing files — done")
      expect(last).not_to contain("%")
      expect(last).not_to contain(MnemodocServer::Progress::FILLED)
    end

    # Nothing to do is a legitimate outcome — every file already indexed — and
    # it must not divide by zero to say so.
    it "closes a zero-total phase immediately" do
      reporter.start("Indexing files", total: 0)

      expect(io.to_s).to contain("Indexing files — done")
      expect(io.to_s).not_to contain("%")
    end

    # done() is called from an ensure block on paths that may never have opened
    # a phase; it must stay a no-op there rather than raise over the real error.
    it "tolerates done without an open phase" do
      expect { reporter.done }.not_to raise_error
      expect(io.to_s).to be_empty
    end
  end
end

# The crawler reports two things and knows nothing of phases: a running count
# while it scans, then a fraction while it indexes. Nothing tells us the scan
# has ended — the first indexing callback is that signal, and this is where
# that is turned into two phases.
Spectator.describe MnemodocServer::Progress::Indexing do
  let(io) { IO::Memory.new }
  let(reporter) { MnemodocServer::Progress.new(io, tty: false) }
  let(phases) { MnemodocServer::Progress::Indexing.new(reporter) }

  it "opens the scan phase and feeds it the running count" do
    phases.scan.try &.call(3)
    expect(io.to_s).to contain("Scanning files...")
  end

  it "closes the scan and opens the indexing phase on the first file" do
    phases.scan.try &.call(1)
    phases.index.try &.call(1, 4, "a.md")

    expect(io.to_s.lines).to eq(["Scanning files...", "Indexing files..."])
  end

  # Every file already up to date: the crawler never fires the indexing
  # callback, and the run must still read as finished rather than leave the
  # scan phase hanging open.
  it "declares indexing done when there was nothing to index" do
    phases.scan.try &.call(2)
    phases.finish

    expect(io.to_s.lines).to eq(["Scanning files...", "Indexing files..."])
  end

  it "is entirely inert without a reporter" do
    inert = MnemodocServer::Progress::Indexing.new(nil)

    expect(inert.scan).to be_nil
    expect(inert.index).to be_nil
    expect { inert.finish }.not_to raise_error
  end

  context "on a terminal" do
    let(reporter) { MnemodocServer::Progress.new(io, tty: true) }

    it "carries the crawler's total into the bar" do
      phases.index.try &.call(2, 8, "a.md")
      expect(io.to_s.split("\r").last).to contain(" 25%")
    end

    it "closes the indexing phase on finish" do
      phases.index.try &.call(8, 8, "a.md")
      phases.finish
      expect(io.to_s).to contain("Indexing files — done")
    end
  end
end
