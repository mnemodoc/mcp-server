# spec/backfill_documents_spec.cr
require "./spec_helper"
require "file_utils"

# Rebuilding the stored text and outline for an index built before documents
# were stored. Two properties matter and neither is obvious from the code:
# it must not embed anything, and it must not lose the vectors it rewrites.
Spectator.describe "document backfill" do
  let(root) { File.join(Dir.tempdir, "mnemodoc-backfill-#{Random::Secure.hex(6)}") }
  let(db_path) { File.join(root, "index.db") }
  let(doc_path) { File.join(root, "guide.md") }

  before_each do
    Dir.mkdir_p(root)
    File.write(doc_path, "# Guide\n\n## Setup\n\nRun the thing.\n")
  end

  after_each do
    delete_db(db_path)
    FileUtils.rm_rf(root)
  end

  # Ollama pointed at a dead port: any embedding call raises instead of quietly
  # succeeding, so an example fails loudly if the backfill ever reaches the
  # embedder.
  private def dead_ollama_config(root : String) : MnemodocServer::Config
    MnemodocServer::Config.from_yaml("paths:\n  - #{root}/\nollama:\n  host: http://127.0.0.1:1\n")
  end

  # An index as it looks before this feature: chunks and their vectors are
  # there, the document row is not.
  private def store_without_documents : MnemodocServer::Store::SQLite
    store = MnemodocServer::Store::SQLite.new(db_path)
    store.index_file(
      doc_path, File.info(doc_path).modification_time.to_unix,
      [MnemodocServer::Chunk.new(
        file_path: doc_path, heading: "## Setup", parent_heading: "# Guide",
        content: "Run the thing.", embedding: Array(Float32).new(768, 0.1_f32),
        token_count: 4, mtime: 1000_i64,
      )],
      text: "", verbatim: false, outline: [] of MnemodocServer::Indexer::OutlineEntry,
    )
    store.@db.exec("DELETE FROM documents WHERE file_path = ?", doc_path)
    store
  end

  private def registry_for(config : MnemodocServer::Config) : MnemodocServer::Indexer::Format::Registry
    MnemodocServer::Indexer::Format::Registry.new(config)
  end

  it "rebuilds the document and outline without asking Ollama for anything" do
    store = store_without_documents
    config = dead_ollama_config(root)

    expect(store.files_missing_documents.map(&.[:path])).to eq([doc_path])
    rebuilt = MnemodocServer.backfill_documents!(config, store, registry_for(config))

    expect(rebuilt).to eq(1)
    expect(store.files_missing_documents).to be_empty
    expect(store.document_for(doc_path).try(&.[:text])).to contain("Run the thing.")
    expect(store.document_for(doc_path).try(&.[:verbatim])).to be_true
    expect(store.outline_for(doc_path).map(&.title)).to eq(["# Guide", "## Setup"])
    store.close
  end

  it "leaves the chunk count alone" do
    store = store_without_documents
    config = dead_ollama_config(root)
    before = store.chunk_count

    MnemodocServer.backfill_documents!(config, store, registry_for(config))

    expect(store.chunk_count).to eq(before)
    store.close
  end

  # The trap this spec exists for: chunks_for_files deliberately hands back
  # chunks with an empty embedding, so rewriting them straight through
  # index_file would wipe every vector in the index — search would keep
  # answering, with nothing but the keyword signal behind it.
  it "preserves the embeddings of the chunks it rewrites" do
    store = store_without_documents
    config = dead_ollama_config(root)

    MnemodocServer.backfill_documents!(config, store, registry_for(config))

    vectors = store.embeddings_for_file(doc_path)
    expect(vectors.size).to eq(1)
    expect(vectors.first[:vector].size).to eq(768)
    expect(store.vec_chunk_count).to eq(1_i64)
    store.close
  end

  it "leaves the file's freshness bookkeeping untouched" do
    store = store_without_documents
    config = dead_ollama_config(root)
    mtime = File.info(doc_path).modification_time.to_unix

    MnemodocServer.backfill_documents!(config, store, registry_for(config))

    expect(store.file_indexed?(doc_path, mtime: mtime)).to be_true
    store.close
  end

  it "skips a file that has vanished from disk" do
    store = store_without_documents
    File.delete(doc_path)
    config = dead_ollama_config(root)

    expect(MnemodocServer.backfill_documents!(config, store, registry_for(config))).to eq(0)
    store.close
  end

  it "does nothing when every file already carries a document" do
    store = MnemodocServer::Store::SQLite.new(db_path)
    store.index_file(
      doc_path, 1000_i64,
      [MnemodocServer::Chunk.new(
        file_path: doc_path, heading: nil, parent_heading: nil, content: "body",
        embedding: Array(Float32).new(768, 0.1_f32), token_count: 1, mtime: 1000_i64,
      )],
      text: "body\n", verbatim: true, outline: [] of MnemodocServer::Indexer::OutlineEntry,
    )
    config = dead_ollama_config(root)

    expect(MnemodocServer.backfill_documents!(config, store, registry_for(config))).to eq(0)
    store.close
  end
end
