require "./spec_helper"
require "file_utils"

# Exercises the `usage` subcommand end-to-end by running the built binary, so
# what is under test is where the output goes and the exit code — neither of
# which an in-process Admiral run can show.
Spectator.describe "usage CLI command" do
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }
  let(tmp_dir) { "/tmp/mnemodoc-cli-usage-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }
  let(db_path) { File.join(tmp_dir, ".mnemodoc", "index.db") }

  before_each { Dir.mkdir_p(File.join(tmp_dir, ".mnemodoc")) }
  after_each do
    delete_db(db_path)
    FileUtils.rm_rf(tmp_dir)
  end

  private def write_config
    File.write(config_path, "paths:\n  - #{tmp_dir}\ndb:\n  path: #{db_path}\n")
  end

  private def write_fixture : String
    write_config
    doc = File.join(tmp_dir, "guide.md")
    File.write(doc, "# Guide\n\nbody\n")
    store = MnemodocServer::Store::SQLite.new(db_path)
    store.index_file(
      doc, File.info(doc).modification_time.to_unix,
      [MnemodocServer::Chunk.new(file_path: doc, heading: nil, parent_heading: nil,
        content: "body", embedding: Array(Float32).new(768, 0.1_f32), token_count: 1, mtime: 1000_i64)],
      text: "# Guide\n\nbody\n", verbatim: true,
      outline: [] of MnemodocServer::Indexer::OutlineEntry)
    now = Time.utc.to_unix
    store.usage.insert(MnemodocServer::Usage::UsageEvent.new(
      at: now, source: "tool", action: "query_documents", query: "found it",
      result_count: 1, elapsed_ms: 4, session: nil, agent: nil, files: [doc]))
    store.usage.insert(MnemodocServer::Usage::UsageEvent.new(
      at: now, source: "hook", action: "prompt_hook", query: "nothing here",
      result_count: 0, elapsed_ms: nil, session: nil, agent: nil, files: [] of String))
    store.close
    doc
  end

  private def run_cli(args : Array(String))
    out_io = IO::Memory.new
    err_io = IO::Memory.new
    status = Process.run(binary, ["usage"] + args + ["--config", config_path],
      output: out_io, error: err_io)
    {out: out_io.to_s, err: err_io.to_s, code: status.exit_code}
  end

  it "summarises the window as JSON" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_cli(["--json"])
    expect(result[:code]).to eq(0)
    parsed = JSON.parse(result[:out])
    expect(parsed["events"].as_i).to eq(2)
    expect(parsed["silent_hooks"].as_i).to eq(1)
    expect(parsed["documents"].as_i).to eq(1)
  end

  it "lists the served documents" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    doc = write_fixture
    parsed = JSON.parse(run_cli(["--documents", "--json"])[:out])
    expect(parsed["documents"].as_a.first["path"].as_s).to eq(doc)
    expect(parsed["documents"].as_a.first["served"].as_i).to eq(1)
  end

  it "lists the calls that found nothing" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    parsed = JSON.parse(run_cli(["--misses", "--json"])[:out])
    expect(parsed["misses"].as_a.map(&.["query"].as_s)).to eq(["nothing here"])
  end

  # The three views return different shapes, so merging them would leave the
  # payload with no stable schema. Refusing is the honest answer.
  it "refuses two views at once rather than merging them" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_cli(["--documents", "--misses", "--json"])
    expect(result[:code]).to eq(1)
    expect(result[:out].strip).to be_empty
    expect(JSON.parse(result[:err])["error"].as_s).to contain("one view")
  end

  # Only the daemon imports the spool, so a CLI-only project — or one running
  # with server.daemon: false — would report zeros forever while the file grew.
  # The command therefore drains the spool itself before reading.
  it "imports what was spooled before reporting" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_config
    spool = File.join(tmp_dir, ".mnemodoc", "usage.jsonl")
    event = MnemodocServer::Usage::UsageEvent.new(
      at: Time.utc.to_unix, source: "cli", action: "query_documents", query: "spooled",
      result_count: 1, elapsed_ms: 2, session: nil, agent: nil, files: ["/docs/a.md"])
    File.write(spool, "#{event.to_json}\n")

    parsed = JSON.parse(run_cli(["--json"])[:out])
    expect(parsed["events"].as_i).to eq(1)
    expect(File.exists?(spool)).to be_false
  end

  it "reports zeros on an empty journal rather than failing" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_config
    result = run_cli(["--json"])
    expect(result[:code]).to eq(0)
    expect(JSON.parse(result[:out])["events"].as_i).to eq(0)
  end
end
