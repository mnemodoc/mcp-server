require "./spec_helper"
require "file_utils"

# The prompt hook runs before every user message, synchronously, in the client's
# critical path. Two properties matter more than what it prints: it must stay
# silent unless the prompt measurably concerns this corpus, and it must never
# fail in a way that blocks or annoys — whatever is wrong, exit 0 and say
# nothing.
Spectator.describe "prompt-hook CLI" do
  let(tmp_dir) { "/tmp/mnemodoc-hook-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }

  before_each do
    Dir.mkdir_p(File.join(tmp_dir, "doc"))
    File.write(File.join(tmp_dir, "doc", "excluding.md"), <<-MD)
    # Indexing

    ## Excluding paths

    Glob patterns listed under the exclude key are matched against absolute
    paths and skipped. Exclusion is evaluated during the walk, so an excluded
    directory is never descended into.
    MD
  end
  after_each { FileUtils.rm_rf(tmp_dir) }

  private def write_config(threshold : Float64 = 0.5, ollama : String = "http://localhost:11434") : Nil
    File.write(config_path, <<-YAML)
    paths:
      - doc/
    ollama:
      host: #{ollama}
    server:
      log_level: error
      daemon: false
    hook:
      similarity_threshold: #{threshold}
    db:
      path: #{File.join(tmp_dir, "index.db")}
    YAML
  end

  private def run_hook(prompt : String)
    payload = {hook_event_name: "UserPromptSubmit", prompt: prompt}.to_json
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("./bin/mnemodoc-server",
      ["prompt-hook", "--config", config_path],
      input: IO::Memory.new(payload), output: stdout, error: stderr)
    {stdout.to_s, stderr.to_s, status}
  end

  private def index! : Nil
    Process.run("./bin/mnemodoc-server",
      ["index", File.join(tmp_dir, "doc"), "--config", config_path, "--quiet"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
  end

  describe "when the prompt concerns the corpus" do
    it "injects the best passage, naming its source" do
      write_config
      index!
      stdout, _, status = run_hook("how do I exclude a directory from indexing?")
      expect(status.success?).to be_true
      expect(stdout).to contain("Glob patterns")
      expect(stdout).to contain("excluding.md")
      expect(stdout).to contain("Excluding paths")
    end
  end

  describe "when it does not" do
    # The whole point of the gate: conversational filler must cost nothing.
    it "stays silent on an off-topic prompt" do
      write_config
      index!
      stdout, _, status = run_hook("write me a haiku about cats")
      expect(status.success?).to be_true
      expect(stdout).to be_empty
    end

    it "stays silent when the threshold is unreachable" do
      write_config(threshold: 1.0)
      index!
      stdout, _, status = run_hook("how do I exclude a directory from indexing?")
      expect(status.success?).to be_true
      expect(stdout).to be_empty
    end
  end

  # Every failure mode below would, if it escaped, surface as noise or an error
  # in front of the user on a turn that had nothing to do with documentation.
  describe "never gets in the way" do
    it "exits cleanly on unparseable stdin" do
      write_config
      index!
      stdout = IO::Memory.new
      status = Process.run("./bin/mnemodoc-server", ["prompt-hook", "--config", config_path],
        input: IO::Memory.new("not json at all"), output: stdout, error: Process::Redirect::Close)
      expect(status.success?).to be_true
      expect(stdout.to_s).to be_empty
    end

    it "exits cleanly when Ollama is unreachable" do
      write_config(ollama: "http://127.0.0.1:1")
      stdout, _, status = run_hook("how do I exclude a directory from indexing?")
      expect(status.success?).to be_true
      expect(stdout).to be_empty
    end

    it "exits cleanly on an empty index" do
      write_config
      stdout, _, status = run_hook("how do I exclude a directory from indexing?")
      expect(status.success?).to be_true
      expect(stdout).to be_empty
    end

    it "exits cleanly when the config file does not exist" do
      stdout = IO::Memory.new
      payload = {hook_event_name: "UserPromptSubmit", prompt: "anything"}.to_json
      status = Process.run("./bin/mnemodoc-server",
        ["prompt-hook", "--config", File.join(tmp_dir, "absent.yml")],
        input: IO::Memory.new(payload), output: stdout, error: Process::Redirect::Close)
      expect(status.success?).to be_true
      expect(stdout.to_s).to be_empty
    end
  end
end
