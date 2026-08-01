require "./spec_helper"
require "file_utils"

# Exercises the `outline` and `read` subcommands end-to-end by running the built
# binary as a subprocess: what is under test is where the output goes (stdout
# for results, stderr for errors and warnings) and the exit code, neither of
# which is observable from an in-process Admiral run. The binary comes from
# `mise dev:build`, which `mise dev:check` runs before the specs.
Spectator.describe "document CLI subcommands" do
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }
  let(tmp_dir) { "/tmp/mnemodoc-cli-doc-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }
  let(db_path) { File.join(tmp_dir, ".mnemodoc", "index.db") }
  let(doc_path) { File.join(tmp_dir, "guide.md") }

  before_each { Dir.mkdir_p(File.join(tmp_dir, ".mnemodoc")) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Populates the index directly rather than through a crawl: outline and read
  # never embed anything, so requiring a live Ollama to test them would test
  # something else.
  private def write_fixture
    File.write(config_path, "paths:\n  - .\n")
    File.write(doc_path, "# Guide\n\nintro\n\n## Setup\n\nstep one\n")
    store = MnemodocServer::Store::SQLite.new(db_path)
    store.index_file(
      doc_path, File.info(doc_path).modification_time.to_unix,
      [MnemodocServer::Chunk.new(
        file_path: doc_path, heading: "## Setup", parent_heading: "# Guide",
        content: "step one", embedding: Array(Float32).new(768, 0.1_f32),
        token_count: 2, mtime: 1000_i64,
      )],
      text: File.read(doc_path), verbatim: true,
      outline: [
        MnemodocServer::Indexer::OutlineEntry.new(1, "# Guide", 1),
        MnemodocServer::Indexer::OutlineEntry.new(2, "## Setup", 5),
      ],
    )
    store.close
  end

  private def run_cli(args : Array(String))
    out_io = IO::Memory.new
    err_io = IO::Memory.new
    status = Process.run(binary, args + ["--config", config_path], output: out_io, error: err_io)
    {out: out_io.to_s, err: err_io.to_s, code: status.exit_code}
  end

  it "prints the plan as JSON" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_cli(["outline", "guide.md", "--json"])
    expect(result[:code]).to eq(0)
    parsed = JSON.parse(result[:out])
    expect(parsed["sections"].as_a.map(&.["title"].as_s)).to eq(["# Guide", "## Setup"])
    expect(parsed["verbatim"].as_bool).to be_true
  end

  it "prints the plan indented by level in text mode" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_cli(["outline", "guide.md"])
    expect(result[:code]).to eq(0)
    expect(result[:out]).to contain("1\t# Guide")
    expect(result[:out]).to contain("5\t  ## Setup")
  end

  it "prints numbered lines" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_cli(["read", "guide.md", "--offset", "1", "--limit", "2"])
    expect(result[:code]).to eq(0)
    expect(result[:out]).to eq("   1\t# Guide\n   2\t\n")
  end

  it "reports an unknown path on stderr with empty stdout under --json" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_cli(["read", "absent.md", "--json"])
    expect(result[:code]).to eq(1)
    expect(result[:out].strip).to be_empty
    expect(JSON.parse(result[:err])["error"].as_s).to contain("not found in index")
  end

  it "sends the staleness warning to stderr, keeping stdout to the lines" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    File.touch(doc_path, Time.utc + 1.hour)
    result = run_cli(["read", "guide.md", "--limit", "1"])
    expect(result[:code]).to eq(0)
    expect(result[:out]).to eq("   1\t# Guide\n")
    expect(result[:err]).to contain("changed on disk")
  end
end
