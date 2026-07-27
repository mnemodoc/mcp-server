require "./spec_helper"
require "../bench/report"

# The report is where a cost figure becomes a claim, so its arithmetic is
# tested on its own — no I/O, no search, no network.
Spectator.describe Bench::Report do
  private def outcome(retrieved : Int32, hit : Bool, question : String = "q")
    Bench::QuestionOutcome.new(
      question: question,
      retrieved_cost: retrieved,
      hit: hit,
      expected_file: "a.md",
      expected_heading: "H",
      returned: [] of String,
    )
  end

  describe "#recall" do
    it "is the share of questions whose expected passage came back" do
      report = Bench::Report.new(mode: "m", baseline_cost: 1000, top_k: 5,
        outcomes: [outcome(10, true), outcome(10, false), outcome(10, true), outcome(10, true)])
      expect(report.recall).to be_close(0.75, 1e-9)
    end

    it "is zero, not one, when nothing matches" do
      report = Bench::Report.new(mode: "m", baseline_cost: 1000, top_k: 5,
        outcomes: [outcome(0, false), outcome(0, false)])
      expect(report.recall).to eq(0.0)
    end
  end

  describe "#saving_ratio" do
    it "compares the mean retrieved cost against the baseline" do
      report = Bench::Report.new(mode: "m", baseline_cost: 1000, top_k: 5,
        outcomes: [outcome(100, true), outcome(300, true)])
      # mean 200 of a 1000 baseline → 80 % saved
      expect(report.mean_retrieved).to be_close(200.0, 1e-9)
      expect(report.saving_ratio).to be_close(0.8, 1e-9)
    end

    # The degenerate case the whole design exists to guard against: returning
    # nothing is a perfect saving and a total failure, and the report must make
    # that impossible to read as a success.
    it "reports a total saving as suspect when recall is zero" do
      report = Bench::Report.new(mode: "m", baseline_cost: 1000, top_k: 5,
        outcomes: [outcome(0, false), outcome(0, false)])
      expect(report.saving_ratio).to be_close(1.0, 1e-9)
      expect(report.meaningful?).to be_false
    end

    it "is meaningful when passages come back and are relevant" do
      report = Bench::Report.new(mode: "m", baseline_cost: 1000, top_k: 5,
        outcomes: [outcome(100, true), outcome(120, true)])
      expect(report.meaningful?).to be_true
    end

    it "guards against a zero baseline rather than dividing by it" do
      report = Bench::Report.new(mode: "m", baseline_cost: 0, top_k: 5,
        outcomes: [outcome(10, true)])
      expect(report.saving_ratio).to eq(0.0)
    end
  end

  describe "#median_retrieved" do
    it "takes the middle value on an odd count" do
      report = Bench::Report.new(mode: "m", baseline_cost: 100, top_k: 5,
        outcomes: [outcome(10, true), outcome(50, true), outcome(30, true)])
      expect(report.median_retrieved).to be_close(30.0, 1e-9)
    end

    it "averages the two middle values on an even count" do
      report = Bench::Report.new(mode: "m", baseline_cost: 100, top_k: 5,
        outcomes: [outcome(10, true), outcome(20, true), outcome(30, true), outcome(40, true)])
      expect(report.median_retrieved).to be_close(25.0, 1e-9)
    end
  end

  # Every rendering must carry the unit and the recall alongside the saving —
  # a saving published on its own is not a valid output of this harness.
  describe "#to_s" do
    it "always states the unit, the recall and the saving together" do
      report = Bench::Report.new(mode: "exact (count_tokens, model claude-opus-5)",
        baseline_cost: 1000, top_k: 5, outcomes: [outcome(100, true), outcome(200, false)])
      text = report.to_s.downcase
      expect(text).to contain("count_tokens")
      expect(text).to contain("recall")
      expect(text).to contain("saving")
    end

    it "flags the result when recall is zero" do
      report = Bench::Report.new(mode: "m", baseline_cost: 1000, top_k: 5,
        outcomes: [outcome(0, false)])
      expect(report.to_s.downcase).to contain("not meaningful")
    end
  end

  describe "#to_json" do
    it "carries the unit, the aggregates and the per-question detail" do
      report = Bench::Report.new(mode: "m", baseline_cost: 1000, top_k: 5,
        outcomes: [outcome(100, true, "how do I X?")])
      parsed = JSON.parse(report.to_json)
      expect(parsed["mode"].as_s).to eq("m")
      expect(parsed["baseline_cost"].as_i).to eq(1000)
      expect(parsed["recall"].as_f).to be_close(1.0, 1e-9)
      expect(parsed["questions"].as_a.size).to eq(1)
      expect(parsed["questions"][0]["question"].as_s).to eq("how do I X?")
    end
  end
end
