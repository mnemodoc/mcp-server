require "./spec_helper"
require "file_utils"

# Exercises the machine-readable output contract through the compiled binary,
# so flag parsing, payload shape and exit codes are all covered end to end.
# Nothing here reaches Ollama: the embedding host points at a closed port, and
# the examples that would need embeddings assert the error path instead.
Spectator.describe "CLI machine output" do
  let(tmp_dir) { "/tmp/mnemodoc-cli-json-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }

  before_each do
    Dir.mkdir_p(File.join(tmp_dir, "doc"))
    File.write(File.join(tmp_dir, "doc", "a.md"), "# Title\n\n## Section\n\nSome body text.\n")
  end
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Ollama is deliberately unreachable; only commands that never embed succeed.
  private def write_config(daemon : Bool = false, roles : Bool = false) : Nil
    context_block = roles ? <<-CTX : ""

    context:
      default: doc/a.md
      roles:
        - file: doc/a.md
          when_files: ["**/*.md"]
    CTX

    File.write(config_path, <<-YAML + context_block)
    paths:
      - doc/
    ollama:
      host: http://127.0.0.1:1
    server:
      log_level: error
      daemon: #{daemon}
      daemon_watch: false
    YAML
  end

  private def run_cli(*args : String)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("./bin/mnemodoc-server", args.to_a, output: stdout, error: stderr)
    {stdout.to_s, stderr.to_s, status}
  end

  describe "--json payloads" do
    # The crawler stays resilient — a file whose embedding fails is logged and
    # skipped rather than aborting the run — so the payload is well formed even
    # with Ollama unreachable. The exit code is not 0 though: a run that
    # embedded nothing at all, having tried, is a failed run, and reporting
    # success there is how a deployment script comes to believe a broken index
    # is current. The path argument resolves against the CWD, not the config
    # directory, hence the absolute path.
    it "emits the index counters, and fails when nothing could be indexed" do
      write_config
      stdout, stderr, status = run_cli("index", File.join(tmp_dir, "doc"), "--config", config_path, "--json")
      expect(status.success?).to be_false
      payload = JSON.parse(stdout)
      expect(payload["indexed"].as_i).to eq(0)
      expect(payload["skipped"].as_i).to eq(0)
      expect(payload["pruned"].as_i).to eq(0)
      expect(payload["failed"].as_i).to be > 0
      # Errors stay on stderr and stay JSON under --json, so a consumer parsing
      # stdout never has to tell a result from a failure.
      expect(JSON.parse(stderr)["error"].as_s).to contain("nothing could be indexed")
    end

    it "emits the index status" do
      write_config
      stdout, _, status = run_cli("status", "--config", config_path, "--json")
      expect(status.success?).to be_true
      payload = JSON.parse(stdout)
      expect(payload["version"].as_s).not_to be_empty
      expect(payload["db_path"].as_s).to contain(".mnemodoc")
      expect(payload["files"].as_i).to eq(0)
      expect(payload["chunks"].as_i).to eq(0)
      expect(payload["ollama"]["model"].as_s).not_to be_empty
      # null rather than absent: an empty index has no width yet, and the key
      # being there is what lets a script tell "not embedded" from "old payload".
      expect(payload["embedding_dim"].raw).to be_nil
    end

    it "reports a delete miss without failing" do
      write_config
      stdout, _, status = run_cli("delete", "doc/missing.md", "--config", config_path, "--json")
      expect(status.success?).to be_true
      payload = JSON.parse(stdout)
      expect(payload["found"].as_bool).to be_false
      expect(payload["path"].as_s).to contain("missing.md")
    end

    it "emits version and compiler info" do
      stdout, _, status = run_cli("info", "--json")
      expect(status.success?).to be_true
      payload = JSON.parse(stdout)
      expect(payload["version"].as_s).not_to be_empty
      expect(payload["crystal"].as_s).to contain("Crystal")
      # The provenance detail lives in `info`, not in the one-line banner.
      # Added keys, never renamed ones: the payload contract is additive.
      expect(payload["commit"].as_s).not_to be_empty
      expect(payload["target"].as_s).to contain("/")
      expect(payload["built"].as_s).to contain("T")
      # `tag` is legitimately "unknown" on a repository with no tag at all, so
      # the contract is the key's presence, not its value.
      expect(payload.as_h.has_key?("tag")).to be_true
    end

    it "emits the selected role" do
      write_config(roles: true)
      stdout, _, status = run_cli("context", "--config", config_path, "--files", "doc/a.md", "--json")
      expect(status.success?).to be_true
      payload = JSON.parse(stdout)
      expect(payload["role"].as_s).not_to be_empty
      expect(payload["reason"].as_s).not_to be_empty
      expect(payload["content"].as_s).to contain("Title")
      expect(payload["suppressed"].as_bool).to be_false
    end

    it "emits the daemon status" do
      write_config(daemon: true)
      stdout, _, status = run_cli("daemon", "status", "--config", config_path, "--json")
      # Exit 1 because no daemon is running, like `systemctl is-active`.
      expect(status.success?).to be_false
      payload = JSON.parse(stdout)
      expect(payload["running"].as_bool).to be_false
      expect(payload["daemon_enabled"].as_bool).to be_true
      expect(payload["socket"].as_s).to contain("daemon.sock")
    end

    it "emits the daemon stop outcome" do
      write_config(daemon: true)
      stdout, _, status = run_cli("daemon", "stop", "--config", config_path, "--json")
      expect(status.success?).to be_true
      payload = JSON.parse(stdout)
      expect(payload["stopped"].as_bool).to be_false
      expect(payload["reason"].as_s).not_to be_empty
    end
  end

  describe "--quiet" do
    it "prints nothing on a delete miss" do
      write_config
      stdout, _, status = run_cli("delete", "doc/missing.md", "--config", config_path, "--quiet")
      expect(stdout).to be_empty
      # Exit code deliberately unchanged from the pre-flag behaviour.
      expect(status.success?).to be_true
    end

    it "prints nothing and exits 1 when no daemon runs" do
      write_config(daemon: true)
      stdout, _, status = run_cli("daemon", "status", "--config", config_path, "--quiet")
      expect(stdout).to be_empty
      expect(status.success?).to be_false
    end

    it "prints nothing when stopping an absent daemon" do
      write_config(daemon: true)
      stdout, _, status = run_cli("daemon", "stop", "--config", config_path, "--quiet")
      expect(stdout).to be_empty
      expect(status.success?).to be_true
    end
  end

  describe "error path" do
    it "keeps stdout empty and reports the failure on stderr" do
      write_config
      stdout, stderr, status = run_cli("search", "anything", "--config", config_path, "--json")
      expect(status.success?).to be_false
      expect(stdout).to be_empty
      expect(JSON.parse(stderr)["error"].as_s).to contain("Ollama")
    end
  end

  describe "search payload" do
    # Mock Ollama returning a fixed 768-dim vector, so the results array — the
    # one payload the unreachable-host examples cannot reach — is covered.
    private def with_mock_ollama(&)
      embedding = Array(Float32).new(768, 0.1_f32)
      server = HTTP::Server.new do |ctx|
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        body = ctx.request.body.try(&.gets_to_end) || ""
        count = JSON.parse(body)["input"].as_a.size rescue 1
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
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

    private def write_search_config(port : Int32, model : String) : Nil
      File.write(config_path, <<-YAML)
      paths:
        - doc/
      ollama:
        host: http://127.0.0.1:#{port}
        model: #{model}
      server:
        log_level: error
        daemon: false
        daemon_watch: false
      YAML
    end

    # A keyword answer under a changed model is honest — it touches no vector —
    # but it is missing the semantic half, and the CLI said nothing about it.
    # The MCP tool carried the warning from the start; this surface reimplements
    # the search path rather than delegating, and the message was never written
    # here, so `search --mode keyword` returned its table as if the index were
    # current.
    describe "a keyword answer on an index built by another model" do
      it "carries the warning in the --json payload" do
        with_mock_ollama do |port|
          write_search_config(port, "model-a")
          _, _, status = run_cli("index", File.join(tmp_dir, "doc"), "--config", config_path)
          expect(status.success?).to be_true

          write_search_config(port, "model-b")
          stdout, _, status = run_cli("search", "body", "--mode", "keyword", "--config", config_path, "--json")
          expect(status.success?).to be_true

          warnings = JSON.parse(stdout)["warnings"].as_a.map(&.as_s)
          expect(warnings.size).to eq(1)
          expect(warnings.first).to contain("model-a")
          expect(warnings.first).to contain("model-b")
          expect(warnings.first).to contain("keyword signal only")
        end
      end

      # stdout stays the result and nothing else, as it does for `read`: a
      # caller piping the table must not find prose in it.
      it "puts the warning on stderr and leaves stdout to the results" do
        with_mock_ollama do |port|
          write_search_config(port, "model-a")
          run_cli("index", File.join(tmp_dir, "doc"), "--config", config_path)

          write_search_config(port, "model-b")
          stdout, stderr, status = run_cli("search", "body", "--mode", "keyword", "--config", config_path)
          expect(status.success?).to be_true
          expect(stderr).to contain("keyword signal only")
          expect(stdout).not_to contain("keyword signal only")
        end
      end

      # Nothing to say when the model is the one the index was built with.
      it "says nothing when the model still matches" do
        with_mock_ollama do |port|
          write_search_config(port, "model-a")
          run_cli("index", File.join(tmp_dir, "doc"), "--config", config_path)

          stdout, stderr, status = run_cli("search", "body", "--mode", "keyword", "--config", config_path, "--json")
          expect(status.success?).to be_true
          expect(JSON.parse(stdout)["warnings"].as_a).to be_empty
          expect(stderr).not_to contain("keyword signal only")
        end
      end
    end

    # Keyword search touches no vector, so it must not need the service that
    # produces them. Two things rest on that: CLAUDE.md makes "the read-only
    # tools, keyword search and init all work with Ollama down" the reason the
    # dimension is probed at the start of an indexing run rather than at store
    # open; and keyword is the fallback the refusal message recommends — one
    # that requires the service just found wanting is not a fallback.
    it "answers a keyword search from the index alone when Ollama is unreachable" do
      with_mock_ollama do |port|
        write_search_config(port, "model-a")
        _, _, status = run_cli("index", File.join(tmp_dir, "doc"), "--config", config_path)
        expect(status.success?).to be_true
      end

      # The mock is gone; port 1 is nothing at all.
      write_search_config(1, "model-a")
      stdout, stderr, status = run_cli("search", "body", "--mode", "keyword", "--config", config_path, "--json")

      expect(status.success?).to be_true
      expect(stderr).not_to contain("Ollama")
      expect(JSON.parse(stdout)["results"].as_a.size).to be > 0
    end

    it "mirrors the query_documents key vocabulary" do
      with_mock_ollama do |port|
        File.write(config_path, <<-YAML)
        paths:
          - doc/
        ollama:
          host: http://127.0.0.1:#{port}
        server:
          log_level: error
          daemon: false
          daemon_watch: false
        YAML

        _, _, index_status = run_cli("index", File.join(tmp_dir, "doc"), "--config", config_path, "--quiet")
        expect(index_status.success?).to be_true

        stdout, _, status = run_cli("search", "body", "--config", config_path, "--json")
        expect(status.success?).to be_true
        payload = JSON.parse(stdout)
        expect(payload["query"].as_s).to eq("body")
        expect(payload["mode"].as_s).not_to be_empty
        first = payload["results"].as_a.first
        # A superset, not an exact match: the payload contract is additive, so
        # asserting equality here would forbid the very additions it allows.
        # What must hold is that the query_documents vocabulary is all present.
        %w[file heading parent_heading content score].each do |key|
          expect(first.as_h.has_key?(key)).to be_true
        end
        expect(first["content"].as_s).to contain("Some body text")
      end
    end
  end
end
