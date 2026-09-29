{% if flag?(:linux) %}
  lib LibInotify
    fun inotify_init1(flags : Int32) : Int32
    fun inotify_add_watch(fd : Int32, pathname : UInt8*, mask : UInt32) : Int32
    fun inotify_rm_watch(fd : Int32, wd : Int32) : Int32
  end

  module MnemodocServer
    module Watch
      # Native Linux backend: one inotify watch per non-excluded directory.
      #
      # inotify watches a directory, not a tree, so every way a directory can
      # appear, vanish or move is a way to go blind, and each is handled here:
      # a directory created or moved in is watched and then scanned (the scan
      # comes after the watch, so a file written in between is seen by one or
      # the other); a directory deleted or moved out is reported as one deleted
      # event on its path, and its watches are dropped — a moved directory is
      # still watched by the kernel under its new location, with events that
      # would carry its old path; a configured root that is deleted or renamed
      # away reports itself, since nobody watches its parent.
      class Inotify < Backend
        IN_CLOSE_WRITE = 0x00000008_u32
        IN_MOVED_FROM  = 0x00000040_u32
        IN_MOVED_TO    = 0x00000080_u32
        IN_CREATE      = 0x00000100_u32
        IN_DELETE      = 0x00000200_u32
        IN_DELETE_SELF = 0x00000400_u32
        IN_MOVE_SELF   = 0x00000800_u32
        IN_Q_OVERFLOW  = 0x00004000_u32
        IN_IGNORED     = 0x00008000_u32
        IN_ISDIR       = 0x40000000_u32

        # Identical on every Linux architecture this project builds for
        # (asm-generic values, shared by x86_64 and arm64).
        IN_NONBLOCK =    0o4000
        IN_CLOEXEC  = 0o2000000

        MASK = IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO |
               IN_DELETE_SELF | IN_MOVE_SELF

        # Header of one `struct inotify_event`: wd, mask, cookie, len.
        HEADER_SIZE = 16

        # Room for many events per read; a single one needs at most
        # HEADER_SIZE + NAME_MAX + 1 bytes.
        BUFFER_SIZE = 64 * 1024

        @fd : Int32 = -1
        @io : IO::FileDescriptor? = nil
        @paths = {} of Int32 => String
        @wds = {} of String => Int32
        @roots : Set(String)

        def initialize(@filter : Filter)
          @roots = @filter.roots.to_set
        end

        # The directories currently watched, for inspection.
        def watched_directories : Array(String)
          @wds.keys
        end

        def run(stop : Channel(Nil), &block : Event ->) : Nil
          @fd = LibInotify.inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
          if @fd < 0
            raise Unavailable.new("inotify_init1 failed: #{Errno.value.message}")
          end
          io = @io = IO::FileDescriptor.new(@fd)
          # IO::FileDescriptor.new puts back in blocking mode any descriptor
          # that is not a pipe, socket or character device — an inotify one is
          # an anonymous inode — and a blocking read then parks the only thread:
          # nothing else runs, not even the timeouts. Non-blocking, the read
          # goes through the event loop like any socket.
          IO::FileDescriptor.set_blocking(@fd, false)
          begin
            watch_roots(report: nil, found: [] of Event)
            # Closing the descriptor is what wakes the read below.
            spawn do
              stop.receive?
              io.close rescue nil
            end
            read_events(io, &block)
          ensure
            io.close rescue nil
            @paths.clear
            @wds.clear
          end
        end

        private def read_events(io : IO::FileDescriptor, & : Event ->) : Nil
          buffer = Bytes.new(BUFFER_SIZE)
          found = [] of Event
          loop do
            count =
              begin
                io.read(buffer)
              rescue IO::Error
                return
              end
            return if count == 0
            offset = 0
            while offset + HEADER_SIZE <= count
              wd = IO::ByteFormat::SystemEndian.decode(Int32, buffer[offset, 4])
              mask = IO::ByteFormat::SystemEndian.decode(UInt32, buffer[offset + 4, 4])
              len = IO::ByteFormat::SystemEndian.decode(UInt32, buffer[offset + 12, 4]).to_i
              raw = buffer[offset + HEADER_SIZE, len]
              name = String.new(raw[0, raw.index(0_u8) || len])
              offset += HEADER_SIZE + len
              translate(wd, mask, name, found)
              found.each { |event| yield event }
              found.clear
            end
          end
        end

        # Appends to *found* the events one inotify record stands for. Public
        # so a spec can feed it the records the kernel cannot be made to send,
        # such as a queue overflow.
        def translate(wd : Int32, mask : UInt32, name : String, found : Array(Event)) : Nil
          if mask & IN_Q_OVERFLOW != 0
            # Events were dropped: every file may have changed. The crawler
            # skips an unchanged mtime, so re-reporting all of them is cheap.
            watch_roots(report: Event::Kind::Changed, found: found, rescan: true)
            return
          end
          dir = @paths[wd]?
          return unless dir

          if mask & IN_IGNORED != 0
            forget(wd)
            return
          end

          if mask & (IN_DELETE_SELF | IN_MOVE_SELF) != 0
            # A root has no watched parent to report it; any other directory
            # was already reported by its parent's DELETE or MOVED_FROM.
            emit(Event.new(dir, Event::Kind::Deleted), found) if @roots.includes?(dir)
            unwatch_tree(dir) if mask & IN_MOVE_SELF != 0
            return
          end

          path = File.join(dir, name)
          if mask & IN_ISDIR != 0
            if mask & (IN_CREATE | IN_MOVED_TO) != 0
              add_tree(path, report: Event::Kind::Added, found: found) if @filter.descend?(path)
            elsif mask & (IN_DELETE | IN_MOVED_FROM) != 0
              unwatch_tree(path)
              emit(Event.new(path, Event::Kind::Deleted), found)
            end
            return
          end

          kind =
            if mask & (IN_DELETE | IN_MOVED_FROM) != 0
              Event::Kind::Deleted
            elsif mask & (IN_CREATE | IN_MOVED_TO) != 0
              Event::Kind::Added
            else
              Event::Kind::Changed
            end
          emit(Event.new(path, kind), found)
        end

        # Watches every configured root; *report* re-announces the files found,
        # which only the overflow rescan wants.
        #
        # The parent of every root is watched too, its other entries rejected
        # by the filter: that is what sees a root created after start, or
        # deleted and recreated — `git checkout` of a branch without it, then
        # back — since a deleted directory takes its own watch with it. A root
        # that is a file is only ever seen through that parent.
        private def watch_roots(report : Event::Kind?, found : Array(Event), rescan : Bool = false) : Nil
          @roots.to_a.sort_by(&.size).each do |root|
            parent = File.dirname(root)
            add_watch(parent) if File.directory?(parent)
            info = File.info?(root)
            if info.nil? || !info.directory?
              emit(Event.new(root, report), found) if report && info
              next
            end
            add_tree(root, report: report, found: found, rescan: rescan)
          end
        end

        # Watches *dir*, then lists it: in that order, so a file created in
        # between is seen by the listing or by the watch. Descends into
        # subdirectories the filter allows, never through a symlink.
        #
        # A *rescan* also walks directories already watched under this very
        # path — after an overflow every one of them may hide a change — while
        # still skipping the same directory reached again through an alias.
        private def add_tree(dir : String, report : Event::Kind?, found : Array(Event), rescan : Bool = false) : Nil
          added = add_watch(dir)
          return unless added || (rescan && @wds.has_key?(dir))
          Watch.each_entry(dir) do |name, is_dir|
            path = File.join(dir, name)
            type = is_dir.nil? ? Watch.resolve_unknown(path) : (is_dir ? :dir : :file)
            case type
            when :dir
              add_tree(path, report: report, found: found, rescan: rescan) if @filter.descend?(path)
            when :file
              emit(Event.new(path, report), found) if report
            end
          end
        end

        # True when *dir* got a watch of its own. False when it could not be
        # watched, or when the kernel returned a descriptor already held — the
        # same directory reached again, through a nested root or a symlinked
        # one — so its tree is not walked twice and its events come once.
        private def add_watch(dir : String) : Bool
          return false if @wds.has_key?(dir)
          wd = LibInotify.inotify_add_watch(@fd, dir.check_no_null_byte, MASK)
          if wd < 0
            errno = Errno.value
            raise Unavailable.new("inotify_add_watch failed on #{dir}: #{errno.message}") if errno == Errno::ENOSPC
            return false
          end
          return false if @paths.has_key?(wd)
          @paths[wd] = dir
          @wds[dir] = wd
          true
        end

        # Drops the watches of *dir* and everything below it.
        private def unwatch_tree(dir : String) : Nil
          prefix = "#{dir}/"
          @wds.select { |path, _wd| path == dir || path.starts_with?(prefix) }.each do |path, wd|
            LibInotify.inotify_rm_watch(@fd, wd)
            @wds.delete(path)
            @paths.delete(wd)
          end
        end

        private def forget(wd : Int32) : Nil
          if path = @paths.delete(wd)
            @wds.delete(path)
          end
        end

        private def emit(event : Event, found : Array(Event)) : Nil
          found << event if @filter.accept?(event)
        end
      end
    end
  end
{% end %}
