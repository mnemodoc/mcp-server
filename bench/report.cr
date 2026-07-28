require "json"

module Bench
  # One question's result: what it cost to answer, and whether the passage that
  # actually holds the answer came back.
  struct QuestionOutcome
    include JSON::Serializable

    getter question : String
    getter retrieved_cost : Int32
    getter? hit : Bool
    # Best cosine seen for this prompt, and whether it cleared the threshold.
    getter similarity : Float64?
    getter? fired : Bool
    getter? expect_fire : Bool
    # What the hook would actually have injected — the shipped rule's outcome,
    # which is not the same as the top-k the cost figures above describe.
    getter injected_count : Int32
    getter injected_cost : Int32
    getter? injected_hit : Bool
    getter expected_file : String
    getter expected_heading : String
    # The (file, heading) pairs the search returned, for diagnosing a miss.
    getter returned : Array(String)

    def initialize(@question, @retrieved_cost, @hit, @expected_file, @expected_heading, @returned,
                   @similarity = nil, @fired = false, @expect_fire = true,
                   @injected_count = 0, @injected_cost = 0, @injected_hit = false)
    end
  end

  # Aggregates the run and renders it.
  #
  # The rule this class exists to enforce: a saving is never published without
  # its recall. Returning nothing is a 100 % saving and a total failure, so a
  # run with no relevant results is reported as **not meaningful** rather than
  # as a spectacular one.
  class Report
    include JSON::Serializable

    getter mode : String
    getter baseline_cost : Int32
    getter top_k : Int32
    getter threshold : Float64
    @[JSON::Field(key: "questions")]
    getter outcomes : Array(QuestionOutcome)

    getter? exact : Bool

    def initialize(@mode, @baseline_cost, @top_k, @outcomes, @threshold = 0.0, @exact = false)
    end

    # Questions the hook was meant to fire on: recall and cost are computed on
    # these alone, since off-topic entries have no expected passage.
    def answerable : Array(QuestionOutcome)
      @outcomes.select(&.expect_fire?)
    end

    # Share of on-topic prompts the hook would have injected on.
    def firing_rate : Float64
      wanted = answerable
      return 0.0 if wanted.empty?
      wanted.count(&.fired?) / wanted.size.to_f
    end

    # Of the on-topic prompts the hook fires on, how often the passage holding
    # the answer is among those injected. This is the figure a user actually
    # experiences — not the top-k recall above, which describes a wider window.
    def hook_accuracy : Float64
      fired = answerable.select(&.fired?)
      return 0.0 if fired.empty?
      fired.count(&.injected_hit?) / fired.size.to_f
    end

    def mean_injected_cost : Float64
      fired = answerable.select(&.fired?)
      return 0.0 if fired.empty?
      fired.sum(&.injected_cost) / fired.size.to_f
    end

    def mean_injected_count : Float64
      fired = answerable.select(&.fired?)
      return 0.0 if fired.empty?
      fired.sum(&.injected_count) / fired.size.to_f
    end

    # Share of off-topic prompts the hook would have wrongly injected on — the
    # half of the calibration that a threshold tuned only on real questions
    # never sees.
    def false_fire_rate : Float64
      unwanted = @outcomes.reject(&.expect_fire?)
      return 0.0 if unwanted.empty?
      unwanted.count(&.fired?) / unwanted.size.to_f
    end

    def recall : Float64
      wanted = answerable
      return 0.0 if wanted.empty?
      wanted.count(&.hit?) / wanted.size.to_f
    end

    def mean_retrieved : Float64
      wanted = answerable
      return 0.0 if wanted.empty?
      wanted.sum(&.retrieved_cost) / wanted.size.to_f
    end

    def median_retrieved : Float64
      return 0.0 if answerable.empty?
      sorted = answerable.map(&.retrieved_cost).sort!
      middle = sorted.size // 2
      sorted.size.odd? ? sorted[middle].to_f : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    # Share of the baseline avoided. Guards a zero baseline rather than
    # dividing by it — an empty corpus is a setup error, not an infinite saving.
    def saving_ratio : Float64
      return 0.0 if @baseline_cost <= 0
      1.0 - (mean_retrieved / @baseline_cost)
    end

    # A saving only means something if the answers came back with it.
    # A run is worth reading when it retrieved something relevant AND did not
    # simply fire on everything. Recall alone was not enough: a threshold of
    # zero injects on every off-topic prompt too, and that run came out
    # "meaningful" with a fine recall and a saving to match.
    MAX_FALSE_FIRE_RATE = 0.5

    def meaningful? : Bool
      recall > 0.0 && mean_retrieved > 0 && false_fire_rate <= MAX_FALSE_FIRE_RATE
    end

    def to_s(io : IO) : Nil
      io << "Unit          : " << @mode << '\n'
      io << "Baseline      : " << @baseline_cost << " (whole corpus, loaded every session)\n"
      io << "Retrieved     : mean " << mean_retrieved.round(1) << ", median " << median_retrieved.round(1)
      io << " (top-" << @top_k << ")\n"
      io << "Saving        : " << (saving_ratio * 100).round(1) << " %\n"
      io << "Recall        : " << (recall * 100).round(1) << " % of " << answerable.size << " questions\n"
      io << "Hook fires    : " << (firing_rate * 100).round(1) << " % on topic"
      unwanted = @outcomes.size - answerable.size
      if unwanted > 0
        io << ", " << (false_fire_rate * 100).round(1) << " % on " << unwanted << " off-topic prompts"
      end
      io << " (threshold " << @threshold << ")\n"
      io << "Hook injects  : " << mean_injected_count.round(2) << " passage(s), "
      io << mean_injected_cost.round(1) << " on average — right "
      io << (hook_accuracy * 100).round(1) << " % of the time\n"

      unless meaningful?
        if recall > 0.0 && mean_retrieved > 0
          io << "\n  ⚠ NOT MEANINGFUL — the hook fires on #{(false_fire_rate * 100).round(1)} % of\n"
          io << "    off-topic prompts, so the recall above is bought by injecting on\n"
          io << "    everything. Raise hook.similarity_threshold.\n"
        else
          io << "\n  ⚠ NOT MEANINGFUL — recall is zero, so the saving above only reflects\n"
          io << "    that little or nothing was returned. Do not read it as a result.\n"
        end
      end

      io << "\nPer question:\n"
      @outcomes.each do |outcome|
        # An off-topic prompt has no expected passage: its annotation carries an
        # arbitrary one, for schema uniformity only. Judging it on `hit?` marked
        # it ✗ for failing to find something it was never meant to find — and ✓
        # when the search happened to return that arbitrary passage. What is
        # being asked of these is whether the hook stayed quiet.
        if outcome.expect_fire?
          io << (outcome.hit? ? "  ✓ " : "  ✗ ")
          io << outcome.retrieved_cost.to_s.rjust(6) << "  " << outcome.question << '\n'
          unless outcome.hit?
            io << "           expected " << outcome.expected_file << " › " << outcome.expected_heading << '\n'
            io << "           returned " << (outcome.returned.empty? ? "(nothing)" : outcome.returned.join(", ")) << '\n'
          end
        else
          io << (outcome.fired? ? "  ✗ " : "  ✓ ")
          io << outcome.retrieved_cost.to_s.rjust(6) << "  " << outcome.question << " (off-topic)" << '\n'
          io << "           the hook fired on it; it should have stayed quiet\n" if outcome.fired?
        end
      end
    end

    # Aggregates are computed, so they are injected into the serialised form
    # rather than stored — keeping one source of truth for each figure.
    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "mode", @mode
        # Taken from the counter, not inferred from its human-readable label:
        # rewording that label would have flipped this field silently, telling
        # a consumer it was reading real token counts when it was reading
        # characters.
        json.field "exact", exact?
        json.field "baseline_cost", @baseline_cost
        json.field "top_k", @top_k
        json.field "mean_retrieved", mean_retrieved
        json.field "median_retrieved", median_retrieved
        json.field "saving_ratio", saving_ratio
        json.field "recall", recall
        json.field "threshold", @threshold
        json.field "firing_rate", firing_rate
        json.field "false_fire_rate", false_fire_rate
        json.field "hook_accuracy", hook_accuracy
        json.field "mean_injected_cost", mean_injected_cost
        json.field "mean_injected_count", mean_injected_count
        json.field "meaningful", meaningful?
        json.field "questions", @outcomes
      end
    end
  end
end
