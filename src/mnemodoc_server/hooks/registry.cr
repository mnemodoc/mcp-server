module MnemodocServer
  module Hooks
    # Raised when --client names a client with no adapter. This is a hook-wiring
    # mistake (not runtime data), so the CLI fails loudly rather than degrading.
    class UnknownClientError < Exception
      def initialize(client : String)
        super("unknown hook client #{client.inspect}; supported clients: claude-code")
      end
    end

    # Maps a client name (kebab-case) to its Adapter. Only claude-code ships
    # today; new clients add one entry here plus their adapter file.
    module Registry
      ADAPTERS = {
        "claude-code" => ClaudeCode.new.as(Adapter),
      }

      def self.for(client : String) : Adapter
        ADAPTERS[client]? || raise UnknownClientError.new(client)
      end
    end
  end
end
