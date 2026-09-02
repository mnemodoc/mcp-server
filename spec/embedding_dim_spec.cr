require "./spec_helper"

# Raises inside the index_file transaction, after the files row is written, so
# the whole write rolls back — including any schema change the write made.
private class RollbackStore < MnemodocServer::Store::SQLite
  class Boom < Exception
  end

  protected def after_chunk_write(path : String) : Nil
    raise Boom.new("forced rollback")
  end
end

# The embedding dimension is a property of the model, never a constant: vec0
# freezes it in the virtual table's DDL, so changing models is a lifecycle
# (drop, recreate, re-embed) and not a setting. These examples pin that
# lifecycle, and above all pin that a divergence is a hard, readable failure
# rather than one skipped vector per chunk.
Spectator.describe "embedding dimension lifecycle" do
  let(tmp_db) { File.join(Dir.tempdir, "mnemodoc-dim-#{Random::Secure.hex(4)}.db") }
  # Every store this example opened, closed by the teardown rather than by the
  # example body: an example that fails an expectation mid-way leaves its
  # connection open otherwise, and SQLite writes the WAL files straight back
  # after delete_db has removed them.
  let(opened) { [] of MnemodocServer::Store::SQLite }

  after_each do
    opened.each { |store| store.close rescue nil }
    delete_db(tmp_db)
  end

  private def make_store(path : String, vec0 : Bool = true) : MnemodocServer::Store::SQLite
    store = MnemodocServer::Store::SQLite.new(path, vec0: vec0)
    opened << store
    store
  end

  private def vec(dim : Int32, seed : Float32 = 0.1_f32) : Array(Float32)
    Array(Float32).new(dim, seed)
  end

  private def store_chunk(store : MnemodocServer::Store::SQLite, path : String,
                          embedding : Array(Float32)) : Nil
    mtime = Time.utc.to_unix
    store.upsert_file(path, mtime: mtime)
    store.save_chunks([MnemodocServer::Chunk.new(
      file_path: path, heading: nil, parent_heading: nil,
      content: "body of #{path}", embedding: embedding, token_count: 1, mtime: mtime
    )])
  end

  describe "adoption" do
    it "has no dimension and no vec table on a fresh index" do
      store = make_store(tmp_db)
      expect(store.embedding_dim).to be_nil
      expect(store.vec_table_dim).to be_nil
    end

    # The whole point of task 1: the size comes from a vector that Ollama really
    # produced, never from a model -> dimension table that would lie the day a
    # model changes size between two releases.
    it "adopts the dimension of the first embedding actually written" do
      store = make_store(tmp_db)
      store_chunk(store, "/a.md", vec(1024))
      expect(store.embedding_dim).to eq(1024)
      expect(store.vec_table_dim).to eq(1024)
      expect(store.vec_chunk_count).to eq(1)
    end

    it "serves KNN at the adopted dimension" do
      store = make_store(tmp_db)
      store_chunk(store, "/a.md", vec(1024, 0.1_f32))
      store_chunk(store, "/b.md", vec(1024, 0.9_f32))
      results = store.knn_chunks(vec(1024, 0.1_f32), limit: 2)
      expect(results.size).to eq(2)
      expect(results.first[:chunk].file_path).to eq("/a.md")
    end

    it "adopts through prepare_embedding_dim! before anything is indexed" do
      store = make_store(tmp_db)
      store.prepare_embedding_dim!(1024)
      expect(store.embedding_dim).to eq(1024)
      expect(store.vec_table_dim).to eq(1024)
    end

    # A chunk whose embedding failed carries an empty vector: it is indexed for
    # keyword search and simply has nothing to put in vec0. That is not a
    # mismatch and must not raise.
    it "skips an empty embedding without adopting or raising" do
      store = make_store(tmp_db)
      store_chunk(store, "/a.md", [] of Float32)
      expect(store.embedding_dim).to be_nil
      expect(store.chunk_count).to eq(1)
    end
  end

  describe "divergence" do
    it "refuses a write whose dimension differs from the adopted one" do
      store = make_store(tmp_db)
      store_chunk(store, "/a.md", vec(768))
      expect { store_chunk(store, "/b.md", vec(1024)) }
        .to raise_error(MnemodocServer::Store::EmbeddingDimMismatch, /768/)
    end

    it "refuses prepare_embedding_dim! against a different recorded dimension" do
      store = make_store(tmp_db)
      store.prepare_embedding_dim!(768)
      expect { store.prepare_embedding_dim!(1024) }
        .to raise_error(MnemodocServer::Store::EmbeddingDimMismatch, /re-index/)
    end

    # The query side of the same failure: searching a 768-dim index with a
    # 1024-dim query used to fall through to keyword results wearing the name
    # "hybrid". It must say so instead.
    it "refuses a KNN query vector of the wrong dimension" do
      store = make_store(tmp_db)
      store_chunk(store, "/a.md", vec(768))
      expect { store.knn_chunks(vec(1024), limit: 5) }
        .to raise_error(MnemodocServer::Store::EmbeddingDimMismatch, /1024/)
    end

    it "returns nothing from KNN while no dimension is known" do
      store = make_store(tmp_db)
      expect(store.knn_chunks(vec(768), limit: 5)).to be_empty
    end
  end

  describe "migration of an existing index" do
    # An index built by an earlier version has the float[768] table but no
    # meta row. Its dimension is readable from the DDL, and recording it is
    # what lets every later check compare against something.
    it "adopts the dimension of a legacy vec table that predates the meta row" do
      store = make_store(tmp_db)
      store_chunk(store, "/a.md", vec(768))

      DB.open("sqlite3://#{tmp_db}") do |conn|
        conn.exec("DELETE FROM meta WHERE key = 'embedding_dim'")
      end

      reopened = make_store(tmp_db)
      expect(reopened.embedding_dim).to eq(768)
      expect(reopened.knn_chunks(vec(768), limit: 1).size).to eq(1)
    end

    # The reverse case: the meta row survives but the virtual table does not.
    # That is exactly an index built under the qdrant backend, which stores the
    # embedding BLOBs and no vec0 table at all. Switching back to vec0 must
    # rebuild the table at the recorded size and refill it from those BLOBs.
    it "recreates a missing vec table at the recorded dimension and backfills it" do
      qdrant_side = make_store(tmp_db, vec0: false)
      store_chunk(qdrant_side, "/a.md", vec(1024))
      expect(qdrant_side.embedding_dim).to eq(1024)
      expect(qdrant_side.vec_table_dim).to be_nil

      reopened = make_store(tmp_db)
      expect(reopened.vec_table_dim).to eq(1024)
      expect(reopened.vec_chunk_count).to eq(1)
    end
  end

  # Only reachable by editing the database by hand, but the choice it forces is
  # worth pinning: the table constrains writes absolutely, the meta row does
  # not, so the table wins and the row is corrected — rather than the index
  # refusing to open at all, which would take the read-only tools down with it.
  describe "disagreement between the metadata and the table" do
    it "trusts the table's declared width and corrects the metadata" do
      store = make_store(tmp_db)
      store_chunk(store, "/a.md", vec(1024))

      DB.open("sqlite3://#{tmp_db}") do |conn|
        conn.exec("UPDATE meta SET value = '768' WHERE key = 'embedding_dim'")
      end

      reopened = make_store(tmp_db)
      expect(reopened.embedding_dim).to eq(1024)
      expect(reopened.vec_table_dim).to eq(1024)

      again = make_store(tmp_db)
      expect(again.embedding_dim).to eq(1024)
    end
  end

  # Regressions caught in review, both of them states the happy path never
  # reaches and neither of which announces itself.
  describe "consistency of the in-memory state" do
    # The vec0 table is dropped and recreated per dimension, so "does it exist"
    # and "which backend am I" are two different questions. Conflating them
    # skipped the purge for a qdrant-backed store that still carried a vec0
    # table from a previous backend, leaving rowids behind that a later switch
    # back to vec0 would serve as missing results.
    it "purges the vec table on delete even under the qdrant backend" do
      vec_side = make_store(tmp_db)
      store_chunk(vec_side, "/a.md", vec(1024))
      expect(vec_side.vec_chunk_count).to eq(1)
      vec_side.close

      qdrant_side = make_store(tmp_db, vec0: false)
      qdrant_side.delete_file("/a.md")
      qdrant_side.close

      # Observed from a vec0 store, since the qdrant-side one reports no vector
      # count of its own: the row must be gone, not merely invisible.
      back_on_vec0 = make_store(tmp_db)
      expect(back_on_vec0.chunk_count).to eq(0)
      expect(back_on_vec0.vec_chunk_count).to eq(0)
    end

    # The adoption writes a DDL statement and a meta row. Performed inside the
    # caller's transaction, a rollback undid both while the in-memory width
    # survived — after which the store believed in a table that no longer
    # existed and every following write died on `no such table: vec_chunks`.
    it "survives a rolled-back write without believing in a table that is gone" do
      store = RollbackStore.new(tmp_db)
      opened << store
      mtime = Time.utc.to_unix
      chunk = MnemodocServer::Chunk.new(
        file_path: "/rolled-back.md", heading: nil, parent_heading: nil,
        content: "body", embedding: vec(1024), token_count: 1, mtime: mtime)

      expect { store.index_file("/rolled-back.md", mtime, [chunk], text: "body", verbatim: true, outline: [] of MnemodocServer::Indexer::OutlineEntry) }
        .to raise_error(RollbackStore::Boom)

      # The next write must succeed: whatever the store thinks its width is, the
      # table it points at has to exist.
      store_chunk(store, "/after.md", vec(1024))
      expect(store.vec_chunk_count).to eq(1)
      expect(store.embedding_dim).to eq(1024)
    end
  end

  # The probe's contract is narrow on purpose: it either learns a width or it
  # does not, and only a mismatch escapes. A model answering 200 with an empty
  # embeddings array is a case Embedder#embed_many deliberately tolerates, so
  # the probe must not turn it into an unhandled Enumerable::EmptyError that
  # every caller's `rescue EmbedderError` walks straight past.
  describe ".probe_embedding_dim!" do
    # Wraps the raw body in the full config the probe now takes: it consults
    # the configured model name before deciding whether to ask anything.
    private def probe_config(port : Int32) : MnemodocServer::Config
      MnemodocServer::Config.from_yaml(
        "paths:\n  - /nonexistent\nollama:\n  host: http://127.0.0.1:#{port}\n")
    end

    private def ollama_returning(body : String, &)
      server = HTTP::Server.new do |ctx|
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        ctx.response.print(body)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield
      begin
        yield addr.port
      ensure
        server.close
      end
    end

    it "returns nil when the model answers with no embedding at all" do
      store = make_store(tmp_db)
      ollama_returning(%({"embeddings": []})) do |port|
        config = probe_config(port)
        embedder = MnemodocServer::Indexer::Embedder.new(config.ollama)
        begin
          expect(MnemodocServer.probe_embedding_dim!(config, store, embedder)).to be_nil
          expect(store.embedding_dim).to be_nil
        ensure
          embedder.close
        end
      end
    end

    it "adopts the width the model actually returns" do
      store = make_store(tmp_db)
      row = Array(Float32).new(1024, 0.1_f32).to_json
      ollama_returning(%({"embeddings": [#{row}]})) do |port|
        config = probe_config(port)
        embedder = MnemodocServer::Indexer::Embedder.new(config.ollama)
        begin
          expect(MnemodocServer.probe_embedding_dim!(config, store, embedder)).to eq(1024)
          expect(store.embedding_dim).to eq(1024)
        ensure
          embedder.close
        end
      end
    end
  end

  # Two properties the CI caught the hard way: the probe must not become a
  # network call on paths that had none, and the refusal must not become a
  # per-file counter once the crawler is the one to meet it.
  describe "the probe" do
    private def counting_ollama(dims : Int32, calls : Array(String), &)
      row = Array(Float32).new(dims, 0.1_f32)
      server = HTTP::Server.new do |ctx|
        body = ctx.request.body.try(&.gets_to_end) || ""
        calls << body
        count = (JSON.parse(body)["input"].as_a.size rescue 1)
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        ctx.response.print({"embeddings" => Array.new(count, row)}.to_json)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield
      begin
        yield addr.port
      ensure
        server.close
      end
    end

    it "asks the model nothing when the index already records a width for it" do
      calls = [] of String
      counting_ollama(768, calls) do |port|
        config = MnemodocServer::Config.from_yaml(
          "paths:\n  - /nonexistent\nollama:\n  host: http://127.0.0.1:#{port}\n  model: fixed-model\n")
        store = make_store(tmp_db)
        embedder = MnemodocServer::Indexer::Embedder.new(config.ollama)
        begin
          # First call: nothing recorded, so the width has to be measured.
          expect(MnemodocServer.probe_embedding_dim!(config, store, embedder)).to eq(768)
          store.embedding_model = "fixed-model"
          expect(calls.size).to eq(1)

          # Second call: same model, width already recorded. Nothing can have
          # changed, so nothing is asked.
          expect(MnemodocServer.probe_embedding_dim!(config, store, embedder)).to eq(768)
          expect(calls.size).to eq(1)
        ensure
          embedder.close
        end
      end
    end

    it "measures again once the configured model has changed" do
      calls = [] of String
      counting_ollama(768, calls) do |port|
        config = MnemodocServer::Config.from_yaml(
          "paths:\n  - /nonexistent\nollama:\n  host: http://127.0.0.1:#{port}\n  model: new-model\n")
        store = make_store(tmp_db)
        store.prepare_embedding_dim!(768)
        store.embedding_model = "old-model"
        embedder = MnemodocServer::Indexer::Embedder.new(config.ollama)
        begin
          expect(MnemodocServer.probe_embedding_dim!(config, store, embedder)).to eq(768)
          expect(calls.size).to eq(1)
        ensure
          embedder.close
        end
      end
    end
  end

  describe "#clear_index!" do
    # Clearing is what the model-change path runs before a full rebuild, so it
    # must release the dimension too: otherwise the next model's vectors meet a
    # table frozen at the old size, which is the original failure.
    it "releases the dimension so the next model can impose its own" do
      store = make_store(tmp_db)
      store_chunk(store, "/a.md", vec(768))
      store.clear_index!
      expect(store.embedding_dim).to be_nil
      expect(store.vec_table_dim).to be_nil

      store_chunk(store, "/b.md", vec(1024))
      expect(store.embedding_dim).to eq(1024)
      expect(store.vec_chunk_count).to eq(1)
    end
  end
end
