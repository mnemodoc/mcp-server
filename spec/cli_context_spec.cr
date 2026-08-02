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
    paths:
      - .
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

  # Like write_fixture but adds a configured default (generalist) role plus a
  # query-decisive `policies` role, so the query-channel suppression of the
  # default can be exercised. The file roles stay narrow (app/**) so a
  # cross-cutting PreToolUse path falls back to the default.
  private def write_fixture_with_default
    File.write(File.join(tmp_dir, "generalist.md"), "# Generalist role\nDefault conventions.")
    File.write(File.join(tmp_dir, "policies.md"), "# Policies role\nScope ownership.")
    File.write(config_path, <<-YAML)
    paths:
      - .
    server:
      log_file: #{log_path}
    context:
      default: generalist.md
      roles:
        - file: policies.md
          when_files: ["app/policies/**"]
          when_query: ["policy", "ownership"]
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

  it "stays silent on stdout but still audits when UserPromptSubmit resolves to the default" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture_with_default
    payload = %({"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"merci, continue"})
    result = run_context_stdin(["--config", config_path, "--hook-stdin"], payload)
    expect(result[:code]).to eq(0)
    expect(result[:out]).to be_empty
    log_content = File.read(log_path)
    expect(log_content).to contain("event=UserPromptSubmit")
    expect(log_content).to contain("role=generalist")
  end

  it "prints the domain role when a UserPromptSubmit query is decisive" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture_with_default
    payload = %({"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"ajouter une policy de scope ownership"})
    result = run_context_stdin(["--config", config_path, "--hook-stdin"], payload)
    expect(result[:code]).to eq(0)
    expect(result[:out]).to contain("Policies role")
  end

  # A project whose keywords are short or common can find one hit too thin a
  # signal to spend context on. The threshold raises the bar for the query
  # channel alone, and below it the channel says nothing at all rather than
  # falling back to the default role on every conversational turn.
  describe "context.min_query_score" do
    private def write_fixture_with_threshold(threshold : Int32)
      File.write(File.join(tmp_dir, "generalist.md"), "# Generalist role\nDefault conventions.")
      File.write(File.join(tmp_dir, "policies.md"), "# Policies role\nScope ownership.")
      File.write(config_path, <<-YAML)
      paths:
        - .
      server:
        log_file: #{log_path}
      context:
        default: generalist.md
        min_query_score: #{threshold}
        roles:
          - file: policies.md
            when_files: ["app/policies/**"]
            when_query: ["policy", "ownership"]
      YAML
    end

    it "stays silent when a single keyword falls short of the threshold" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_threshold(2)
      payload = %({"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"une question de policy"})
      result = run_context_stdin(["--config", config_path, "--hook-stdin"], payload)

      expect(result[:code]).to eq(0)
      expect(result[:out]).to be_empty
      # Silence on stdout, never in the audit trail: the turn stays traceable.
      expect(File.read(log_path)).to contain("event=UserPromptSubmit")
    end

    it "injects once the query carries enough signal" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_threshold(2)
      payload = %({"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"une policy de scope ownership"})
      result = run_context_stdin(["--config", config_path, "--hook-stdin"], payload)

      expect(result[:code]).to eq(0)
      expect(result[:out]).to contain("Policies role")
    end

    # An edited file is a strong, unambiguous signal, and the threshold has no
    # business gating it.
    it "does not gate the files channel" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_threshold(9)
      payload = %({"session_id":"x","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"app/policies/thing.rb"}})
      result = run_context_stdin(["--config", config_path, "--hook-stdin"], payload)

      expect(result[:code]).to eq(0)
      expect(result[:out]).to contain("Policies role")
    end

    # Under --json the payload is always emitted; suppression is a field, since
    # an empty stdout would be indistinguishable from a failure.
    it "reports the suppression under --json rather than emitting nothing" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_threshold(2)
      payload = %({"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"une question de policy"})
      result = run_context_stdin(["--config", config_path, "--hook-stdin", "--json"], payload)

      payload_json = JSON.parse(result[:out])
      expect(payload_json["suppressed"].as_bool).to be_true
      expect(payload_json["score"].as_i).to eq(1)
    end
  end

  it "always prints the default role on a cross-cutting PreToolUse edit" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_fixture_with_default
    payload = %({"session_id":"x","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"#{tmp_dir}/config/initializers/cors.rb"}})
    result = run_context_stdin(["--config", config_path, "--hook-stdin"], payload)
    expect(result[:code]).to eq(0)
    expect(result[:out]).to contain("Generalist role")
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

  # Claude Code discards a PreToolUse hook's stdout: for that event the client
  # only reads context out of `hookSpecificOutput.additionalContext`. Printing
  # the markdown raw there computes a role and throws it away, silently. The
  # envelope is therefore chosen by the event, not by the flags.
  describe "output shape per hook event" do
    # A role whose markdown carries the characters JSON has to escape, so the
    # round-trip proves the payload is encoded rather than concatenated.
    private def write_fixture_with_tricky_role
      File.write(File.join(tmp_dir, "crystal.md"), %(# Crystal role\nSay "no" to `x \\ y`.\nUse idiomatic Crystal.))
      File.write(config_path, <<-YAML)
      paths:
        - .
      server:
        log_file: #{log_path}
      context:
        roles:
          - file: crystal.md
            when_files: ["**/*.cr"]
      YAML
    end

    it "wraps the role markdown in the PreToolUse envelope the client reads" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_tricky_role
      payload = %({"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.cr"}})
      result = run_context_stdin(["--config", config_path, "--hook-stdin"], payload)

      expect(result[:code]).to eq(0)
      emitted = JSON.parse(result[:out])
      expect(emitted["hookSpecificOutput"]["hookEventName"].as_s).to eq("PreToolUse")
      expect(emitted["hookSpecificOutput"]["additionalContext"].as_s)
        .to eq(File.read(File.join(tmp_dir, "crystal.md")))
    end

    # The query channel already reaches the model: UserPromptSubmit stdout is
    # appended to the context by the client, so wrapping it would inject a JSON
    # blob instead of the role.
    it "keeps UserPromptSubmit on raw stdout" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_default
      payload = %({"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"ajouter une policy de scope ownership"})
      result = run_context_stdin(["--config", config_path, "--hook-stdin"], payload)

      expect(result[:code]).to eq(0)
      expect(result[:out]).to contain("Policies role")
      expect(result[:out]).not_to contain("hookSpecificOutput")
    end

    it "keeps flags-only invocation on raw stdout" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_tricky_role
      result = run_context(["--config", config_path, "--files", "src/foo.cr"])

      expect(result[:code]).to eq(0)
      expect(result[:out]).to contain("Crystal role")
      expect(result[:out]).not_to contain("hookSpecificOutput")
    end

    # --json is the diagnostic payload, a different format for a different
    # caller. The hook never passes it, and the envelope must not leak into it.
    it "leaves the --json diagnostic payload untouched on PreToolUse" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_tricky_role
      payload = %({"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.cr"}})
      result = run_context_stdin(["--config", config_path, "--hook-stdin", "--json"], payload)

      emitted = JSON.parse(result[:out])
      expect(emitted["role"].as_s).to eq("crystal")
      expect(emitted["suppressed"].as_bool).to be_false
      expect(emitted["content"].as_s).to contain("Crystal role")
      expect(emitted["hookSpecificOutput"]?).to be_nil
    end
  end

  # A hook payload that carries nothing to select on used to fall through to the
  # configured default role, with exit 0 — so a broken pipe or a malformed
  # payload injected a plausible but unfounded context, indistinguishable from a
  # real selection.
  describe "hook stdin carrying no signal" do
    it "prints nothing and exits 0 on empty stdin" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_default
      result = run_context_stdin(["--config", config_path, "--hook-stdin"], "")

      expect(result[:code]).to eq(0)
      expect(result[:out]).to be_empty
    end

    it "prints nothing and exits 0 on stdin that is not JSON" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_default
      result = run_context_stdin(["--config", config_path, "--hook-stdin"], "pas du json")

      expect(result[:code]).to eq(0)
      expect(result[:out]).to be_empty
    end

    # Valid JSON, well-formed, but an event this adapter does not handle: no
    # file, no prompt. Same absence of signal, same silence.
    it "prints nothing on a valid payload for an unhandled event" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_default
      result = run_context_stdin(["--config", config_path, "--hook-stdin"],
        %({"session_id":"x","hook_event_name":"SessionStart"}))

      expect(result[:code]).to eq(0)
      expect(result[:out]).to be_empty
    end

    # Exit 0 and an empty stdout are indistinguishable from a legitimate
    # silence, so the log line is the only trace this case leaves.
    it "records the silence in the audit log" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_default
      run_context_stdin(["--config", config_path, "--hook-stdin"], "")

      expect(File.read(log_path)).to contain("no signal")
    end

    it "reports it as a suppression under --json rather than emitting nothing" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_default
      result = run_context_stdin(["--config", config_path, "--hook-stdin", "--json"], "")

      expect(result[:code]).to eq(0)
      expect(JSON.parse(result[:out])["suppressed"].as_bool).to be_true
    end

    # The guard is for the hook, which speaks through stdin. A human running the
    # command by hand with no flags asked for the default role, and gets it.
    it "leaves manual flags-only invocation alone" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_default
      result = run_context(["--config", config_path])

      expect(result[:code]).to eq(0)
      expect(result[:out]).to contain("Generalist role")
    end
  end

  # server.log_file is frequently a real file, kept far longer than the session
  # that wrote it. The audit line runs at the default level, so anything it
  # carries is on disk in clear: a prompt is the user's own words, and those
  # routinely contain a token, a customer name, an internal hostname.
  describe "what the audit trail records" do
    it "records that a prompt was handled, not what it said" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      write_fixture_with_default
      secret = "sk-live-#{Random::Secure.hex(8)}"
      # A query that fires the `policies` role, so the selection succeeds and
      # the audit line is actually written.
      payload = {hook_event_name: "UserPromptSubmit", prompt: "policy question, token #{secret}"}.to_json

      Process.run(binary, ["context", "--hook-stdin", "--config", config_path],
        input: IO::Memory.new(payload),
        output: Process::Redirect::Close, error: Process::Redirect::Close)

      log = File.exists?(log_path) ? File.read(log_path) : ""
      expect(log).not_to be_empty
      expect(log).not_to contain(secret)
      # The turn is still traceable: the event and the prompt's length are there.
      expect(log).to contain("event=UserPromptSubmit")
      expect(log).to contain("query_len=")
    end
  end
end
