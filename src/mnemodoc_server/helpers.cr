module MnemodocServer
  # Resolved at compile time from shard.yml and the current git HEAD so the
  # binary reports its exact provenance without runtime lookups.
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
  # `|| echo unknown` because the build is not always a git checkout: a source
  # tarball has no repository, git prints nothing, and the version string then
  # read "1.0.0 ()" in `status`, in `info`, and in every bug report quoting it.
  GIT_REF = {{ `git log -n 1 --format="%H" 2>/dev/null | head -c 8 || true`.chomp.stringify }}

  # Human-readable version string combining the shard version and git ref.
  def self.version : String
    ref = GIT_REF.empty? ? "unknown" : GIT_REF
    "#{VERSION} (#{ref})"
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
