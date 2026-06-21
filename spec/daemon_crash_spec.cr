require "./spec_helper"
require "db"
require "sqlite3"
require "file_utils"

# Verifies that a `kill -9` of the daemon DURING indexing leaves the reopened
# index consistent: the file whose per-file transaction committed before the
# kill survives, the file that was mid-flight (uncommitted) is entirely absent,
# and the database opens clean (PRAGMA integrity_check = ok, no orphan chunks).
#
# The daemon is driven as a REAL subprocess (`serve --daemon`) so the kill is a
# genuine SIGKILL of a separate process — the only faithful way to prove WAL
# crash-safety. Determinism comes from a mock embeddings server that hands the
# test a Channel: it answers the FIRST file's request normally (so file 1
# commits) and, on the SECOND file's request, signals the test and then BLOCKS
# forever (so the daemon is provably stuck inside file 2's uncommitted work when
# the kill lands). No fixed sleeps are used for synchronisation; every wait is
# bounded so the test cannot hang.
Spectator.describe "daemon crash resilience" do
  # Path to the dev binary, resolved relative to this spec file. Produced by
  # `mise dev:build`, which `mise dev:check` runs before the specs.
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }
  let(tmp_dir) { "/tmp/mnemodoc-daemon-crash-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }
  let(db_path) { File.join(tmp_dir, "index.db") }

  # Upper bound on every blocking wait so a regression can never hang the suite.
  WAIT_TIMEOUT = 30.seconds

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Starts the mock embeddings server bound to an ephemeral port. It mimics
  # Ollama's `POST /api/embed` contract used by Embedder#embed_many: request
  # body `{model, input: [...]}`, response `{embeddings: [[...]]}`.
  #
  # The first request is answered with a valid 768-dim embedding so the daemon
  # commits file 1. The second request pushes nil onto *second_request* (proof
  # that file 1 is committed and file 2 is now mid-flight) and then blocks the
  # connection fiber forever, keeping the daemon inside file 2's uncommitted
  # work until the test kills it. Yields the bound port to the block and closes
  # the server on the way out.
  private def with_blocking_mock(second_request : Channel(Nil), &)
    request_count = 0
    request_mutex = Mutex.new
    embedding = Array.new(768, 0.1_f32)

    server = HTTP::Server.new do |ctx|
      body = ctx.request.body.try(&.gets_to_end) || ""
      count = JSON.parse(body)["input"].as_a.size rescue 1

      ordinal = request_mutex.synchronize { request_count += 1 }
      if ordinal == 1
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      else
        # Second file is mid-flight: tell the test, then never respond so the
        # daemon stays blocked inside this uncommitted transaction's prelude.
        second_request.send(nil)
        sleep
      end
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

  # Writes the project config and two markdown files. They are named so the
  # crawler's path sort yields a deterministic order (aaa before bbb), and
  # index.concurrency is 1 so files are embedded sequentially — the second
  # request therefore always belongs to the second file.
  private def write_fixture(port : Int32)
    File.write(
      File.join(tmp_dir, "aaa.md"),
      "# First\n\n## Section\n\nThis is the first file's body content."
    )
    File.write(
      File.join(tmp_dir, "bbb.md"),
      "# Second\n\n## Section\n\nThis is the second file's body content."
    )
    File.write(config_path, <<-YAML)
    paths:
      - #{tmp_dir}
    ollama:
      host: http://127.0.0.1:#{port}
      model: test
    index:
      concurrency: 1
    db:
      path: #{db_path}
    server:
      daemon_idle_timeout: 5
      log_file: #{File.join(tmp_dir, "daemon.log")}
    YAML
  end

  # Receives from a channel within WAIT_TIMEOUT, failing the test (instead of
  # hanging) when nothing arrives in time.
  private def receive_within(channel : Channel(Nil), what : String)
    select
    when channel.receive
      # ok
    when timeout(WAIT_TIMEOUT)
      fail "timed out after #{WAIT_TIMEOUT} waiting for #{what}"
    end
  end

  # Runs `PRAGMA integrity_check` on a fresh connection to the given DB file and
  # returns the single-row result (expected "ok").
  private def integrity_check(path : String) : String
    db = DB.open("sqlite3://#{path}")
    begin
      db.query_one("PRAGMA integrity_check", as: String)
    ensure
      db.close
    end
  end

  it "rolls back the uncommitted file when kill -9 lands mid-indexing" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)

    second_request = Channel(Nil).new

    with_blocking_mock(second_request) do |port|
      write_fixture(port)

      # Launch the real daemon as a subprocess. Its stdout/stderr are discarded;
      # the daemon logs to the configured log_file, so nothing blocks on pipes.
      process = Process.new(
        binary,
        ["serve", "--daemon", "--config", config_path],
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      )

      begin
        # Block until the daemon requests the SECOND file's embedding. This is
        # the synchronisation point: file 1 is committed, file 2 is uncommitted.
        receive_within(second_request, "the second file's embedding request")

        # Kill -9 while file 2's transaction has not been written.
        process.terminate(graceful: false)
        process.wait
      ensure
        # Belt-and-braces: ensure no daemon survives even if an assertion above
        # raised before the kill.
        process.terminate(graceful: false) rescue nil
        process.wait rescue nil
      end

      # Reopen the index in-process and assert consistency.
      expect(integrity_check(db_path)).to eq("ok")

      store = MnemodocServer::Store::SQLite.new(db_path, vec0: true)
      begin
        listed = store.list_files
        basenames = listed.map { |file_info| File.basename(file_info.path) }

        # File 1 committed before the crash: present with at least one chunk.
        expect(basenames).to contain("aaa.md")
        aaa = listed.find! { |file_info| File.basename(file_info.path) == "aaa.md" }
        expect(aaa.chunk_count).to be >= 1

        # File 2 was mid-flight: its transaction rolled back, so it is absent
        # from files AND leaves no chunks behind (no orphans).
        expect(basenames).not_to contain("bbb.md")

        bbb_path = File.join(tmp_dir, "bbb.md")
        orphan_chunks = store.chunk_ids_for_file(bbb_path)
        expect(orphan_chunks).to be_empty

        # The store is fully queryable; total chunks equal file 1's chunks only.
        expect(store.chunk_count).to eq(aaa.chunk_count.to_i64)
      ensure
        store.close
      end
    end
  end
end
