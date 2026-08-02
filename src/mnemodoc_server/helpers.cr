module MnemodocServer
  # Resolved at compile time from shard.yml and the current git HEAD so the
  # binary reports its exact provenance without runtime lookups.
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
  # The program name, read from the same shard.yml the version comes from
  # rather than written down a second time: a literal here would be free to
  # drift from the shard, and nothing would catch it. shard.yml is already a
  # hard requirement of the build — `shards version` above reads it.
  NAME = {{ read_file("#{__DIR__}/../../shard.yml").lines.find(&.starts_with?("name:")).split(":")[1].strip }}
  # `|| true` because the build is not always a git checkout: a source
  # tarball has no repository, git prints nothing, and the version string then
  # read "1.0.0 ()" in `status`, in `info`, and in every bug report quoting it.
  #
  # Every git call below is anchored with `-C #{__DIR__}`, because a macro
  # backtick runs in the COMPILER's working directory, not in this file's. The
  # two coincide for a binary compiled from its own repository — but not for a
  # shard vendored under another project's lib/, where a bare `git log` reports
  # the provenance of the application doing the compiling. Measured: a probe
  # project compiled from this repository reported this repository's commit
  # instead of its own. Anchoring also degrades correctly, a vendored copy
  # having no .git for git to answer from.
  GIT_REF = {{ `git -C #{__DIR__} log -n 1 --format="%H" 2>/dev/null | head -c 8 || true`.chomp.stringify }}
  # Non-empty when the working tree carried uncommitted changes at compile
  # time. This is the one piece of provenance whose absence makes the version
  # *false* rather than merely incomplete: without it, a binary built from
  # patched sources reports the exact string the pristine release reports.
  GIT_DIRTY = {{ `git -C #{__DIR__} status --porcelain 2>/dev/null | head -c 1 || true`.chomp.stringify }}
  # The nearest tag and the distance to it ("v1.2.0", "v1.2.0-4-gd86b19d8"),
  # which is what catches a shard.yml version drifting from the tag actually
  # built. Empty outside a checkout, and in a repository with no tag at all.
  GIT_TAG = {{ `git -C #{__DIR__} describe --tags 2>/dev/null || true`.chomp.stringify }}
  # Compile timestamp, UTC and ISO 8601: answers "since when has this been
  # running" without a round-trip to the image registry.
  BUILT_AT = {{ `date -u +%Y-%m-%dT%H:%M:%SZ`.chomp.stringify }}
  # The platform this binary was compiled for, taken from the compiler's own
  # flags and NOT from `Crystal::DESCRIPTION`, whose "Default target" is the
  # compiler's own and would lie under cross-compilation. Static binaries ship
  # for amd64 and arm64, and this is what tells a wrongly pulled image from
  # the right one at a glance.
  TARGET = {{ flag?(:linux) ? "linux" : (flag?(:darwin) ? "darwin" : (flag?(:windows) ? "windows" : "unknown")) }} +
           "/" + {{ flag?(:x86_64) ? "amd64" : (flag?(:aarch64) ? "arm64" : "unknown") }}

  # The commit as it deserves to be quoted: the short ref, suffixed `-dirty`
  # when the tree was patched, and "unknown" when there was no repository to
  # ask.
  def self.commit : String
    return "unknown" if GIT_REF.empty?
    GIT_DIRTY.empty? ? GIT_REF : "#{GIT_REF}-dirty"
  end

  # The nearest git tag, or "unknown". Every field of the `info` build block is
  # always printed: a line that disappears reads as a rendering bug, where
  # "unknown" states plainly that the build could not know.
  def self.git_tag : String
    GIT_TAG.empty? ? "unknown" : GIT_TAG
  end

  # The provenance on its own — version, commit, platform, no program name.
  # This one feeds the MCP serverInfo, whose `name` is a separate field, and
  # the `status` tool's `version` key; folding the name in would duplicate it
  # in both.
  def self.version : String
    "#{VERSION} (#{commit}, #{TARGET})"
  end

  # The self-describing one-liner: `--version`, and the first line of `status`.
  # It is what a fleet inventory harvests one service per row, and the row's
  # left-hand column is gone the moment the line is copied into a bug report —
  # hence the name.
  def self.version_line : String
    "#{NAME} #{version}"
  end

  # Formats an elapsed duration into the largest fitting unit (ms/s/m).
  # A first crawl of a large repository runs for minutes while a re-index with
  # nothing to do returns in milliseconds, and one unit cannot state both
  # without printing either "0.4s" or "184000ms".
  def self.format_duration(span : Time::Span) : String
    case span
    when .>= 1.minute then "#{span.total_minutes.to_i}m#{(span.total_seconds.to_i % 60).to_s.rjust(2, '0')}s"
    when .>= 1.second then "#{span.total_seconds.round(1)}s"
    else                   "#{span.total_milliseconds.round.to_i}ms"
    end
  end

  # Formats a byte count into the largest fitting binary unit (B/KB/MB/GB).
  def self.format_bytes(n : Int64) : String
    case n
    when .>= 1_073_741_824 then "#{(n / 1_073_741_824.0).round(1)} GB"
    when .>= 1_048_576     then "#{(n / 1_048_576.0).round(1)} MB"
    when .>= 1_024         then "#{(n / 1_024.0).round(1)} KB"
    else                        "#{n} B"
    end
  end
end
