require "../spec_helper"
require "file_utils"

{% if flag?(:darwin) %}
  # FSEvents watches whole trees, so the directory cases that make inotify go
  # blind cost it nothing; what it gets wrong instead is naming. It reports
  # resolved paths — /tmp is /private/tmp, $TMPDIR lives under /private/var —
  # and those must come back in the spelling the index stores. It also flags a
  # rename without saying which side a path was on.
  Spectator.describe MnemodocServer::Watch::FSEvents do
    # Under $TMPDIR, i.e. /var/folders/…, which FSEvents reports as
    # /private/var/folders/…: every example exercises the spelling mapping.
    let(tmp_dir) { File.join(Dir.tempdir, "mnemodoc-fsevents-#{Random::Secure.hex(4)}") }
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

    private def start(backend : MnemodocServer::Watch::FSEvents)
      events = Channel(MnemodocServer::Watch::Event).new(256)
      stop = Channel(Nil).new
      done = Channel(Nil).new(1)
      spawn do
        backend.run(stop) { |event| events.send(event) }
      ensure
        done.send(nil)
      end
      # The stream only reports what happens after it started.
      sleep 500.milliseconds
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

    private def deleted?(seen, path)
      kinds(seen, path).last? == MnemodocServer::Watch::Event::Kind::Deleted
    end

    private def reported_once?(seen, suffix)
      matching = seen.select(&.path.ends_with?(suffix))
      !matching.empty? && matching.map(&.path).uniq.size == 1 && matching.map(&.kind).tally.values.all?(1)
    end

    it "reports under the configured spelling, never the resolved one" do
      backend = MnemodocServer::Watch::FSEvents.new(filter)
      events, stop, _done = start(backend)
      path = File.join(docs, "guide.md")
      begin
        File.write(path, "# One")
        seen = collect(events)
        expect(present?(seen, path)).to be_true
        expect(seen.none?(&.path.starts_with?("/private/"))).to be_true
      ensure
        stop.close
      end
    end

    it "reports create, modify, delete, rename and atomic save within 2 s" do
      backend = MnemodocServer::Watch::FSEvents.new(filter)
      events, stop, _done = start(backend)
      path = File.join(docs, "guide.md")
      begin
        File.write(path, "# One")
        expect(present?(collect(events), path)).to be_true

        File.write(path, "# Two")
        expect(present?(collect(events), path)).to be_true

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

    it "reports files in a directory created after start, even written at once" do
      backend = MnemodocServer::Watch::FSEvents.new(filter)
      events, stop, _done = start(backend)
      begin
        immediate = File.join(docs, "fresh", "first.md")
        Dir.mkdir_p(File.dirname(immediate))
        File.write(immediate, "# First")
        expect(present?(collect(events), immediate)).to be_true
      ensure
        stop.close
      end
    end

    it "reports the files of a directory moved in, and later writes in it" do
      Dir.mkdir_p(File.join(outside, "incoming"))
      File.write(File.join(outside, "incoming", "carried.md"), "# Carried")
      backend = MnemodocServer::Watch::FSEvents.new(filter)
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
      backend = MnemodocServer::Watch::FSEvents.new(filter)
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
      backend = MnemodocServer::Watch::FSEvents.new(filter([docs, other, third]))
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
      backend = MnemodocServer::Watch::FSEvents.new(filter([docs, File.join(docs, "sub"), alias_root]))
      events, stop, _done = start(backend)
      begin
        File.write(File.join(docs, "sub", "nested.md"), "# Nested")
        expect(reported_once?(collect(events), "/sub/nested.md")).to be_true

        File.write(File.join(docs, "shared.md"), "# Shared")
        expect(reported_once?(collect(events), "/shared.md")).to be_true
      ensure
        stop.close
      end
    end

    it "reports nothing under an excluded directory" do
      backend = MnemodocServer::Watch::FSEvents.new(filter)
      events, stop, _done = start(backend)
      begin
        File.write(File.join(docs, "drafts", "wip.md"), "# Draft")
        expect(collect(events).none?(&.path.includes?("/drafts/"))).to be_true
      ensure
        stop.close
      end
    end

    it "reports a file name containing a newline and a tab intact" do
      backend = MnemodocServer::Watch::FSEvents.new(filter)
      events, stop, _done = start(backend)
      path = File.join(docs, "odd\nname\twith.md")
      begin
        File.write(path, "# Odd")
        expect(present?(collect(events), path)).to be_true
      ensure
        stop.close
      end
    end

    it "rescans the subtree when the stream says events were dropped" do
      File.write(File.join(docs, "sub", "kept.md"), "# Kept")
      backend = MnemodocServer::Watch::FSEvents.new(filter)
      found = [] of MnemodocServer::Watch::Event
      backend.translate(MnemodocServer::Watch::FSEvents::MUST_SCAN_SUB_DIRS, File.realpath(File.join(docs, "sub")), found)
      expect(found.map(&.path)).to contain(File.join(docs, "sub", "kept.md"))
    end

    # Nobody drains the pipe here, so a burst fills it and the stream's
    # callback blocks in write(). Stopping used to wait for that callback from
    # the only thread — the one that would have drained the pipe — and the
    # process froze for good, instance lock held. Driven through the shim
    # directly: a natural burst only fills the pipe when the reader happens to
    # fall behind, which no spec can arrange reliably.
    it "stops a stream whose callback is blocked on a full pipe" do
      root = File.realpath(docs)
      read_fd = -1
      paths = [root.to_unsafe]
      handle = LibFSEvents.mnemo_fsevents_start(paths, 1, 0.05, pointerof(read_fd))
      expect(handle.null?).to be_false
      io = IO::FileDescriptor.new(read_fd)
      2_000.times { |index| File.write(File.join(docs, "fill-#{index}.md"), "x") }
      sleep 1.second

      done = Channel(Nil).new(1)
      spawn do
        MnemodocServer::Watch::FSEvents.shutdown(handle, io)
        done.send(nil)
      end
      returned = select
      when done.receive
        true
      when timeout(2.seconds)
        false
      end
      expect(returned).to be_true
    end

    # `git checkout` of a branch without the directory, then back: the poller
    # it replaces recovered by itself on its next pass, so must this.
    it "watches a configured root created after start" do
      late = File.join(tmp_dir, "late")
      backend = MnemodocServer::Watch::FSEvents.new(filter([docs, late]))
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
      backend = MnemodocServer::Watch::FSEvents.new(filter([docs, other]))
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

    # Crystal starts a child with fork and exec and closes nothing: a pipe
    # end without FD_CLOEXEC went to every pdftotext the daemon ran.
    it "rescans every root when events were dropped outside of them" do
      File.write(File.join(docs, "sub", "kept.md"), "# Kept")
      backend = MnemodocServer::Watch::FSEvents.new(filter)
      found = [] of MnemodocServer::Watch::Event
      backend.translate(MnemodocServer::Watch::FSEvents::KERNEL_DROPPED, "/", found)
      expect(found.map(&.path)).to contain(File.join(docs, "sub", "kept.md"))
    end

    it "does not hand its pipe to a child process" do
      read_fd = -1
      paths = [File.realpath(docs).to_unsafe]
      handle = LibFSEvents.mnemo_fsevents_start(paths, 1, 0.05, pointerof(read_fd))
      io = IO::FileDescriptor.new(read_fd)
      begin
        listing = IO::Memory.new
        Process.run("/bin/sh", ["-c", "ls /dev/fd"], output: listing)
        expect(listing.to_s.split).not_to contain(read_fd.to_s)
      ensure
        MnemodocServer::Watch::FSEvents.shutdown(handle, io)
      end
    end

    it "returns within 1 s of the stop signal, with no file event" do
      backend = MnemodocServer::Watch::FSEvents.new(filter)
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
