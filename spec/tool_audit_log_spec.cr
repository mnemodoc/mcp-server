require "./spec_helper"
require "file_utils"

# Every MCP tool must leave a trace at the DEFAULT log level.
#
# The split used to be read versus write rather than anything deliberate: tools
# that changed the index logged at info, tools that read it logged at debug or
# not at all. Since debug is off by default, the entire retrieval half of the
# server — the part worth auditing — was invisible in the log, and checking how
# the documentation was actually used meant reading the client's transcript
# instead.
#
# Exercised through a subprocess speaking MCP over stdio, for two reasons: it
# is the path being audited, and the logger is memoised process-wide
# (@@log_file / @@logger), so an in-process example cannot redirect the log
# after whichever spec ran first already opened it.
Spectator.describe "tool audit log" do
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }
  let(tmp_dir) { "/tmp/mnemodoc-toolaudit-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }
  let(log_path) { File.join(tmp_dir, "server.log") }
  let(db_path) { File.join(tmp_dir, "index.db") }
  let(doc_path) { File.join(tmp_dir, "guide.md") }

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { delete_db(db_path); FileUtils.rm_rf(tmp_dir) }

  # Writes the config and seeds the index directly: what is under test is the
  # logging of tool calls, not indexing, and seeding needs no embedder.
  private def write_fixture
    File.write(doc_path, "# Guide\n\nintro\n\n## Setup\n\nstep one\n")
    # No log_level: the point of this example is what the DEFAULT level shows.
    File.write(config_path, <<-YAML)
    paths:
      - #{tmp_dir}
    db:
      path: #{db_path}
    server:
      log_file: #{log_path}
    YAML
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

  private def call(id : Int32, name : String, arguments) : String
    {jsonrpc: "2.0", id: id, method: "tools/call",
     params: {name: name, arguments: arguments}}.to_json
  end

  # Drives one stdio session through every read-only tool. keyword mode keeps
  # query_documents off Ollama; the embedding call is what the mode skips, not
  # the logging.
  private def run_session
    requests = [
      {jsonrpc: "2.0", id: 1, method: "initialize",
       params: {protocolVersion: "2024-11-05", capabilities: {} of String => String,
                clientInfo: {name: "spec", version: "1"}}}.to_json,
      call(2, "query_documents", {query: "setup", mode: "keyword"}),
      call(3, "list_files", {} of String => String),
      call(4, "status", {} of String => String),
      call(5, "outline_document", {path: doc_path}),
      call(6, "read_document", {path: doc_path, offset: 1, limit: 2}),
    ]
    Process.run(
      binary, ["serve", "--stdio", "--config", config_path],
      env: {"MNEMODOC_SERVER_DAEMON" => "false"},
      input: IO::Memory.new(requests.join('\n') + "\n"),
      output: Process::Redirect::Close, error: Process::Redirect::Close,
    )
    File.read(log_path)
  end

  it "records every read-only tool call at the default level" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    log = run_session

    expect(log).to contain("mnemodoc-server.tools.query")
    expect(log).to contain("mnemodoc-server.tools.list")
    expect(log).to contain("mnemodoc-server.tools.status")
    expect(log).to contain("mnemodoc-server.tools.outline")
    expect(log).to contain("mnemodoc-server.tools.read")
  end

  it "names the document a read and an outline served" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    log = run_session

    expect(log).to contain("guide.md")
    expect(log).to contain("query=\"setup\"")
  end
end
