require "./spec_helper"

# Opt-in integration: only runs when QDRANT_TEST_URL points at a real Qdrant
# (e.g. `mise dev:qdrant-up`); otherwise the example skips so `mise dev:check`
# stays runnable without a container.
Spectator.describe "Qdrant integration" do
  it "ensures, upserts, knn, counts and deletes against a real Qdrant" do
    # Skipped (empty example) unless QDRANT_TEST_URL is set.
    if url = ENV["QDRANT_TEST_URL"]?
      cfg = MnemodocServer::QdrantConfig.from_yaml("url: #{url}")
      index = MnemodocServer::Store::QdrantIndex.new(cfg, "mnemodoc-it-#{Random::Secure.hex(4)}")

      begin
        expect(index.ensure(768)).to be_true

        v1 = Array(Float32).new(768) { |i| i == 0 ? 1.0_f32 : 0.0_f32 }
        v2 = Array(Float32).new(768) { |i| i == 1 ? 1.0_f32 : 0.0_f32 }
        expect(index.upsert([{id: 1_i64, vector: v1}, {id: 2_i64, vector: v2}])).to be_true
        expect(index.count).to eq(2_i64)

        hits = index.knn(v1, 1)
        expect(hits.first[:id]).to eq(1_i64)

        expect(index.delete([1_i64])).to be_true
        expect(index.count).to eq(1_i64)
      ensure
        index.clear
      end
    end
  end
end
