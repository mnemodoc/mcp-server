require "./spec_helper"
require "file_utils"

# `index` is what a deployment script runs. Its exit code is the only thing
# such a script reads, and under --quiet it is the only thing it gets at all.
Spectator.describe "index CLI" do
  let(binary) { "./bin/mnemodoc-server" }
  let(tmp_dir) { "/tmp/mnemodoc-index-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }

  before_each do
    Dir.mkdir_p(File.join(tmp_dir, "doc"))
    File.write(File.join(tmp_dir, "doc", "a.md"), "# Doc\n\n## S\n\nbody text")
  end
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Ollama on a closed port: every embedding fails, so nothing can be indexed.
  private def write_config(ollama : String = "http://127.0.0.1:1") : Nil
    File.write(config_path, <<-YAML)
    paths:
      - doc/
    ollama:
      host: #{ollama}
    server:
      log_level: error
    db:
      path: #{File.join(tmp_dir, "index.db")}
    YAML
  end

  private def run_index(*args) : {String, Process::Status}
    stdout = IO::Memory.new
    status = Process.run(binary,
      ["index", File.join(tmp_dir, "doc"), "--config", config_path] + args.to_a,
      output: stdout, error: Process::Redirect::Close)
    {stdout.to_s, status}
  end

  it "exits non-zero when nothing could be indexed" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_config
    _, status = run_index
    expect(status.success?).to be_false
  end

  # --quiet prints nothing by design, which makes the exit code the whole of
  # the report. Reporting success there is how a broken index goes unnoticed.
  it "exits non-zero under --quiet too" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_config
    _, status = run_index("--quiet")
    expect(status.success?).to be_false
  end

  it "reports the failed chunk count in the JSON payload" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_config
    stdout, _ = run_index("--json")
    payload = JSON.parse(stdout)
    expect(payload["indexed"].as_i).to eq(0)
    expect(payload["failed"].as_i).to be > 0
  end

  it "still succeeds when there is simply nothing to do" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    write_config
    FileUtils.rm_rf(File.join(tmp_dir, "doc"))
    Dir.mkdir_p(File.join(tmp_dir, "doc"))
    _, status = run_index
    expect(status.success?).to be_true
  end
end
