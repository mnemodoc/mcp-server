require "../spec_helper"
require "file_utils"

{% if flag?(:linux) %}
  # The inotify backend watches one directory per descriptor, so every case
  # where a directory appears, vanishes or moves is a case where it can go
  # blind: those are the ones spelled out here, beside the ordinary file events.
  Spectator.describe MnemodocServer::Watch::Inotify do
    let(tmp_dir) { "/tmp/mnemodoc-inotify-#{Random::Secure.hex(4)}" }
    let(docs) { File.join(tmp_dir, "docs") }
    let(outside) { File.join(tmp_dir, "outside") }

    before_each do
      Dir.mkdir_p(File.join(docs, "drafts"))
      Dir.mkdir_p(File.join(docs, "sub"))
      Dir.mkdir_p(outside)
    end
    after_each { FileUtils.rm_rf(tmp_dir) }

    private def filter(paths = [docs])
      cfg = MnemodocServer::Config.from_yaml(<<-YAML)
      paths:
      #{paths.map { |path| "  - #{path}" }.join('\n')}
      exclude:
        - "**/drafts/**"
      db:
        path: #{File.join(tmp_dir, "index.db")}
      YAML
      MnemodocServer::Watch::Filter.new(cfg, MnemodocServer::Indexer::Format::Registry.new(cfg))
    end

    private def start(backend : MnemodocServer::Watch::Inotify)
      events = Channel(MnemodocServer::Watch::Event).new(256)
      stop = Channel(Nil).new
      done = Channel(Nil).new(1)
      spawn do
        backend.run(stop) { |event| events.send(event) }
      ensure
        done.send(nil)
      end
      sleep 200.milliseconds
      {events, stop, done}
    end

    private def collect(events, span = 2.seconds)
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

    private def present?(seen, path)
      found = kinds(seen, path)
      !found.empty? && !found.last.deleted?
    end

    # One path only, and no event repeated on it. A new file legitimately
    # yields two events (created, then closed after writing); what a doubled
    # watch would add is a second path, or the same event twice.
    private def reported_once?(seen, suffix)
      matching = seen.select(&.path.ends_with?(suffix))
      !matching.empty? && matching.map(&.path).uniq.size == 1 && matching.map(&.kind).tally.values.all?(1)
    end

    private def deleted?(seen, path)
      kinds(seen, path).last? == MnemodocServer::Watch::Event::Kind::Deleted
    end

    it "reports create, modify, delete, rename and atomic save within 2 s" do
      backend = MnemodocServer::Watch::Inotify.new(filter)
      events, stop, _done = start(backend)
      path = File.join(docs, "guide.md")
      begin
        File.write(path, "# One")
        expect(present?(collect(events), path)).to be_true

        File.write(path, "# Two")
        expect(kinds(collect(events), path)).to contain(MnemodocServer::Watch::Event::Kind::Changed)

        renamed = File.join(docs, "renamed.md")
        File.rename(path, renamed)
        seen = collect(events)
        expect(deleted?(seen, path)).to be_true
        expect(present?(seen, renamed)).to be_true

        File.delete(renamed)
        expect(deleted?(collect(events), renamed)).to be_true

        saved = File.join(docs, "saved.md")
        temp = File.join(docs, ".saved.md.tmp")
        File.write(temp, "# Saved")
        File.rename(temp, saved)
        expect(present?(collect(events), saved)).to be_true
      ensure
        stop.close
      end
    end

    it "watches a directory created after start, even for a file written at once" do
      backend = MnemodocServer::Watch::Inotify.new(filter)
      events, stop, _done = start(backend)
      begin
        immediate = File.join(docs, "fresh", "first.md")
        Dir.mkdir_p(File.dirname(immediate))
        File.write(immediate, "# First")
        expect(present?(collect(events), immediate)).to be_true

        later = File.join(docs, "fresh", "later.md")
        File.write(later, "# Later")
        expect(present?(collect(events), later)).to be_true
      ensure
        stop.close
      end
    end

    it "reports the files of a directory moved in, and watches it" do
      Dir.mkdir_p(File.join(outside, "incoming"))
      File.write(File.join(outside, "incoming", "carried.md"), "# Carried")
      backend = MnemodocServer::Watch::Inotify.new(filter)
      events, stop, _done = start(backend)
      begin
        File.rename(File.join(outside, "incoming"), File.join(docs, "incoming"))
        expect(present?(collect(events), File.join(docs, "incoming", "carried.md"))).to be_true

        added = File.join(docs, "incoming", "added.md")
        File.write(added, "# Added")
        expect(present?(collect(events), added)).to be_true
      ensure
        stop.close
      end
    end

    it "reports a directory moved out as one deletion on its path" do
      Dir.mkdir_p(File.join(docs, "leaving"))
      File.write(File.join(docs, "leaving", "gone.md"), "# Gone")
      backend = MnemodocServer::Watch::Inotify.new(filter)
      events, stop, _done = start(backend)
      begin
        File.rename(File.join(docs, "leaving"), File.join(outside, "leaving"))
        expect(deleted?(collect(events), File.join(docs, "leaving"))).to be_true
      ensure
        stop.close
      end
    end

    it "reports a configured root renamed away or deleted as a deletion on the root" do
      other = File.join(tmp_dir, "other")
      third = File.join(tmp_dir, "third")
      Dir.mkdir_p(other)
      Dir.mkdir_p(third)
      backend = MnemodocServer::Watch::Inotify.new(filter([docs, other, third]))
      events, stop, _done = start(backend)
      begin
        File.rename(other, File.join(outside, "other"))
        expect(deleted?(collect(events), other)).to be_true

        FileUtils.rm_rf(third)
        expect(deleted?(collect(events), third)).to be_true
      ensure
        stop.close
      end
    end

    it "reports a file under two nested roots, or two roots on one directory, once" do
      alias_root = File.join(tmp_dir, "alias")
      File.symlink(docs, alias_root)
      backend = MnemodocServer::Watch::Inotify.new(filter([docs, File.join(docs, "sub"), alias_root]))
      events, stop, _done = start(backend)
      begin
        nested = File.join(docs, "sub", "nested.md")
        File.write(nested, "# Nested")
        expect(reported_once?(collect(events), "/sub/nested.md")).to be_true

        shared = File.join(docs, "shared.md")
        File.write(shared, "# Shared")
        expect(reported_once?(collect(events), "/shared.md")).to be_true
      ensure
        stop.close
      end
    end

    it "puts no watch on an excluded directory" do
      backend = MnemodocServer::Watch::Inotify.new(filter)
      _events, stop, _done = start(backend)
      begin
        expect(backend.watched_directories).to contain(File.join(docs, "sub"))
        expect(backend.watched_directories).not_to contain(File.join(docs, "drafts"))
      ensure
        stop.close
      end
    end

    # An overflow means events were dropped: every file may have changed, and
    # a directory created meanwhile has no watch yet. The rescan used to go
    # through the "add a watch" path, which returns at once for a directory
    # already watched — so it reported nothing and watched nothing new.
    it "re-reports every file and watches missed directories on a queue overflow" do
      File.write(File.join(docs, "kept.md"), "# Kept")
      backend = MnemodocServer::Watch::Inotify.new(filter)
      _events, stop, _done = start(backend)
      begin
        found = [] of MnemodocServer::Watch::Event
        backend.translate(-1, MnemodocServer::Watch::Inotify::IN_Q_OVERFLOW, "", found)
        expect(found.map(&.path)).to contain(File.join(docs, "kept.md"))
      ensure
        stop.close
      end
    end

    # `git checkout` of a branch without the directory, then back: the poller
    # it replaces recovered by itself on its next pass, so must this.
    it "watches a configured root created after start" do
      late = File.join(tmp_dir, "late")
      backend = MnemodocServer::Watch::Inotify.new(filter([docs, late]))
      events, stop, _done = start(backend)
      begin
        Dir.mkdir_p(late)
        sleep 300.milliseconds
        path = File.join(late, "arrived.md")
        File.write(path, "# Arrived")
        expect(present?(collect(events), path)).to be_true
      ensure
        stop.close
      end
    end

    it "watches a configured root again once it is deleted and recreated" do
      other = File.join(tmp_dir, "other")
      Dir.mkdir_p(other)
      backend = MnemodocServer::Watch::Inotify.new(filter([docs, other]))
      events, stop, _done = start(backend)
      begin
        FileUtils.rm_rf(other)
        collect(events, 1.second)
        Dir.mkdir_p(other)
        sleep 300.milliseconds
        path = File.join(other, "back.md")
        File.write(path, "# Back")
        expect(present?(collect(events), path)).to be_true
      ensure
        stop.close
      end
    end

    it "returns within 1 s of the stop signal, with no file event" do
      backend = MnemodocServer::Watch::Inotify.new(filter)
      _events, stop, done = start(backend)
      stop.close
      returned = select
      when done.receive
        true
      when timeout(1.second)
        false
      end
      expect(returned).to be_true
    end
  end
{% end %}
