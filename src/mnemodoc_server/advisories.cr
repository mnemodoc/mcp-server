module MnemodocServer
  # Collects persistent operational advisories raised at startup (e.g. a missing
  # config file) so they can be surfaced in every tool response, where the MCP
  # agent actually reads and relays them — unlike Log.warn, which only reaches
  # stderr/logs and is invisible in clients like Zed.
  module Advisories
    @@items = [] of String

    # Records an advisory, ignoring exact duplicates.
    def self.add(message : String) : Nil
      @@items << message unless @@items.includes?(message)
    end

    # The active advisories, as a copy.
    def self.all : Array(String)
      @@items.dup
    end

    # Drops all advisories (used between tests and on re-init).
    def self.clear : Nil
      @@items.clear
    end
  end

  # The active persistent advisories, surfaced in tool responses.
  def self.advisories : Array(String)
    Advisories.all
  end
end
