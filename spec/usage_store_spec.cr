# spec/usage_store_spec.cr
require "./spec_helper"

Spectator.describe MnemodocServer::Store::Usage do
  let(tmp_db) { "/tmp/mnemodoc-usage-#{Random::Secure.hex(4)}.db" }
  subject(store) { MnemodocServer::Store::SQLite.new(tmp_db) }

  after_each do
    store.close
    delete_db(tmp_db)
  end

  private def event(action : String, at : Int64, files : Array(String),
                    source : String = "tool", results : Int32 = 1,
                    query : String? = "q") : MnemodocServer::Usage::UsageEvent
    MnemodocServer::Usage::UsageEvent.new(
      at: at, source: source, action: action, query: query,
      result_count: results, elapsed_ms: 5, session: nil, agent: nil, files: files,
    )
  end

  private def index(path : String, indexed_at : Int64) : Nil
    store.index_file(
      path, 1000_i64,
      [MnemodocServer::Chunk.new(file_path: path, heading: nil, parent_heading: nil,
        content: "body", embedding: Array(Float32).new(768, 0.1_f32), token_count: 1, mtime: 1000_i64)],
      text: "body\n", verbatim: true, outline: [] of MnemodocServer::Indexer::OutlineEntry,
    )
    store.@db.exec("UPDATE files SET indexed_at = ? WHERE path = ?", indexed_at, path)
  end

  it "stores an event with its served files" do
    store.usage.insert(event("query_documents", 100_i64, ["/docs/a.md", "/docs/b.md"]))
    expect(store.usage.count).to eq(1_i64)
    expect(store.usage.documents(0_i64).map(&.[:path]).sort!).to eq(["/docs/a.md", "/docs/b.md"])
  end

  it "counts how often each document was served, most served first" do
    3.times { |i| store.usage.insert(event("query_documents", (100 + i).to_i64, ["/docs/a.md"])) }
    store.usage.insert(event("read_document", 200_i64, ["/docs/b.md"]))
    documents = store.usage.documents(0_i64)
    expect(documents.first[:path]).to eq("/docs/a.md")
    expect(documents.first[:served]).to eq(3)
    expect(documents.first[:last_at]).to eq(102_i64)
  end

  it "purges past the window and takes the file rows with it" do
    store.usage.insert(event("query_documents", 100_i64, ["/docs/a.md"]))
    store.usage.insert(event("query_documents", 300_i64, ["/docs/b.md"]))
    expect(store.usage.purge(older_than: 200_i64)).to eq(1)
    expect(store.usage.count).to eq(1_i64)
    expect(store.usage.documents(0_i64).map(&.[:path])).to eq(["/docs/b.md"])
  end

  # A document indexed after the window opened cannot be said to have gone
  # unserved for the window: it was not there for all of it.
  it "separates never-served documents from those too recent to judge" do
    index("/docs/old.md", 50_i64)
    index("/docs/fresh.md", 500_i64)
    store.usage.insert(event("query_documents", 600_i64, [] of String, results: 0))

    verdict = store.usage.unused(since: 100_i64)
    expect(verdict[:unused]).to eq(["/docs/old.md"])
    expect(verdict[:too_recent]).to eq(["/docs/fresh.md"])
  end

  it "leaves a served document out of the unused list" do
    index("/docs/old.md", 50_i64)
    store.usage.insert(event("query_documents", 600_i64, ["/docs/old.md"]))
    expect(store.usage.unused(since: 100_i64)[:unused]).to be_empty
  end

  it "lists the calls that returned nothing, with their query" do
    store.usage.insert(event("query_documents", 100_i64, [] of String, results: 0, query: "nothing here"))
    store.usage.insert(event("query_documents", 200_i64, ["/docs/a.md"], results: 1, query: "found"))
    misses = store.usage.misses(0_i64)
    expect(misses.size).to eq(1)
    expect(misses.first[:query]).to eq("nothing here")
  end

  # status, list_files, delete_file and get_project_context serve no document by
  # nature, so they record a zero count. Counting them as misses fills the one
  # view meant to reveal gaps in the corpus with calls that never looked for
  # anything — and an agent calls status and list_files routinely.
  it "leaves out calls that were never searching for a document" do
    store.usage.insert(event("status", 100_i64, [] of String, results: 0, query: nil))
    store.usage.insert(event("list_files", 110_i64, [] of String, results: 0, query: nil))
    store.usage.insert(event("get_project_context", 120_i64, [] of String, results: 0, query: "which role"))
    store.usage.insert(event("query_documents", 130_i64, [] of String, results: 0, query: "real miss"))
    store.usage.insert(event("prompt_hook", 140_i64, [] of String, source: "hook", results: 0, query: "silent"))

    expect(store.usage.misses(0_i64).map(&.[:action])).to eq(["prompt_hook", "query_documents"])
  end

  # The hook staying silent is the one figure no other source can report.
  it "counts silent hooks apart from other empty results" do
    store.usage.insert(event("prompt_hook", 100_i64, [] of String, source: "hook", results: 0))
    store.usage.insert(event("query_documents", 110_i64, [] of String, source: "tool", results: 0))
    summary = store.usage.summary(0_i64)
    expect(summary[:silent_hooks]).to eq(1)
    expect(summary[:events]).to eq(2)
    expect(summary[:by_source]["hook"]).to eq(1)
    expect(summary[:by_action]["query_documents"]).to eq(1)
  end

  it "counts distinct documents served in the window" do
    store.usage.insert(event("query_documents", 100_i64, ["/docs/a.md", "/docs/b.md"]))
    store.usage.insert(event("read_document", 110_i64, ["/docs/a.md"]))
    expect(store.usage.summary(0_i64)[:documents]).to eq(2)
  end

  it "honours the window on every view" do
    store.usage.insert(event("query_documents", 100_i64, ["/docs/old.md"]))
    store.usage.insert(event("query_documents", 900_i64, ["/docs/new.md"]))
    expect(store.usage.documents(500_i64).map(&.[:path])).to eq(["/docs/new.md"])
    expect(store.usage.summary(500_i64)[:events]).to eq(1)
  end
end
