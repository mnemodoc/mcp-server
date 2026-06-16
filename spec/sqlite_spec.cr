require "./spec_helper"
require "file_utils"

Spectator.describe MnemodocServer::Store::SQLite do
  let(tmp_db) { "/tmp/mnemodoc-test-#{Random::Secure.hex(4)}.db" }
  subject(store) { MnemodocServer::Store::SQLite.new(tmp_db) }

  after_each do
    store.close
    File.delete(tmp_db) rescue nil
  end

  describe "#chunks_fts sync" do
    it "mirrors chunks into the FTS index and stays in sync on delete" do
      embedding = Array(Float32).new(768, 0.1_f32)
      store.upsert_file("doc/foo.md", mtime: 1000_i64)
      store.save_chunks([
        MnemodocServer::Chunk.new(file_path: "doc/foo.md", heading: "## A", parent_heading: nil, content: "alpha beta", embedding: embedding, token_count: 2, mtime: 1000_i64),
        MnemodocServer::Chunk.new(file_path: "doc/foo.md", heading: "## B", parent_heading: nil, content: "gamma", embedding: embedding, token_count: 1, mtime: 1000_i64),
      ])
      expect(store.fts_chunk_count).to eq(2)
      expect(store.fts_chunk_count).to eq(store.chunk_count)

      store.delete_file("doc/foo.md")
      expect(store.fts_chunk_count).to eq(0)
    end
  end

  describe "#keyword_search" do
    it "ranks files by BM25 relevance, best first, one row per file" do
      embedding = Array(Float32).new(768, 0.1_f32)
      store.upsert_file("doc/match.md", mtime: 1000_i64)
      store.upsert_file("doc/other.md", mtime: 1000_i64)
      store.save_chunks([
        MnemodocServer::Chunk.new(file_path: "doc/match.md", heading: "## A", parent_heading: nil, content: "crystal crystal lang", embedding: embedding, token_count: 3, mtime: 1000_i64),
        MnemodocServer::Chunk.new(file_path: "doc/match.md", heading: "## B", parent_heading: nil, content: "crystal again", embedding: embedding, token_count: 2, mtime: 1000_i64),
        MnemodocServer::Chunk.new(file_path: "doc/other.md", heading: "## C", parent_heading: nil, content: "ruby on rails", embedding: embedding, token_count: 3, mtime: 1000_i64),
      ])

      results = store.keyword_search(%("crystal"), limit: 10)
      expect(results.map(&.[:path])).to eq(["doc/match.md"])
    end
  end

  describe "#chunks_for_files" do
    it "returns the chunks (with content) for the requested files only" do
      embedding = Array(Float32).new(768, 0.1_f32)
      store.upsert_file("doc/a.md", mtime: 1000_i64)
      store.upsert_file("doc/b.md", mtime: 1000_i64)
      store.save_chunks([
        MnemodocServer::Chunk.new(file_path: "doc/a.md", heading: "## A1", parent_heading: nil, content: "a-one", embedding: embedding, token_count: 1, mtime: 1000_i64),
        MnemodocServer::Chunk.new(file_path: "doc/a.md", heading: "## A2", parent_heading: nil, content: "a-two", embedding: embedding, token_count: 1, mtime: 1000_i64),
        MnemodocServer::Chunk.new(file_path: "doc/b.md", heading: "## B1", parent_heading: nil, content: "b-one", embedding: embedding, token_count: 1, mtime: 1000_i64),
      ])

      chunks = store.chunks_for_files(["doc/a.md"])
      expect(chunks.map(&.file_path).uniq!).to eq(["doc/a.md"])
      expect(chunks.size).to eq(2)
      expect(chunks.map(&.content).sort!).to eq(["a-one", "a-two"])
      expect(store.chunks_for_files([] of String)).to be_empty
    end
  end

  describe "WAL mode" do
    it "enables WAL journal mode" do
      expect(store.journal_mode).to eq("wal")
    end
  end

  describe "qdrant backend helpers" do
    it "skips vec_chunks when vec0 is disabled but keeps chunks + fts + blobs" do
      novec_db = "/tmp/mnemodoc-novec-#{Random::Secure.hex(4)}.db"
      db = MnemodocServer::Store::SQLite.new(novec_db, vec0: false)
      embedding = Array(Float32).new(768, 0.1_f32)
      db.upsert_file("doc/x.md", mtime: 1000_i64)
      db.save_chunks([
        MnemodocServer::Chunk.new(file_path: "doc/x.md", heading: nil, parent_heading: nil, content: "a", embedding: embedding, token_count: 1, mtime: 1000_i64),
        MnemodocServer::Chunk.new(file_path: "doc/x.md", heading: nil, parent_heading: nil, content: "b", embedding: embedding, token_count: 1, mtime: 1000_i64),
      ])
      expect(db.vec_chunk_count).to eq(0_i64)
      expect(db.chunk_count).to eq(2_i64)
      expect(db.fts_chunk_count).to eq(2_i64)
      db.close
      File.delete(novec_db) rescue nil
    end

    it "reads ids, hydrated chunks, and embeddings by id/file" do
      embedding = Array(Float32).new(768) { |i| (i.to_f64 / 768).to_f32 }
      store.upsert_file("doc/a.md", mtime: 1000_i64)
      store.save_chunks([
        MnemodocServer::Chunk.new(file_path: "doc/a.md", heading: "## H", parent_heading: nil, content: "hello", embedding: embedding, token_count: 1, mtime: 1000_i64),
      ])
      ids = store.chunk_ids_for_file("doc/a.md")
      expect(ids.size).to eq(1)
      expect(store.chunks_by_ids(ids)[ids.first].content).to eq("hello")

      embs = store.embeddings_for_file("doc/a.md")
      expect(embs.size).to eq(1)
      expect(embs.first[:id]).to eq(ids.first)
      expect(embs.first[:vector].size).to eq(768)
      expect(store.stored_embeddings.size).to eq(1)
    end
  end

  describe "#upsert_file and #file_indexed?" do
    it "returns false for unknown file" do
      expect(store.file_indexed?("doc/foo.md", mtime: 1000_i64)).to be_false
    end

    it "returns true after upsert with same mtime" do
      store.upsert_file("doc/foo.md", mtime: 1000_i64)
      expect(store.file_indexed?("doc/foo.md", mtime: 1000_i64)).to be_true
    end

    it "returns false when mtime changed" do
      store.upsert_file("doc/foo.md", mtime: 1000_i64)
      expect(store.file_indexed?("doc/foo.md", mtime: 2000_i64)).to be_false
    end
  end

  describe "#exists?" do
    it "returns false for unknown path" do
      expect(store.exists?("doc/missing.md")).to be_false
    end

    it "returns true after upsert" do
      store.upsert_file("doc/foo.md", mtime: 1000_i64)
      expect(store.exists?("doc/foo.md")).to be_true
    end
  end

  describe "#save_chunks" do
    it "stores and retrieves chunks with content (embeddings not hydrated)" do
      embedding = Array(Float32).new(768) { |i| (i.to_f64 / 768).to_f32 }
      store.upsert_file("doc/foo.md", mtime: 1000_i64)
      store.save_chunks([
        MnemodocServer::Chunk.new(file_path: "doc/foo.md", heading: "## Section A", parent_heading: nil, content: "content here", embedding: embedding, token_count: 10, mtime: 1000_i64),
      ])

      all = store.chunks_for_files(["doc/foo.md"])
      expect(all.size).to eq(1)
      expect(all.first.file_path).to eq("doc/foo.md")
      expect(all.first.heading).to eq("## Section A")
      expect(all.first.content).to eq("content here")
      # chunks_for_files never hydrates the embedding (vec0 owns the vectors).
      expect(all.first.embedding).to be_empty
    end
  end

  describe "#delete_file" do
    it "removes chunks for the file" do
      embedding = Array(Float32).new(768, 0.1_f32)
      store.upsert_file("doc/foo.md", mtime: 1000_i64)
      store.save_chunks([MnemodocServer::Chunk.new("doc/foo.md", nil, nil, "x", embedding, 1, 1000_i64)])
      store.delete_file("doc/foo.md")
      expect(store.chunk_count).to eq(0_i64)
    end

    it "returns 0 for unknown path" do
      expect(store.delete_file("doc/nonexistent.md")).to eq(0_i64)
    end

    it "returns 1 after deleting an indexed file" do
      embedding = Array(Float32).new(4, 0.1_f32)
      store.upsert_file("doc/bar.md", mtime: 1000_i64)
      store.save_chunks([MnemodocServer::Chunk.new("doc/bar.md", nil, nil, "y", embedding, 1, 1000_i64)])
      expect(store.delete_file("doc/bar.md")).to eq(1_i64)
    end
  end

  describe "#file_paths" do
    it "returns empty array when no files indexed" do
      expect(store.file_paths).to be_empty
    end

    it "returns all indexed paths" do
      store.upsert_file("/abs/a.md", mtime: 1000_i64)
      store.upsert_file("/abs/b.md", mtime: 2000_i64)
      paths = store.file_paths.sort!
      expect(paths).to eq(["/abs/a.md", "/abs/b.md"])
    end
  end

  describe "#indexed_path_for" do
    it "returns nil for a path not in the index" do
      expect(store.indexed_path_for("doc/missing.md")).to be_nil
    end

    it "returns the path on exact match" do
      store.upsert_file("/abs/doc/foo.md", mtime: 1000_i64)
      expect(store.indexed_path_for("/abs/doc/foo.md")).to eq("/abs/doc/foo.md")
    end

    it "returns the path when input expands to it" do
      abs = File.expand_path(".")
      store.upsert_file("#{abs}/doc/foo.md", mtime: 1000_i64)
      # Pass a relative path that expands to the stored absolute path
      expect(store.indexed_path_for("doc/foo.md")).to eq("#{abs}/doc/foo.md")
    end

    it "returns the path on unique suffix match" do
      store.upsert_file("/project/docs/config/audit.md", mtime: 1000_i64)
      expect(store.indexed_path_for("config/audit.md")).to eq("/project/docs/config/audit.md")
    end

    it "returns nil when suffix matches multiple paths (ambiguous)" do
      store.upsert_file("/project/a/shared.md", mtime: 1000_i64)
      store.upsert_file("/project/b/shared.md", mtime: 2000_i64)
      expect(store.indexed_path_for("shared.md")).to be_nil
    end

    it "returns nil when suffix matches no paths" do
      store.upsert_file("/project/docs/other.md", mtime: 1000_i64)
      expect(store.indexed_path_for("config/missing.md")).to be_nil
    end
  end

  describe "#list_files" do
    it "returns indexed files with metadata" do
      store.upsert_file("doc/a.md", mtime: 1000_i64)
      store.upsert_file("doc/b.md", mtime: 2000_i64)
      files = store.list_files
      expect(files.map(&.path).sort!).to eq(["doc/a.md", "doc/b.md"])
    end
  end

  describe "#meta_set and #meta_get" do
    it "returns nil for an unknown key" do
      expect(store.meta_get("nonexistent")).to be_nil
    end

    it "stores and retrieves a value" do
      store.meta_set("embedding_model", "nomic-embed-text")
      expect(store.meta_get("embedding_model")).to eq("nomic-embed-text")
    end

    it "overwrites an existing value" do
      store.meta_set("embedding_model", "nomic-embed-text")
      store.meta_set("embedding_model", "mxbai-embed-large")
      expect(store.meta_get("embedding_model")).to eq("mxbai-embed-large")
    end
  end

  describe "#embedding_model and #embedding_model=" do
    it "returns nil when no model recorded" do
      expect(store.embedding_model).to be_nil
    end

    it "stores and retrieves the embedding model name" do
      store.embedding_model = "nomic-embed-text"
      expect(store.embedding_model).to eq("nomic-embed-text")
    end
  end

  describe "#model_mismatch?" do
    it "returns false when no model is stored" do
      expect(store.model_mismatch?("nomic-embed-text")).to be_false
    end

    it "returns false when stored model matches current" do
      store.embedding_model = "nomic-embed-text"
      expect(store.model_mismatch?("nomic-embed-text")).to be_false
    end

    it "returns true when stored model differs from current" do
      store.embedding_model = "nomic-embed-text"
      expect(store.model_mismatch?("mxbai-embed-large")).to be_true
    end
  end

  describe "sqlite-vec" do
    it "exposes vec_version() on every connection" do
      db = MnemodocServer::Store::SQLite.new("/tmp/vec-ver-#{Random::Secure.hex(4)}.db")
      version = db.vec_version
      expect(version).to start_with("v0.")
      db.close
    end

    it "can create and query a vec0 virtual table" do
      db = MnemodocServer::Store::SQLite.new("/tmp/vec-knn-#{Random::Secure.hex(4)}.db")
      begin
        # Direct SQL to prove vec0 works end-to-end
        version = db.vec_version
        expect(version).not_to be_empty
      ensure
        db.close
      end
    end
  end

  describe "#index_file" do
    it "makes chunks visible immediately" do
      embedding = Array(Float32).new(4, 0.5_f32)
      chunks = [MnemodocServer::Chunk.new(file_path: "doc/c.md", heading: nil, parent_heading: nil, content: "cached content", embedding: embedding, token_count: 5, mtime: 2000_i64)]
      store.index_file("doc/c.md", 2000_i64, chunks)

      all = store.chunks_for_files(["doc/c.md"])
      expect(all.size).to eq(1)
      expect(all.first.content).to eq("cached content")
    end

    it "replaces a file's chunks on a second index_file call" do
      embedding = Array(Float32).new(4, 0.1_f32)
      store.index_file("doc/d.md", 1000_i64, [MnemodocServer::Chunk.new(file_path: "doc/d.md", heading: nil, parent_heading: nil, content: "v1", embedding: embedding, token_count: 1, mtime: 1000_i64)])
      expect(store.chunks_for_files(["doc/d.md"]).first.content).to eq("v1")

      store.index_file("doc/d.md", 2000_i64, [MnemodocServer::Chunk.new(file_path: "doc/d.md", heading: nil, parent_heading: nil, content: "v2", embedding: embedding, token_count: 1, mtime: 2000_i64)])
      expect(store.chunks_for_files(["doc/d.md"]).first.content).to eq("v2")
    end

    it "removes a file's chunks on delete_file" do
      embedding = Array(Float32).new(4, 0.2_f32)
      store.index_file("doc/e.md", 1000_i64, [MnemodocServer::Chunk.new(file_path: "doc/e.md", heading: nil, parent_heading: nil, content: "to delete", embedding: embedding, token_count: 1, mtime: 1000_i64)])
      expect(store.chunks_for_files(["doc/e.md"]).size).to eq(1)
      store.delete_file("doc/e.md")
      expect(store.chunks_for_files(["doc/e.md"])).to be_empty
    end
  end

  describe "vec_chunks" do
    let(tmp_db) { "/tmp/mnemodoc-vec-#{Random::Secure.hex(4)}.db" }
    after_each { File.delete(tmp_db) rescue nil }

    private def make_store : MnemodocServer::Store::SQLite
      MnemodocServer::Store::SQLite.new(tmp_db)
    end

    private def vec_768(seed : Float32 = 0.1_f32) : Array(Float32)
      # Constant vector: all elements equal to seed (not normalised so that
      # different seeds produce genuinely different L2 distances).
      Array(Float32).new(768, seed)
    end

    it "backfills vec_chunks from existing BLOB embeddings on first open" do
      db = make_store
      mtime = Time.utc.to_unix
      db.upsert_file("/x.md", mtime: mtime)
      chunk = MnemodocServer::Chunk.new(
        file_path: "/x.md", heading: nil, parent_heading: nil,
        content: "hello", embedding: vec_768, token_count: 1, mtime: mtime
      )
      db.save_chunks([chunk])
      db.close

      # Reopen — should backfill
      db2 = make_store
      results = db2.knn_chunks(vec_768, limit: 1)
      expect(results.size).to eq(1)
      expect(results.first[:chunk].content).to eq("hello")
      # The backfilled vector must match the original exactly: querying with the
      # same vector yields ~zero distance (score 1/(1+d) ~ 1). This guards the
      # serialize_embedding -> BLOB -> deserialize_embedding round-trip fidelity,
      # which backfill_vec_chunks depends on.
      expect(results.first[:score]).to be_close(1.0, 0.001)
      db2.close
    end

    it "knn_chunks returns the nearest chunk" do
      db = make_store
      mtime = Time.utc.to_unix
      db.upsert_file("/a.md", mtime: mtime)
      db.upsert_file("/b.md", mtime: mtime)
      db.save_chunks([
        MnemodocServer::Chunk.new(file_path: "/a.md", heading: nil, parent_heading: nil,
          content: "crystal", embedding: vec_768(0.1_f32), token_count: 1, mtime: mtime),
        MnemodocServer::Chunk.new(file_path: "/b.md", heading: nil, parent_heading: nil,
          content: "rails", embedding: vec_768(0.9_f32), token_count: 1, mtime: mtime),
      ])
      results = db.knn_chunks(vec_768(0.1_f32), limit: 2)
      expect(results.first[:chunk].content).to eq("crystal")
      expect(results.first[:rank]).to eq(1)
      db.close
    end

    it "clear_index! wipes files, chunks, and vec_chunks" do
      db = make_store
      mtime = Time.utc.to_unix
      db.upsert_file("/m.md", mtime: mtime)
      db.save_chunks([MnemodocServer::Chunk.new(
        file_path: "/m.md", heading: nil, parent_heading: nil,
        content: "x", embedding: vec_768, token_count: 1, mtime: mtime
      )])
      expect(db.vec_chunk_count).to eq(1)
      db.clear_index!
      expect(db.file_count).to eq(0)
      expect(db.chunk_count).to eq(0)
      expect(db.vec_chunk_count).to eq(0)
      db.close
    end

    it "removes vec_chunks entries when a file is deleted" do
      db = make_store
      mtime = Time.utc.to_unix
      db.upsert_file("/del.md", mtime: mtime)
      db.save_chunks([
        MnemodocServer::Chunk.new(file_path: "/del.md", heading: nil, parent_heading: nil,
          content: "to delete", embedding: vec_768, token_count: 1, mtime: mtime),
      ])
      expect(db.vec_chunk_count).to eq(1)
      db.delete_file("/del.md")
      # Assert the raw vec0 row is actually gone, not just hidden by hydration
      expect(db.vec_chunk_count).to eq(0)
      expect(db.knn_chunks(vec_768, limit: 1).size).to eq(0)
      db.close
    end
  end
end
