module MnemodocServer
  module Search
    # Decides what the prompt hook injects, if anything.
    #
    # Two gates, in order. **Similarity** answers "does this prompt concern the
    # corpus at all" — a cosine, comparable across queries, unlike the fused
    # score which is a rank artifact. **Margin** answers "do we trust the
    # ranking": when the runner-up sits within `margin_threshold` of the best
    # result, the ordering is not decisive, so the contenders go over together
    # rather than betting on first place.
    #
    # Measured on the benchmark corpus, after the store was fixed to return a
    # real cosine rather than 1/(1 + L2): always injecting one passage is right
    # 83.3 % of the time, always injecting three is right 94.4 % — and widening
    # only on a thin margin reaches that same 94.4 % for 45 % less context,
    # widening on 6 prompts out of 18. It works despite decisive and undecided
    # cases overlapping, because widening a case that was already right costs
    # tokens and never accuracy: the error is asymmetric.
    #
    # Both thresholds are calibrated on that cosine scale and do not transfer to
    # another metric unchanged.
    #
    # This lives on its own so the benchmark replays the shipped rule instead of
    # a copy of it.
    module HookSelection
      def self.choose(results : Array(SearchResult), similarity_threshold : Float64,
                      margin_threshold : Float64, max_passages : Int32) : Array(SearchResult)
        best = results.first?
        return [] of SearchResult if best.nil?

        best_similarity = best.similarity
        return [] of SearchResult if best_similarity.nil? || best_similarity < similarity_threshold

        runner_up = results[1]?.try(&.similarity) || 0.0
        return [best] if (best_similarity - runner_up) >= margin_threshold

        # Widening never smuggles in a passage that would have failed the gate
        # on its own.
        results.first(max_passages).select do |item|
          (item.similarity || -1.0) >= similarity_threshold
        end
      end
    end
  end
end
