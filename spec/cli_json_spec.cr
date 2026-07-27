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
    # The crawler is resilient: a file whose embedding fails is logged and
    # skipped rather than aborting the run, so an unreachable Ollama still
    # yields a well-formed payload and exit 0. The path argument resolves
    # against the CWD, not the config directory, hence the absolute path.
    it "emits the index counters" do
      write_config
      stdout, _, status = run_cli("index", File.join(tmp_dir, "doc"), "--config", config_path, "--json")
      expect(status.success?).to be_true
      payload = JSON.parse(stdout)
      expect(payload["indexed"].as_i).to eq(0)
      expect(payload["skipped"].as_i).to eq(0)
      expect(payload["pruned"].as_i).to eq(0)
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
