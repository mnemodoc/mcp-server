require "./spec_helper"

# The rule the prompt hook applies to decide what — if anything — to inject.
# It lives on its own so the benchmark can replay exactly what ships: a harness
# measuring a reimplementation of the rule measures the wrong thing.
Spectator.describe MnemodocServer::Search::HookSelection do
  private def result(similarity : Float64?, score : Float64 = 1.0)
    chunk = MnemodocServer::Chunk.new(
      file_path: "/docs/a.md", heading: "## H", parent_heading: nil,
      content: "body", embedding: [] of Float32, token_count: 1, mtime: 0_i64,
    )
    MnemodocServer::Search::SearchResult.new(chunk, score, similarity)
  end

  private def choose(results, similarity : Float64 = 0.5, margin : Float64 = 0.01, max : Int32 = 3)
    MnemodocServer::Search::HookSelection.choose(results,
      similarity_threshold: similarity, margin_threshold: margin, max_passages: max)
  end

  describe "the gate" do
    it "injects nothing when there is no result" do
      expect(choose([] of MnemodocServer::Search::SearchResult)).to be_empty
    end

    it "injects nothing below the similarity threshold" do
      expect(choose([result(0.49)])).to be_empty
    end

    # A chunk the semantic signal never scored cannot clear a similarity gate on
    # lexical evidence alone.
    it "injects nothing when the best result carries no similarity" do
      expect(choose([result(nil)])).to be_empty
    end

    it "injects the best result once it clears the threshold" do
      expect(choose([result(0.51)]).size).to eq(1)
    end
  end

  describe "the margin" do
    # A decisive lead means one passage is enough: widening would only spend
    # tokens.
    it "injects one when the best result leads decisively" do
      expect(choose([result(0.80), result(0.60), result(0.55)]).size).to eq(1)
    end

    # A near-tie means the ranking is not to be trusted, so hand over the
    # contenders rather than gamble on the top one. Widening on a case that was
    # already right costs tokens, never accuracy — which is why the rule works
    # even though decisive and undecided cases overlap.
    it "widens when the second result is within the margin" do
      expect(choose([result(0.80), result(0.795), result(0.79)]).size).to eq(3)
    end

    it "respects the cap when widening" do
      results = [result(0.80), result(0.799), result(0.798), result(0.797)]
      expect(choose(results, max: 2).size).to eq(2)
    end

    # Widening must not smuggle in a passage that would never have passed the
    # gate on its own.
    it "keeps every widened passage above the similarity threshold" do
      chosen = choose([result(0.52), result(0.515), result(0.30)])
      expect(chosen.size).to eq(2)
      expect(chosen.all? { |item| (item.similarity || 0.0) >= 0.5 }).to be_true
    end

    it "widens on a negative gap, where the fused order disagrees with cosine" do
      expect(choose([result(0.60), result(0.62)]).size).to eq(2)
    end
  end
end
