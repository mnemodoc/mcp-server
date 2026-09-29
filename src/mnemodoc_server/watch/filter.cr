module MnemodocServer
  module Watch
    # Decides which paths a watch backend reports and which directories it
    # descends into. It is the only gate between a backend and indexing:
    # `Indexer::Crawler.new([path])` treats every path it is handed as named
    # explicitly, so anything let through here would be indexed, as plain text
    # if no handler claims it.
    class Filter
      # Three names made of a private-use character no exclude pattern spells
      # out, so only a wildcard can match them: one short, one long, one nested.
      # A pattern matching all three matches every descendant of a directory,
      # whatever its name and depth. (A NUL would be the natural choice, but
      # File.match? refuses a string containing one.)
      PRUNE_PROBES = {"\u{E000}", "\u{E000}" * 8, "\u{E000}/\u{E000}"}

      getter roots : Array(String)
      @named : Set(String)
      @exclude : Array(String)
      @descend = {} of String => Bool

      def initialize(@config : Config, @registry : Indexer::Format::Registry)
        @roots = @config.resolved_paths.uniq
        # A root that is not a directory is a file named explicitly in `paths`,
        # whether or not it exists yet: the registry indexes it whatever its
        # extension.
        @named = @roots.reject { |root| File.directory?(root) }.to_set
        @exclude = @config.exclude
      end

      # True when the event should reach indexing. A deletion is filtered on
      # roots, exclusions and index artifacts only: a deleted directory has no
      # extension and can no longer be stat-ed, and a deleted path the index
      # never held costs one lookup.
      #
      # Cheapest test first: a poll pass asks this of every file in the tree,
      # most of which no handler claims, and the exclusion globs and the
      # artifact paths cost far more than an extension lookup.
      def accept?(event : Event) : Bool
        path = event.path
        return false unless under_root?(path)
        unless event.kind.deleted?
          return false unless @named.includes?(path) || @registry.supported?(File.extname(path))
        end
        return false if hidden?(path)
        return false if MnemodocServer.index_artifact?(path, @config)

        !excluded?(path)
      end

      # True when a backend should list or watch *dir*. False only when every
      # possible descendant is excluded; a narrower exclusion still descends and
      # leaves the per-file check to #accept?.
      #
      # Memoised: the answer depends on the path and the configuration alone,
      # and a poll pass asks it of every directory of the tree every second.
      def descend?(dir : String) : Bool
        @descend.put_if_absent(dir) do
          !hidden?(dir) && @exclude.none? do |pattern|
            PRUNE_PROBES.all? { |probe| File.match?(pattern, File.join(dir, probe)) }
          end
        end
      end

      # The longest configured root containing *path*, or nil. Longest, so a
      # file under two nested roots is attributed to one of them only.
      def root_for(path : String) : String?
        @roots.select { |root| within?(path, root) }.max_by?(&.size)
      end

      # True when a component below the root containing *path* starts with a
      # dot. The crawler globs without DotFiles, so such a file is never
      # indexed at boot — a watcher that let it through made the index flap
      # between the two. A configured root that is itself hidden (`.github/`)
      # is not affected: only what lies below it counts.
      private def hidden?(path : String) : Bool
        root = root_for(path)
        return false unless root

        path[root.size..].split('/').any?(&.starts_with?('.'))
      end

      private def under_root?(path : String) : Bool
        @roots.any? { |root| within?(path, root) }
      end

      # Component-wise: `docs` contains `docs/a.md` but not `docs-old/a.md`.
      private def within?(path : String, root : String) : Bool
        path == root || path.starts_with?(root.ends_with?('/') ? root : "#{root}/")
      end

      private def excluded?(path : String) : Bool
        @exclude.any? { |pattern| File.match?(pattern, path) }
      end
    end
  end
end
