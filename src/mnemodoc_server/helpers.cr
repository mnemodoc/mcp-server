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
