module MnemodocServer
  module Search
    # Keyword search backed by SQLite FTS5. The query is tokenized in Crystal —
    # keeping the FR/EN stop-word filter and the whole-word rule — then turned
    # into an OR-joined FTS5 MATCH expression and ranked by BM25 in the store
    # (best chunk per file). Returns nothing when the query carries no content
    # terms, so the semantic signal drives natural-language queries alone.
    class Keyword
      # Common FR + EN function words that carry no retrieval signal.
      STOP_WORDS = Set{
        "le", "la", "les", "un", "une", "des", "de", "du", "dans", "et", "ou",
        "a", "au", "aux", "en", "pour", "par", "sur", "avec", "sans", "que",
        "qui", "quoi", "comment", "se", "ce", "ces", "son", "sa", "ses", "il",
        "elle", "on", "ne", "pas", "plus", "est", "sont", "the", "an", "and",
        "or", "of", "to", "in", "on", "for", "by", "with", "without", "is",
        "are", "be", "how", "what", "this", "that", "it", "as", "at", "from",
      }

      # Returns matched files ranked best-first (BM25), as 1-based file ranks.
      # An empty term list short-circuits without touching FTS5 (which would
      # raise on an empty MATCH expression).
      def search(query : String, store : Store::SQLite, limit : Int32) : Array({path: String, rank: Int32})
        terms = tokenize(query).uniq!
        empty = [] of {path: String, rank: Int32}
        return empty if terms.empty?

        match = terms.map { |term| %("#{term.gsub('"', "\"\"")}") }.join(" OR ")
        store.keyword_search(match, limit: limit).each_with_index.map do |result, index|
          {path: result[:path], rank: index + 1}
        end.to_a
      end

      # Lowercases, extracts unicode word tokens, drops short tokens and stop-words.
      private def tokenize(text : String) : Array(String)
        text.downcase.scan(/[\p{L}\p{N}]+/).map { |match_data| match_data[0] }.reject do |word|
          word.size < 2 || STOP_WORDS.includes?(word)
        end
      end
    end
  end
end
