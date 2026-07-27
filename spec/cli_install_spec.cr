require "./spec_helper"
require "file_utils"

# Exercises `install` and `uninstall` through the built binary with HOME
# redirected at a throwaway directory, so the real client configuration is never
# touched. HOME is the whole isolation seam — no test-only flag exists, and none
# should: a command that writes somewhere other than where it says it does in
# production is not the command being tested.
#
# The files at stake are shared. `~/.claude/settings.json` in particular already
# carries other tools' hooks and permissions, so every example here checks
# cohabitation rather than assuming it.
Spectator.describe "install CLI command" do
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }
  let(home) { File.join(Dir.tempdir, "mnemodoc-home-#{Random::Secure.hex(6)}") }
  let(claude_json) { File.join(home, ".claude.json") }
  let(settings_json) { File.join(home, ".claude", "settings.json") }

  before_each { Dir.mkdir_p(File.join(home, ".claude")) }
  after_each { FileUtils.rm_rf(home) }

  private def run_cli(args : Array(String))
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(binary, args, env: {"HOME" => home},
      output: output, error: error)
    {code: status.exit_code, out: output.to_s, err: error.to_s}
  end

  # A settings file already carrying another tool's hook and permissions, which
  # must survive untouched.
  private def write_foreign_settings
    File.write(settings_json, {
      "permissions" => {"allow" => ["Bash(ls)"]},
      "hooks"       => {
        "PreToolUse" => [{"matcher" => "Bash", "hooks" => [{"type" => "command", "command" => "other-tool hook"}]}],
      },
      "statusLine" => {"type" => "command", "command" => "my-status"},
    }.to_json)
  end

  describe "--print-config" do
    # codegraph's equivalent shows only the MCP entry, while its install also
    # writes a hook and a permissions entry. A dry run that under-reports is
    # worse than none: it invites trust it has not earned.
    it "reports every file it would touch, hooks and permissions included" do
      result = run_cli(["install", "--print-config"])
      expect(result[:code]).to eq(0)
      expect(result[:out]).to contain(".claude.json")
      expect(result[:out]).to contain("mcpServers")
      expect(result[:out]).to contain("settings.json")
      expect(result[:out]).to contain("UserPromptSubmit")
      expect(result[:out]).to contain("PreToolUse")
      expect(result[:out]).to contain("mcp__mnemodoc__query_documents")
    end

    it "writes nothing at all" do
      run_cli(["install", "--print-config"])
      expect(File.exists?(claude_json)).to be_false
      expect(File.exists?(settings_json)).to be_false
    end
  end

  describe "the MCP entry" do
    it "registers the server and preserves unrelated keys" do
      File.write(claude_json, {"numStartups" => 12, "mcpServers" => {"other" => {"command" => "other"}}}.to_json)
      expect(run_cli(["install", "--yes"])[:code]).to eq(0)

      payload = JSON.parse(File.read(claude_json))
      expect(payload["numStartups"].as_i).to eq(12)
      expect(payload["mcpServers"]["other"]["command"].as_s).to eq("other")
      expect(payload["mcpServers"]["mnemodoc"]["command"].as_s).to end_with("mnemodoc-server")
    end

    # No --config: the server discovers its project by walking up from the
    # working directory the client launches it in. A path here would pin one
    # global entry to a single project.
    it "registers no project path" do
      run_cli(["install", "--yes"])
      args = JSON.parse(File.read(claude_json))["mcpServers"]["mnemodoc"]["args"].as_a.map(&.as_s)
      expect(args).to eq(["serve"])
    end

    it "creates the file when there is none" do
      run_cli(["install", "--yes"])
      expect(JSON.parse(File.read(claude_json))["mcpServers"]["mnemodoc"]?).not_to be_nil
    end
  end

  describe "the hooks" do
    it "adds both hooks without disturbing another tool's" do
      write_foreign_settings
      run_cli(["install", "--yes"])

      payload = JSON.parse(File.read(settings_json))
      expect(payload["statusLine"]["command"].as_s).to eq("my-status")

      pre = payload["hooks"]["PreToolUse"].as_a
      commands = pre.flat_map { |entry| entry["hooks"].as_a.map(&.["command"].as_s) }
      expect(commands).to contain("other-tool hook")
      expect(commands.any?(&.includes?("context --hook-stdin"))).to be_true

      prompt = payload["hooks"]["UserPromptSubmit"].as_a
        .flat_map { |entry| entry["hooks"].as_a.map(&.["command"].as_s) }
      expect(prompt.any?(&.includes?("prompt-hook"))).to be_true
    end

    it "leaves the hooks alone under --no-hooks" do
      run_cli(["install", "--yes", "--no-hooks"])
      payload = JSON.parse(File.read(settings_json))
      expect(payload["hooks"]?).to be_nil
    end
  end

  describe "the permissions" do
    # Named one by one rather than as a `mcp__mnemodoc__*` wildcard: the
    # mutating tools are deliberately left out, so adding one later cannot
    # silently inherit a blanket approval.
    it "allows the read-only tools by name and never a wildcard" do
      write_foreign_settings
      run_cli(["install", "--yes"])

      allow = JSON.parse(File.read(settings_json))["permissions"]["allow"].as_a.map(&.as_s)
      expect(allow).to contain("Bash(ls)")
      expect(allow).to contain("mcp__mnemodoc__query_documents")
      expect(allow).to contain("mcp__mnemodoc__get_project_context")
      expect(allow).to contain("mcp__mnemodoc__status")
      expect(allow.any?(&.includes?("*"))).to be_false
      expect(allow).not_to contain("mcp__mnemodoc__delete_file")
    end

    it "skips them under --no-permissions" do
      run_cli(["install", "--yes", "--no-permissions"])
      payload = JSON.parse(File.read(settings_json))
      expect(payload["permissions"]?).to be_nil
    end
  end

  describe "re-running" do
    it "is idempotent" do
      run_cli(["install", "--yes"])
      run_cli(["install", "--yes"])

      allow = JSON.parse(File.read(settings_json))["permissions"]["allow"].as_a.map(&.as_s)
      expect(allow.count("mcp__mnemodoc__status")).to eq(1)

      prompt = JSON.parse(File.read(settings_json))["hooks"]["UserPromptSubmit"].as_a
      expect(prompt.size).to eq(1)
    end
  end

  describe "refusing to guess" do
    # Rewriting a file we cannot parse would destroy whatever it held. Better to
    # stop and say so.
    it "exits non-zero and writes nothing when a target file is not valid JSON" do
      File.write(claude_json, "{ this is not json")
      result = run_cli(["install", "--yes"])

      expect(result[:code]).not_to eq(0)
      expect(File.read(claude_json)).to eq("{ this is not json")
      expect(File.exists?(settings_json)).to be_false
    end

    it "rejects an unknown --target and names the ones it knows" do
      result = run_cli(["install", "--yes", "--target", "emacs"])
      expect(result[:code]).not_to eq(0)
      expect(result[:err]).to contain("claude")
    end
  end

  describe "uninstall" do
    it "removes exactly what install added and leaves the rest" do
      write_foreign_settings
      run_cli(["install", "--yes"])
      expect(run_cli(["uninstall", "--yes"])[:code]).to eq(0)

      settings = JSON.parse(File.read(settings_json))
      allow = settings["permissions"]["allow"].as_a.map(&.as_s)
      expect(allow).to eq(["Bash(ls)"])
      expect(settings["statusLine"]["command"].as_s).to eq("my-status")

      pre = settings["hooks"]["PreToolUse"].as_a
        .flat_map { |entry| entry["hooks"].as_a.map(&.["command"].as_s) }
      expect(pre).to eq(["other-tool hook"])

      expect(JSON.parse(File.read(claude_json))["mcpServers"]["mnemodoc"]?).to be_nil
    end

    it "succeeds when nothing was installed" do
      expect(run_cli(["uninstall", "--yes"])[:code]).to eq(0)
    end
  end
end
