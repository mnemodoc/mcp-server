require "./spec_helper"
require "file_utils"

# Exercises the `context` CLI subcommand end-to-end by running the built binary
# as a subprocess. A subprocess is used (rather than an in-process Admiral run)
# because the command writes the role markdown to the real STDOUT and signals
# failures with a non-zero process exit — both contracts only observable from
# outside the process. The binary is produced by `mise dev:build`, which
# `mise dev:check` runs before the specs.
Spectator.describe "context CLI command" do
  # Path to the dev binary, resolved relative to this spec file.
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }
  let(tmp_dir) { "/tmp/mnemodoc-cli-context-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  let(log_path) { File.join(tmp_dir, "context.log") }

  # Writes a config whose context section declares two file-glob roles and no
  # default, then drops their markdown files next to it so role paths resolve.
  # The server.log_file points to log_path so tests can assert on audit output.
  private def write_fixture
    File.write(File.join(tmp_dir, "crystal.md"), "# Crystal role\nUse idiomatic Crystal.")
    File.write(File.join(tmp_dir, "rails.md"), "# Rails role\nFollow Rails conventions.")
    File.write(config_path, <<-YAML)
    server:
      log_file: #{log_path}
    context:
      roles:
        - file: crystal.md
          when_files: ["**/*.cr"]
        - file: rails.md
          when_files: ["**/*.rb"]
    YAML
  end

  # Runs the binary's `context` subcommand and returns stdout, stderr, and the
  # process exit code.
  private def run_context(args : Array(String))
    out_io = IO::Memory.new
    err_io = IO::Memory.new
    status = Process.run(binary, ["context"] + args, output: out_io, error: err_io)
    {out: out_io.to_s, err: err_io.to_s, code: status.exit_code}
  end

  it "prints the decisively selected role's markdown to stdout with exit 0" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_context(["--config", config_path, "--files", "src/foo.cr"])
    expect(result[:code]).to eq(0)
    expect(result[:out]).to contain("Crystal role")
    expect(result[:out]).not_to contain("Rails role")
  end

  it "writes an audit line with role name and reason to the log file" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    run_context(["--config", config_path, "--files", "src/foo.cr"])
    log_content = File.read(log_path)
    expect(log_content).to contain("mnemodoc-server.context")
    expect(log_content).to contain("role=crystal")
  end

  it "writes an error to stderr and exits non-zero when there is no signal" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_context(["--config", config_path])
    expect(result[:code]).not_to eq(0)
    expect(result[:err]).to contain("Error:")
    expect(result[:out]).to be_empty
  end

  # Runs `context` with a JSON payload piped on stdin (hook stdin mode).
  private def run_context_stdin(args : Array(String), stdin : String)
    out_io = IO::Memory.new
    err_io = IO::Memory.new
    in_io = IO::Memory.new(stdin)
    status = Process.run(binary, ["context"] + args, input: in_io, output: out_io, error: err_io)
    {out: out_io.to_s, err: err_io.to_s, code: status.exit_code}
  end

  it "selects from a PreToolUse payload piped on stdin and logs the session" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    payload = %({"session_id":"sess_42","hook_event_name":"PreToolUse","tool_input":{"file_path":"src/foo.cr"}})
    result = run_context_stdin(["--config", config_path, "--hook-stdin"], payload)
    expect(result[:code]).to eq(0)
    expect(result[:out]).to contain("Crystal role")
    log_content = File.read(log_path)
    expect(log_content).to contain("session=sess_42")
    expect(log_content).to contain("event=PreToolUse")
  end

  it "falls back to flags for fields the payload omits" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    # UserPromptSubmit carries no file; --files supplies the signal instead.
    payload = %({"session_id":"s","hook_event_name":"UserPromptSubmit","prompt":""})
    result = run_context_stdin(["--config", config_path, "--hook-stdin", "--files", "src/foo.cr"], payload)
    expect(result[:code]).to eq(0)
    expect(result[:out]).to contain("Crystal role")
  end

  it "degrades to flags when stdin is not valid JSON" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_context_stdin(["--config", config_path, "--hook-stdin", "--files", "src/foo.cr"], "not json")
    expect(result[:code]).to eq(0)
    expect(result[:out]).to contain("Crystal role")
  end

  it "errors hard on an unknown --client" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    result = run_context_stdin(["--config", config_path, "--hook-stdin", "--client", "notepad"], "{}")
    expect(result[:code]).not_to eq(0)
    expect(result[:err]).to contain("Error:")
  end

  it "writes a fixed-format audit line with empty attribution in flags-only mode" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture
    run_context(["--config", config_path, "--files", "src/foo.cr"])
    log_content = File.read(log_path)
    expect(log_content).to contain("event=")
    expect(log_content).to contain("session=")
    expect(log_content).to contain("agent=")
  end
end
