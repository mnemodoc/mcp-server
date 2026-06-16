require "./spec_helper"

# A QdrantIndex whose knn returns canned hits (built at a dead port; knn is
# overridden so the wrapped Collection is never touched).
private class FakeQdrant < MnemodocServer::Store::QdrantIndex
  def initialize(@results : Array({id: Int64, score: Float64}))
    super(MnemodocServer::QdrantConfig.from_yaml("url: http://127.0.0.1:1"), "t")
  end

  def knn(query_vec : Array(Float32), limit : Int32) : Array({id: Int64, score: Float64})
    @results
  end
end

Spectator.describe MnemodocServer::Search do
  private def make_chunk(content : String, file : String = "doc/foo.md", heading : String? = nil, mtime : Int64 = Time.utc.to_unix) : MnemodocServer::Chunk
    MnemodocServer::Chunk.new(
      file_path: file,
      heading: heading,
      parent_heading: nil,
      content: content,
      embedding: [] of Float32,
      token_count: content.split.size,
      mtime: mtime
    )
  end

  describe MnemodocServer::Search::Semantic do
    it "returns cosine similarity of 1.0 for identical vectors" do
      v = [1.0_f32, 0.0_f32, 0.0_f32]
      score = MnemodocServer::Search::Semantic.cosine_similarity(v, v)
      expect(score).to be_close(1.0, 0.001)
    end

    it "returns 0.0 for orthogonal vectors" do
      a = [1.0_f32, 0.0_f32]
      b = [0.0_f32, 1.0_f32]
      score = MnemodocServer::Search::Semantic.cosine_similarity(a, b)
      expect(score).to be_close(0.0, 0.001)
    end

    it "returns 0.0 for zero vector" do
      a = [0.0_f32, 0.0_f32]
      b = [1.0_f32, 0.0_f32]
      score = MnemodocServer::Search::Semantic.cosine_similarity(a, b)
      expect(score).to eq(0.0)
    end

    it "returns 0.0 for vectors of different lengths" do
      a = [1.0_f32, 0.0_f32]
      b = [1.0_f32, 0.0_f32, 0.5_f32]
      score = MnemodocServer::Search::Semantic.cosine_similarity(a, b)
      expect(score).to eq(0.0)
    end

    it "ranks similar chunks higher" do
      query_vec = [1.0_f32, 0.0_f32, 0.0_f32]
      close = make_chunk("close")
      far = make_chunk("far")
      close_with_vec = MnemodocServer::Chunk.new(close.file_path, close.heading, close.parent_heading, close.content, [0.99_f32, 0.1_f32, 0.0_f32], 1, close.mtime)
      far_with_vec = MnemodocServer::Chunk.new(far.file_path, far.heading, far.parent_heading, far.content, [0.0_f32, 1.0_f32, 0.0_f32], 1, far.mtime)

      semantic = MnemodocServer::Search::Semantic.new
      results = semantic.search(query_vec, [close_with_vec, far_with_vec], top_k: 2)
      expect(results.first[:chunk].content).to eq("close")
    end
  end

  describe MnemodocServer::Search::Keyword do
    let(tmp_db) { "/tmp/mnemodoc-kw-#{Random::Secure.hex(4)}.db" }
    subject(store) { MnemodocServer::Store::SQLite.new(tmp_db) }
    after_each do
      store.close
      File.delete(tmp_db) rescue nil
    end

    private def index!(store, file : String, content : String, heading : String? = nil)
      embedding = Array(Float32).new(768, 0.1_f32)
      store.upsert_file(file, mtime: 1000_i64)
      store.save_chunks([MnemodocServer::Chunk.new(
        file_path: file, heading: heading, parent_heading: nil, content: content,
        embedding: embedding, token_count: 1, mtime: 1000_i64
      )])
    end

    it "returns empty results for an empty query" do
      keyword = MnemodocServer::Search::Keyword.new
      expect(keyword.search("", store, limit: 10)).to be_empty
    end

    it "returns empty when the query has only stop-words" do
      index!(store, "doc/foo.md", "crystal language")
      keyword = MnemodocServer::Search::Keyword.new
      expect(keyword.search("the and of", store, limit: 10)).to be_empty
    end

    it "matches chunks whose content contains the query term" do
      index!(store, "doc/foo.md", "crystal language")
      keyword = MnemodocServer::Search::Keyword.new
      results = keyword.search("crystal", store, limit: 10)
      expect(results.map(&.[:path])).to eq(["doc/foo.md"])
    end

    it "matches case-insensitively" do
      index!(store, "doc/foo.md", "Crystal Language")
      keyword = MnemodocServer::Search::Keyword.new
      expect(keyword.search("crystal", store, limit: 10).first[:path]).to eq("doc/foo.md")
    end

    it "matches heading text" do
      index!(store, "doc/foo.md", "body text", heading: "Persistence")
      keyword = MnemodocServer::Search::Keyword.new
      expect(keyword.search("persistence", store, limit: 10).map(&.[:path])).to eq(["doc/foo.md"])
    end

    it "returns one rank per file and assigns 1-based ranks" do
      index!(store, "doc/rare.md", "telomere")
      index!(store, "doc/common.md", "telomere common common")
      keyword = MnemodocServer::Search::Keyword.new
      results = keyword.search("telomere", store, limit: 10)
      expect(results.map(&.[:rank])).to eq((1..results.size).to_a)
      expect(results.map(&.[:path]).sort!).to eq(["doc/common.md", "doc/rare.md"])
    end

    it "matches whole words, not substrings" do
      index!(store, "doc/foo.md", "datatable widget")
      keyword = MnemodocServer::Search::Keyword.new
      # "data" is a real (non-stop-word) term; FTS5 must not match it inside "datatable".
      expect(keyword.search("data", store, limit: 10)).to be_empty
    end

    it "drops stop-words mixed into the query, matching only content terms" do
      index!(store, "doc/cron.md", "cron scheduler")
      index!(store, "doc/other.md", "nothing relevant")
      keyword = MnemodocServer::Search::Keyword.new
      # "the"/"dans" are stop-words; only "cron" should drive the match.
      results = keyword.search("the cron dans", store, limit: 10)
      expect(results.map(&.[:path])).to eq(["doc/cron.md"])
    end
  end

  describe "Semantic#search via store" do
    let(tmp_db) { "/tmp/mnemodoc-sem-#{Random::Secure.hex(4)}.db" }
    after_each { File.delete(tmp_db) rescue nil }

    # Builds a 768-dim unit vector whose first element is 1.0 and the rest are seed,
    # then normalizes. This guarantees distinct directions for different seeds because
    # element[0] differs while element[i>0] is seed — unlike all-seed vectors whose
    # L2 directions collapse to an identical unit vector regardless of seed.
    private def vec_768(seed : Float32) : Array(Float32)
      raw = Array(Float32).new(768) { |i| i == 0 ? 1.0_f32 : seed }
      norm = Math.sqrt(raw.sum { |v| v.to_f64 * v.to_f64 })
      raw.map { |v| (v.to_f64 / norm).to_f32 }
    end

    it "returns the closest chunk via KNN" do
      store = MnemodocServer::Store::SQLite.new(tmp_db)
      mtime = Time.utc.to_unix
      store.upsert_file("/a.md", mtime: mtime)
      store.upsert_file("/b.md", mtime: mtime)
      store.save_chunks([
        MnemodocServer::Chunk.new(file_path: "/a.md", heading: nil, parent_heading: nil,
          content: "near", embedding: vec_768(0.1_f32), token_count: 1, mtime: mtime),
        MnemodocServer::Chunk.new(file_path: "/b.md", heading: nil, parent_heading: nil,
          content: "far", embedding: vec_768(0.9_f32), token_count: 1, mtime: mtime),
      ])
      results = MnemodocServer::Search::Semantic.new.search(vec_768(0.1_f32), store, top_k: 1)
      expect(results.first[:chunk].content).to eq("near")
      expect(results.first[:rank]).to eq(1)
      store.close
    end
  end

  describe MnemodocServer::Search::Hybrid do
    it "applies recency boost to recent files" do
      config = MnemodocServer::SearchConfig.from_yaml("recency_days: 7\nrecency_boost: 0.1")
      hybrid = MnemodocServer::Search::Hybrid.new(config)

      recent_mtime = Time.utc.to_unix
      old_mtime = (Time.utc - 30.days).to_unix

      recent_score = hybrid.apply_recency(0.5_f64, recent_mtime)
      old_score = hybrid.apply_recency(0.5_f64, old_mtime)

      expect(recent_score).to be > old_score
    end

    it "computes RRF score correctly" do
      hybrid = MnemodocServer::Search::Hybrid.new(MnemodocServer::SearchConfig.from_yaml(""))
      expect(hybrid.rrf_score(1)).to be_close(1.0 / 61, 0.0001)
      expect(hybrid.rrf_score(60)).to be_close(1.0 / 120, 0.0001)
    end

    it "applies recency multiplicatively" do
      config = MnemodocServer::SearchConfig.from_yaml("recency_days: 7\nrecency_boost: 0.1")
      hybrid = MnemodocServer::Search::Hybrid.new(config)
      recent = (Time.utc).to_unix
      old = (Time.utc - 30.days).to_unix
      expect(hybrid.apply_recency(0.5_f64, recent)).to be_close(0.55, 0.0001)
      expect(hybrid.apply_recency(0.5_f64, old)).to eq(0.5)
    end

    it "does not let a large file outrank a small relevant file by chunk count" do
      config = MnemodocServer::SearchConfig.from_yaml("mode: keyword\ntop_k: 5\nkeyword_weight: 0.3")
      hybrid = MnemodocServer::Search::Hybrid.new(config)
      tmp_db = "/tmp/mnemodoc-hybrid-kw-#{Random::Secure.hex(4)}.db"
      store = MnemodocServer::Store::SQLite.new(tmp_db)
      embedding = Array(Float32).new(768, 0.1_f32)
      store.upsert_file("big.md", mtime: 0_i64)
      store.upsert_file("small.md", mtime: 0_i64)
      big = (1..10).map do |i|
        MnemodocServer::Chunk.new(file_path: "big.md", heading: "## h#{i}", parent_heading: nil,
          content: "cron stuff #{i}", embedding: embedding, token_count: 1, mtime: 0_i64)
      end
      small = [MnemodocServer::Chunk.new(file_path: "small.md", heading: "## only", parent_heading: nil,
        content: "cron stuff", embedding: embedding, token_count: 1, mtime: 0_i64)]
      store.save_chunks(big + small)
      results = hybrid.search("cron", [] of Float32, store)
      store.close
      File.delete(tmp_db) rescue nil
      # The small file's single chunk must not be buried under the big file's chunks:
      # its per-chunk keyword mass is higher because the big file's mass is split 10 ways.
      expect(results.first.chunk.file_path).to eq("small.md")
    end
  end

  describe "qdrant backend" do
    let(tmp_db) { "/tmp/mnemodoc-q-#{Random::Secure.hex(4)}.db" }
    subject(store) { MnemodocServer::Store::SQLite.new(tmp_db, vec0: false) }
    after_each do
      store.close
      File.delete(tmp_db) rescue nil
    end

    private def index!(store, file : String, content : String)
      vec = Array(Float32).new(768, 0.1_f32)
      store.upsert_file(file, mtime: 1000_i64)
      store.save_chunks([MnemodocServer::Chunk.new(
        file_path: file, heading: nil, parent_heading: nil,
        content: content, embedding: vec, token_count: 1, mtime: 1000_i64)])
    end

    it "hydrates Qdrant hit ids into chunks in score order" do
      index!(store, "doc/a.md", "alpha")
      index!(store, "doc/b.md", "beta")
      ids = store.chunk_ids_for_file("doc/a.md") + store.chunk_ids_for_file("doc/b.md")
      fake = FakeQdrant.new([{id: ids[1], score: 0.9}, {id: ids[0], score: 0.4}])
      results = MnemodocServer::Search::Semantic.new.search([0.1_f32], fake, store, 5)
      expect(results.map(&.[:chunk].content)).to eq(["beta", "alpha"])
      expect(results.first[:rank]).to eq(1)
    end

    it "degrades to keyword results when Qdrant returns nothing" do
      index!(store, "doc/k.md", "telomere sequence")
      config = MnemodocServer::SearchConfig.from_yaml("mode: hybrid\ntop_k: 5")
      hybrid = MnemodocServer::Search::Hybrid.new(config, FakeQdrant.new([] of {id: Int64, score: Float64}))
      results = hybrid.search("telomere", [0.1_f32], store)
      expect(results.map(&.chunk.file_path)).to contain("doc/k.md")
    end
  end
end
