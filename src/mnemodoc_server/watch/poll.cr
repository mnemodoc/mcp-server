module MnemodocServer
  module Watch
    # Polling fallback: walks the configured roots every *interval* and diffs
    # modification times.
    #
    # The walk it replaces globbed every tree and stat-ed every match, so a
    # project with 7 314 files, 561 of them indexable, paid for 7 314 stats a
    # second. This one reads the entry type the directory listing already
    # carries (`d_type`), prunes excluded directories before listing them, and
    # stats only the files the filter would let through.
    class Poll < Backend
      alias Stat = Proc(String, File::Info?)

      # *stat* is the one call made per candidate file, injectable so a spec
      # can prove which files are never touched.
      def initialize(@filter : Filter, @interval : Time::Span,
                     @stat : Stat = ->(path : String) { File.info?(path) })
      end

      def run(stop : Channel(Nil), &block : Event ->) : Nil
        known = scan
        loop do
          select
          when stop.receive?
            # Closed: the daemon is shutting down.
            return
          when timeout(@interval)
          end

          current = scan
          current.each do |path, mtime|
            previous = known[path]?
            if previous.nil?
              block.call(Event.new(path, Event::Kind::Added))
            elsif previous != mtime
              block.call(Event.new(path, Event::Kind::Changed))
            end
          end
          known.each_key do |path|
            block.call(Event.new(path, Event::Kind::Deleted)) unless current.has_key?(path)
          end
          known = current
        end
      end

      # Every accepted file under the roots, with its modification time.
      private def scan : Hash(String, Time)
        found = {} of String => Time
        visited = Set(String).new
        # Shortest first, so a nested root is already covered by its parent's
        # walk and is not listed a second time.
        @filter.roots.sort_by(&.size).each do |root|
          next if visited.includes?(root)
          info = File.info?(root)
          next unless info
          if info.directory?
            walk(root, found, visited)
          else
            consider(root, found)
          end
        end
        found
      end

      private def walk(dir : String, found : Hash(String, Time), visited : Set(String)) : Nil
        visited << dir
        Watch.each_entry(dir) do |name, is_dir|
          path = File.join(dir, name)
          type = is_dir.nil? ? Watch.resolve_unknown(path) : (is_dir ? :dir : :file)
          case type
          when :dir
            walk(path, found, visited) if @filter.descend?(path) && !visited.includes?(path)
          when :file
            consider(path, found)
          end
        end
      end

      private def consider(path : String, found : Hash(String, Time)) : Nil
        return unless @filter.accept?(Event.new(path, Event::Kind::Changed))
        info = @stat.call(path)
        found[path] = info.modification_time if info && info.file?
      end
    end
  end
end
