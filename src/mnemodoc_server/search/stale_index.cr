module MnemodocServer
  module Search
    # The one sentence both surfaces say when a keyword answer comes out of an
    # index built by another embedding model.
    #
    # It lives here rather than in either caller because it is the same
    # statement about the same index, and the two callers had already drifted:
    # `Tools::Query` carried it from the start, while `CLI::Search`
    # reimplements the search path instead of delegating and never grew it, so
    # `mnemodoc-server search --mode keyword` returned its table as though the
    # index were current — the exact silence the refusal in the vector modes was
    # introduced to end. Two hand-written near-copies would drift again; one
    # cannot.
    #
    # Deliberately not on Store::SQLite, which owns `model_mismatch?` but has no
    # business phrasing anything, and deliberately not shared with the *refusal*
    # raised in `hybrid`/`semantic` mode: that one names the gesture to perform,
    # and the gesture differs by surface (`--mode keyword` in a terminal,
    # `mode="keyword"` in a tool call).
    module StaleIndex
      # nil when the configured model is the one the index was built with, which
      # is what lets a caller write `if warning = StaleIndex.warning(...)`.
      def self.warning(store : Store::SQLite, config : Config) : String?
        return nil unless store.model_mismatch?(config.ollama.model)
        stored = store.embedding_model || "unknown"
        "index built with model '#{stored}'; current config uses '#{config.ollama.model}' — " \
        "this answer carries the keyword signal only; re-index to restore semantic search"
      end
    end
  end
end
