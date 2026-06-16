module MnemodocServer
  # Resolved at compile time from shard.yml and the current git HEAD so the
  # binary reports its exact provenance without runtime lookups.
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
  GIT_REF = {{ `git log -n 1 --format="%H" | head -c 8`.chomp.stringify }}

  # Human-readable version string combining the shard version and git ref.
  def self.version : String
    "#{VERSION} (#{GIT_REF})"
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
