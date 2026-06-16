require "./spec_helper"

Spectator.describe MnemodocServer::Store::QdrantIndex do
  before_each { MnemodocServer::Advisories.clear }
  after_each { MnemodocServer::Advisories.clear }

  # A QdrantIndex pointed at a dead port: every op must degrade gracefully.
  subject(index) do
    cfg = MnemodocServer::QdrantConfig.from_yaml("url: http://127.0.0.1:1")
    MnemodocServer::Store::QdrantIndex.new(cfg, "t")
  end

  it "returns safe values and records an advisory instead of raising when Qdrant is down" do
    vec = Array(Float32).new(768, 0.1_f32)
    expect(index.ensure(768)).to be_false
    expect(index.upsert([{id: 1_i64, vector: vec}])).to be_false
    expect(index.delete([1_i64])).to be_false
    expect(index.clear).to be_false
    expect(index.knn(vec, 5)).to be_empty
    expect(index.count).to be_nil
    expect(MnemodocServer::Advisories.all).not_to be_empty
  end

  it "short-circuits empty upsert/delete without touching Qdrant" do
    expect(index.upsert([] of {id: Int64, vector: Array(Float32)})).to be_true
    expect(index.delete([] of Int64)).to be_true
    expect(MnemodocServer::Advisories.all).to be_empty
  end
end
