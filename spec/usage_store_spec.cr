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

# Failures of the prompt hook are recorded, but they are not decisions: the hook
# never reached the similarity gate. Counting them as silences would corrupt the
# silence rate, and listing them as misses would blame the corpus for an outage.
Spectator.describe "usage journal hook outcomes" do
  let(tmp_db) { "/tmp/mnemodoc-usage-outcome-#{Random::Secure.hex(4)}.db" }
  subject(store) { MnemodocServer::Store::SQLite.new(tmp_db) }

  after_each do
    store.close
    delete_db(tmp_db)
  end

  private def hook_event(at : Int64, outcome : String?, query : String? = "q") : MnemodocServer::Usage::UsageEvent
    MnemodocServer::Usage::UsageEvent.new(
      at: at, source: "hook", action: "prompt_hook", query: query,
      result_count: 0, elapsed_ms: 3, session: nil, agent: nil,
      files: [] of String, outcome: outcome)
  end

  it "persists the outcome of an event" do
    store.usage.insert(hook_event(100_i64, "backend_error", query: nil))
    stored = store.@db.scalar("SELECT outcome FROM usage_events").as(String)
    expect(stored).to eq("backend_error")
  end

  it "counts decisions and legacy events as silences, and failures apart" do
    store.usage.insert(hook_event(100_i64, "below_threshold"))
    store.usage.insert(hook_event(110_i64, "no_results"))
    store.usage.insert(hook_event(120_i64, nil))
    store.usage.insert(hook_event(130_i64, "backend_error", query: nil))
    store.usage.insert(hook_event(140_i64, "internal_error", query: nil))
    store.usage.insert(hook_event(150_i64, "invalid_payload", query: nil))
    summary = store.usage.summary(0_i64)
    expect(summary[:silent_hooks]).to eq(3)
    expect(summary[:failed_hooks]).to eq(3)
    expect(summary[:events]).to eq(6)
  end

  it "leaves failed hook calls out of the misses" do
    store.usage.insert(hook_event(100_i64, "no_results", query: "real miss"))
    store.usage.insert(hook_event(110_i64, "backend_error", query: nil))
    misses = store.usage.misses(0_i64)
    expect(misses.map(&.[:query])).to eq(["real miss"])
  end
end

# An index built before the outcome column existed must gain it on open, keep
# every recorded event readable, and read those events as legacy (NULL).
Spectator.describe "usage journal migration" do
  let(tmp_db) { "/tmp/mnemodoc-usage-migrate-#{Random::Secure.hex(4)}.db" }

  after_each { delete_db(tmp_db) }

  it "adds the outcome column to an existing journal without losing events" do
    DB.open("sqlite3://#{tmp_db}") do |database|
      database.exec(<<-SQL)
        CREATE TABLE usage_events (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          at           INTEGER NOT NULL,
          source       TEXT    NOT NULL,
          action       TEXT    NOT NULL,
          query        TEXT,
          result_count INTEGER NOT NULL DEFAULT 0,
          elapsed_ms   INTEGER,
          session      TEXT,
          agent        TEXT
        )
        SQL
      database.exec("INSERT INTO usage_events (at, source, action, query, result_count) VALUES (100, 'hook', 'prompt_hook', 'old', 0)")
    end

    store = MnemodocServer::Store::SQLite.new(tmp_db)
    begin
      columns = [] of String
      store.@db.query("PRAGMA table_info(usage_events)") do |result_set|
        result_set.each do
          result_set.read(Int64)
          columns << result_set.read(String)
          result_set.read(String)
          result_set.read(Int64)
          result_set.read(String?)
          result_set.read(Int64)
        end
      end
      expect(columns).to contain("outcome")
      expect(store.usage.count).to eq(1_i64)
      expect(store.@db.scalar("SELECT outcome FROM usage_events WHERE query = 'old'")).to be_nil
      expect(store.usage.summary(0_i64)[:silent_hooks]).to eq(1)

      store.usage.insert(MnemodocServer::Usage::UsageEvent.new(
        at: 200_i64, source: "hook", action: "prompt_hook", query: nil,
        result_count: 0, elapsed_ms: 1, session: nil, agent: nil,
        files: [] of String, outcome: "backend_error"))
      expect(store.usage.summary(0_i64)[:failed_hooks]).to eq(1)
    ensure
      store.close
    end
  end

  # Two processes open the same index — the daemon and a CLI command — and both
  # run the migration. The second must not fail on the column the first added.
  it "opens an already-migrated journal again without error" do
    MnemodocServer::Store::SQLite.new(tmp_db).close
    expect { MnemodocServer::Store::SQLite.new(tmp_db).close }.not_to raise_error
  end
end
