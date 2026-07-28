module MnemodocServer
  # Collects persistent operational advisories raised at startup (e.g. a missing
  # config file) so they can be surfaced in every tool response, where the MCP
  # agent actually reads and relays them — unlike Log.warn, which only reaches
  # stderr/logs and is invisible in clients like Zed.
  module Advisories
    @@items = [] of String
    # Written at startup but READ on every tool response, from whichever fiber
    # is serving it — up to 32 at once in the daemon. Cooperative scheduling
    # hides that today, since none of these operations yields; it stops hiding
    # it under -Dpreview_mt, where a concurrent read during a rehash corrupts
    # the array outright.
    @@mutex = Mutex.new

    # Records an advisory, ignoring exact duplicates.
    def self.add(message : String) : Nil
      @@mutex.synchronize do
        @@items << message unless @@items.includes?(message)
      end
    end

    # The active advisories, as a copy.
    def self.all : Array(String)
      @@mutex.synchronize { @@items.dup }
    end

    # Drops all advisories (used between tests and on re-init).
    def self.clear : Nil
      @@mutex.synchronize { @@items.clear }
    end
  end

  # The active persistent advisories, surfaced in tool responses.
  def self.advisories : Array(String)
    Advisories.all
  end
end
