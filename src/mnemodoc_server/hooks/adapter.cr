module MnemodocServer
  module Hooks
    # A per-client strategy that maps one AI client's raw hook JSON onto the
    # normalised HookInput. Adapters never read stdin or touch the CLI; they
    # assume an already-parsed JSON::Any and MUST NOT raise on missing or extra
    # keys (map absent keys to nil/empty instead).
    abstract class Adapter
      abstract def parse(json : JSON::Any) : HookInput
    end
  end
end
