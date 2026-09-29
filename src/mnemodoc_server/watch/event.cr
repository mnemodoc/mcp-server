module MnemodocServer
  module Watch
    # One change seen by a watch backend. A directory that disappears is
    # reported as a single deleted event on its own path: the backends cannot
    # always enumerate what it contained, so the consumer resolves it against
    # the index instead.
    record Event, path : String, kind : Kind do
      enum Kind
        Added
        Changed
        Deleted
      end
    end
  end
end
