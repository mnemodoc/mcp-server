require "json"

module Bench
  # One question's result: what it cost to answer, and whether the passage that
  # actually holds the answer came back.
  struct QuestionOutcome
    include JSON::Serializable

    getter question : String
    getter retrieved_cost : Int32
    getter? hit : Bool
    getter expected_file : String
    getter expected_heading : String
    # The (file, heading) pairs the search returned, for diagnosing a miss.
    getter returned : Array(String)

    def initialize(@question, @retrieved_cost, @hit, @expected_file, @expected_heading, @returned)
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
    @[JSON::Field(key: "questions")]
    getter outcomes : Array(QuestionOutcome)

    def initialize(@mode, @baseline_cost, @top_k, @outcomes)
    end

    def recall : Float64
      return 0.0 if @outcomes.empty?
      @outcomes.count(&.hit?) / @outcomes.size.to_f
    end

    def mean_retrieved : Float64
      return 0.0 if @outcomes.empty?
      @outcomes.sum(&.retrieved_cost) / @outcomes.size.to_f
    end

    def median_retrieved : Float64
      return 0.0 if @outcomes.empty?
      sorted = @outcomes.map(&.retrieved_cost).sort!
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
    def meaningful? : Bool
      recall > 0.0 && mean_retrieved > 0
    end

    def to_s(io : IO) : Nil
      io << "Unit          : " << @mode << '\n'
      io << "Baseline      : " << @baseline_cost << " (whole corpus, loaded every session)\n"
      io << "Retrieved     : mean " << mean_retrieved.round(1) << ", median " << median_retrieved.round(1)
      io << " (top-" << @top_k << ")\n"
      io << "Saving        : " << (saving_ratio * 100).round(1) << " %\n"
      io << "Recall        : " << (recall * 100).round(1) << " % of " << @outcomes.size << " questions\n"

      unless meaningful?
        io << "\n  ⚠ NOT MEANINGFUL — recall is zero, so the saving above only reflects\n"
        io << "    that little or nothing was returned. Do not read it as a result.\n"
      end

      io << "\nPer question:\n"
      @outcomes.each do |outcome|
        io << (outcome.hit? ? "  ✓ " : "  ✗ ")
        io << outcome.retrieved_cost.to_s.rjust(6) << "  " << outcome.question << '\n'
        unless outcome.hit?
          io << "           expected " << outcome.expected_file << " › " << outcome.expected_heading << '\n'
          io << "           returned " << (outcome.returned.empty? ? "(nothing)" : outcome.returned.join(", ")) << '\n'
        end
      end
    end

    # Aggregates are computed, so they are injected into the serialised form
    # rather than stored — keeping one source of truth for each figure.
    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "mode", @mode
        json.field "exact", !@mode.starts_with?("characters")
        json.field "baseline_cost", @baseline_cost
        json.field "top_k", @top_k
        json.field "mean_retrieved", mean_retrieved
        json.field "median_retrieved", median_retrieved
        json.field "saving_ratio", saving_ratio
        json.field "recall", recall
        json.field "meaningful", meaningful?
        json.field "questions", @outcomes
      end
    end
  end
end
