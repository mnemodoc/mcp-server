{% if flag?(:darwin) %}
  @[Link(framework: "CoreServices")]
  @[Link(ldflags: "#{__DIR__}/../../../vendor/fsevents_shim.o")]
  lib LibFSEvents
    # See vendor/fsevents_shim.c: the stream's callback runs no Crystal code,
    # it writes length-prefixed records into a pipe whose read end it returns.
    fun mnemo_fsevents_start(roots : UInt8**, count : Int32, latency : Float64, read_fd : Int32*) : Void*
    fun mnemo_fsevents_stop(watch : Void*) : Void
  end

  module MnemodocServer
    module Watch
      # Native macOS backend: one FSEvents stream over every configured root.
      #
      # The stream watches whole trees, so a new or moved directory needs no
      # watch of its own. What it gets wrong is naming: it reports resolved
      # paths (/tmp is /private/tmp, $TMPDIR is under /private/var), which are
      # mapped back to the spelling the index stores; and it flags a rename on
      # both sides without saying which, which only the file's presence tells.
      class FSEvents < Backend
        MUST_SCAN_SUB_DIRS = 0x00000001_u32
        USER_DROPPED       = 0x00000002_u32
        KERNEL_DROPPED     = 0x00000004_u32
        ROOT_CHANGED       = 0x00000020_u32
        ITEM_CREATED       = 0x00000100_u32
        ITEM_RENAMED       = 0x00000800_u32
        ITEM_IS_DIR        = 0x00020000_u32

        # Seconds FSEvents may hold events back to batch them.
        LATENCY = 0.2

        # Decoded records waiting for the consumer: the reader never waits on
        # indexing, so the pipe — and behind it the FSEvents queue — keeps
        # draining while a file is being embedded.
        BACKLOG = 4096

        # One configured root and the path FSEvents will report it under.
        private record Root, configured : String, resolved : String

        @roots : Array(Root)
        @restart = false

        def initialize(@filter : Filter)
          @roots = @filter.roots.map { |root| Root.new(root, resolve(root)) }
        end

        # The path FSEvents will report *path* under. A root that does not
        # exist yet cannot be resolved itself, so its nearest existing
        # ancestor is, and the rest is appended: without that, /var/folders/x
        # created later is reported as /private/var/folders/x and matches
        # nothing.
        private def resolve(path : String) : String
          existing = path
          suffix = ""
          until File.exists?(existing) || existing == "/"
            suffix = "/#{File.basename(existing)}#{suffix}"
            existing = File.dirname(existing)
          end
          (File.realpath(existing) rescue existing).chomp('/') + suffix
        end

        def run(stop : Channel(Nil), &block : Event ->) : Nil
          # A stream only covers the directories that existed when it was
          # created: a root that appears later is announced (RootChanged) and
          # then silent. Each appearance therefore restarts the stream.
          while run_stream(stop, &block)
          end
        end

        # Runs one stream until *stop* closes (returns false) or a root that
        # did not exist has appeared (returns true: start a new stream).
        private def run_stream(stop : Channel(Nil), &block : Event ->) : Bool
          return false if stop.closed?
          @restart = false
          watched = stream_paths
          pointers = watched.map(&.to_unsafe)
          read_fd = -1
          handle = LibFSEvents.mnemo_fsevents_start(pointers, pointers.size, LATENCY, pointerof(read_fd))
          raise Unavailable.new("the FSEvents stream did not start") if handle.null?

          io = IO::FileDescriptor.new(read_fd)
          records = Channel({UInt32, String}).new(BACKLOG)
          stopped = Atomic(Bool).new(false)
          stop_stream = -> do
            FSEvents.shutdown(handle, io) unless stopped.swap(true)
          end

          # Stopping the stream closes the pipe: the reader sees the end and
          # closes the channel, which ends the loop below.
          spawn do
            stop.receive?
            stop_stream.call
          end
          spawn { read_records(io, records) }

          found = [] of Event
          begin
            while record = records.receive?
              translate(record[0], record[1], found)
              found.each { |event| block.call(event) }
              found.clear
              if @restart
                stop_stream.call
                return true
              end
            end
            false
          ensure
            stop_stream.call
            io.close rescue nil
          end
        end

        # Stops the stream and releases the pipe. Public so a spec can drive it
        # against a pipe nobody reads.
        #
        # The read end is closed FIRST. The shim's stop waits, synchronously,
        # for any callback in flight — and a callback can be blocked writing
        # into a full pipe, which only this thread would drain. Closing the
        # read end makes that write fail with EPIPE (the runtime ignores
        # SIGPIPE), the callback returns, and the stop completes. The other
        # order froze the whole process, instance lock held.
        def self.shutdown(handle : Void*, io : IO::FileDescriptor) : Nil
          io.close rescue nil
          LibFSEvents.mnemo_fsevents_stop(handle)
        end

        # Appends to *found* the events one FSEvents record stands for. Public
        # so a spec can feed it the records the kernel cannot be made to send,
        # such as a dropped-events notice.
        def translate(flags : UInt32, raw_path : String, found : Array(Event)) : Nil
          path = configured_path(raw_path)
          unless path
            # A drop can be reported on a path above every root — `/`, when
            # the kernel lost track — and then concerns all of them.
            if flags & (USER_DROPPED | KERNEL_DROPPED) != 0
              @roots.each { |root| scan(root.configured, Event::Kind::Changed, found) }
            end
            return
          end

          if flags & (MUST_SCAN_SUB_DIRS | USER_DROPPED | KERNEL_DROPPED) != 0
            # Events under this path were lost: re-report everything below it.
            # The crawler skips an unchanged mtime, so this costs little.
            scan(path, Event::Kind::Changed, found)
            return
          end

          present = !File.info?(path, follow_symlinks: false).nil?
          if flags & ROOT_CHANGED != 0
            if present
              # A root that appeared: report what it holds, and have the
              # stream rebuilt so that it covers it from now on.
              scan(path, Event::Kind::Added, found)
              @restart = true
            else
              emit(Event.new(path, Event::Kind::Deleted), found)
            end
            return
          end

          if flags & ITEM_IS_DIR != 0
            if !present
              emit(Event.new(path, Event::Kind::Deleted), found)
            elsif flags & (ITEM_CREATED | ITEM_RENAMED) != 0
              # A directory moved in arrives as one event on the directory.
              scan(path, Event::Kind::Added, found)
            end
            return
          end

          kind =
            if !present
              Event::Kind::Deleted
            elsif flags & (ITEM_CREATED | ITEM_RENAMED) != 0
              Event::Kind::Added
            else
              Event::Kind::Changed
            end
          emit(Event.new(path, kind), found)
        end

        # The paths handed to the stream: each directory root, the parent of
        # each root that is a file, and each root that does not exist yet —
        # FSEvents streams are defined by path, so a root created later is
        # reported without restarting the stream.
        private def stream_paths : Array(String)
          @roots.map do |root|
            info = File.info?(root.configured)
            info.nil? || info.directory? ? root.configured : File.dirname(root.configured)
          end.uniq
        end

        # Maps a reported path back to the configured spelling, through the
        # longest root that contains it — so a file under two nested roots, or
        # under two roots on one directory, gets one path. On a tie the root
        # configured first wins.
        private def configured_path(raw : String) : String?
          best = nil
          best_size = -1
          @roots.each do |root|
            {root.resolved, root.configured}.each do |prefix|
              next unless raw == prefix || raw.starts_with?("#{prefix}/")
              if prefix.size > best_size
                best = root.configured + raw[prefix.size..]
                best_size = prefix.size
              end
            end
          end
          best
        end

        # Reports every accepted file below *dir* as *kind*, or *dir* itself
        # when it is a file.
        private def scan(dir : String, kind : Event::Kind, found : Array(Event)) : Nil
          info = File.info?(dir)
          return unless info
          unless info.directory?
            emit(Event.new(dir, kind), found)
            return
          end
          return unless @filter.descend?(dir)
          Watch.each_entry(dir) do |name, is_dir|
            path = File.join(dir, name)
            type = is_dir.nil? ? Watch.resolve_unknown(path) : (is_dir ? :dir : :file)
            case type
            when :dir  then scan(path, kind, found)
            when :file then emit(Event.new(path, kind), found)
            end
          end
        end

        # Decodes records until the write end closes, then closes *records*.
        private def read_records(io : IO::FileDescriptor, records : Channel({UInt32, String})) : Nil
          loop do
            flags = io.read_bytes(UInt32, IO::ByteFormat::SystemEndian)
            length = io.read_bytes(UInt32, IO::ByteFormat::SystemEndian)
            records.send({flags, io.read_string(length.to_i)})
          end
        rescue IO::EOFError | IO::Error
          # The stream stopped.
        ensure
          records.close
        end

        private def emit(event : Event, found : Array(Event)) : Nil
          found << event if @filter.accept?(event)
        end
      end
    end
  end
{% end %}
