require "../spec_helper"
require "file_utils"

# The poll backend is the fallback when no native one is available, and the
# default is to pay for it on every tick. Its cost came from stat-ing every
# entry of every configured tree, excluded or not, indexable or not; these
# examples pin what it must no longer touch as well as what it must report.
Spectator.describe MnemodocServer::Watch::Poll do
  let(tmp_dir) { "/tmp/mnemodoc-poll-#{Random::Secure.hex(4)}" }
  let(docs) { File.join(tmp_dir, "docs") }
  let(outside) { File.join(tmp_dir, "outside") }
  let(interval) { 200.milliseconds }

  before_each do
    Dir.mkdir_p(File.join(docs, "drafts"))
    Dir.mkdir_p(File.join(docs, "sub"))
    Dir.mkdir_p(outside)
  end
  after_each { FileUtils.rm_rf(tmp_dir) }

  private def config(paths : Array(String))
    MnemodocServer::Config.from_yaml(<<-YAML)
    paths:
    #{paths.map { |path| "  - #{path}" }.join('\n')}
    exclude:
      - "**/drafts/**"
    db:
      path: #{File.join(tmp_dir, "index.db")}
    YAML
  end

  private def filter(paths = [docs])
    cfg = config(paths)
    MnemodocServer::Watch::Filter.new(cfg, MnemodocServer::Indexer::Format::Registry.new(cfg))
  end

  # Runs the backend in a fiber, collecting its events. Returns the event
  # channel, the stop channel and a channel that fires when run returns.
  private def start(poll : MnemodocServer::Watch::Poll)
    events = Channel(MnemodocServer::Watch::Event).new(64)
    stop = Channel(Nil).new
    done = Channel(Nil).new(1)
    spawn do
      poll.run(stop) { |event| events.send(event) }
    ensure
      done.send(nil)
    end
    # Two ticks: the first pass is the baseline and reports nothing.
    sleep interval * 2
    {events, stop, done}
  end

  # Drains every event that arrives within *span*.
  private def collect(events : Channel(MnemodocServer::Watch::Event), span = 1.second)
    seen = [] of MnemodocServer::Watch::Event
    deadline = Time.instant + span
    loop do
      remaining = deadline - Time.instant
      break if remaining <= Time::Span.zero
      select
      when event = events.receive
        seen << event
      when timeout(remaining)
        break
      end
    end
    seen
  end

  private def kinds(seen, path)
    seen.select { |event| event.path == path }.map(&.kind)
  end

  it "reports a file added, changed and deleted" do
    poll = MnemodocServer::Watch::Poll.new(filter, interval)
    events, stop, _done = start(poll)
    path = File.join(docs, "guide.md")
    begin
      File.write(path, "# One")
      expect(kinds(collect(events), path)).to eq([MnemodocServer::Watch::Event::Kind::Added])

      File.write(path, "# Two")
      File.touch(path, Time.utc + 5.seconds)
      expect(kinds(collect(events), path)).to eq([MnemodocServer::Watch::Event::Kind::Changed])

      File.delete(path)
      expect(kinds(collect(events), path)).to eq([MnemodocServer::Watch::Event::Kind::Deleted])
    ensure
      stop.close
    end
  end

  it "never stats a file under an excluded directory or with a non-indexable extension" do
    File.write(File.join(docs, "drafts", "wip.md"), "# Draft")
    File.write(File.join(docs, "diagram.png"), "png")
    File.write(File.join(docs, "guide.md"), "# Guide")
    statted = [] of String
    stat = ->(path : String) { statted << path; File.info?(path) }

    poll = MnemodocServer::Watch::Poll.new(filter, interval, stat: stat)
    _events, stop, _done = start(poll)
    stop.close

    expect(statted).to contain(File.join(docs, "guide.md"))
    expect(statted.none?(&.includes?("/drafts/"))).to be_true
    expect(statted).not_to contain(File.join(docs, "diagram.png"))
  end

  it "does not descend into a symlinked directory" do
    File.write(File.join(outside, "far.md"), "# Far")
    File.symlink(outside, File.join(docs, "link"))
    poll = MnemodocServer::Watch::Poll.new(filter, interval)
    events, stop, _done = start(poll)
    begin
      File.write(File.join(outside, "far.md"), "# Changed")
      File.touch(File.join(outside, "far.md"), Time.utc + 5.seconds)
      File.write(File.join(outside, "new.md"), "# New")

      expect(collect(events).map(&.path).none?(&.includes?("/link/"))).to be_true
    ensure
      stop.close
    end
  end

  it "reports a file under two nested roots once" do
    poll = MnemodocServer::Watch::Poll.new(filter([docs, File.join(docs, "sub")]), interval)
    events, stop, _done = start(poll)
    path = File.join(docs, "sub", "nested.md")
    begin
      File.write(path, "# Nested")
      expect(kinds(collect(events), path)).to eq([MnemodocServer::Watch::Event::Kind::Added])
    ensure
      stop.close
    end
  end

  it "returns within one interval of the stop signal, with no file event" do
    slow = 1.second
    poll = MnemodocServer::Watch::Poll.new(filter, slow)
    stop = Channel(Nil).new
    done = Channel(Nil).new(1)
    spawn do
      poll.run(stop) { |_event| }
    ensure
      done.send(nil)
    end
    sleep 100.milliseconds
    stop.close

    returned = select
    when done.receive
      true
    when timeout(slow + 500.milliseconds)
      false
    end
    expect(returned).to be_true
  end
end
