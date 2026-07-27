require "./spec_helper"
require "file_utils"

# Exercises the `daemon status` / `daemon stop` surface through the compiled
# binary, so subcommand nesting and flag parsing are covered end to end rather
# than only the helpers underneath. A real daemon is spawned as a subprocess;
# each example works in its own temp project so nothing is shared.
Spectator.describe "daemon CLI" do
  let(tmp_dir) { "/tmp/mnemodoc-cli-daemon-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }

  before_each do
    Dir.mkdir_p(File.join(tmp_dir, "doc"))
    File.write(File.join(tmp_dir, "doc", "a.md"), "# T\n\n## S\n\nbody\n")
  end
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Writes a config for this temp project. Ollama points at a closed port: no
  # example here embeds anything, and an unreachable host keeps it that way.
  private def write_config(daemon : Bool = true) : Nil
    File.write(config_path, <<-YAML)
    paths:
      - doc/
    ollama:
      host: http://127.0.0.1:1
    server:
      log_level: error
      daemon: #{daemon}
      daemon_idle_timeout: 30
      daemon_watch: false
    YAML
  end

  # Runs the compiled binary and returns {stdout, stderr, status}.
  private def run_cli(*args : String)
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("./bin/mnemodoc-server", args.to_a, output: stdout, error: stderr)
    {stdout.to_s, stderr.to_s, status}
  end

  # Spawns a real daemon for this project and waits until it answers /health.
  private def with_daemon(&)
    process = Process.new(
      "./bin/mnemodoc-server",
      ["serve", "--daemon", "--config", config_path],
      input: Process::Redirect::Close,
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )
    config = MnemodocServer::Config.from_yaml(File.read(config_path))
    config.source_dir = tmp_dir

    deadline = Time.instant + 15.seconds
    until MnemodocServer.daemon_healthy?(config)
      raise "daemon did not become healthy in time" if Time.instant > deadline
      sleep 100.milliseconds
    end

    begin
      yield config
    ensure
      process.terminate rescue nil
      process.wait rescue nil
    end
  end

  describe "daemon status" do
    # Exits non-zero when nothing is running, like `systemctl is-active`.
    it "reports that no daemon is running" do
      write_config
      stdout, _, status = run_cli("daemon", "status", "--config", config_path)
      expect(status.success?).to be_false
      expect(stdout).to contain("not running")
    end

    it "reports a running daemon and its pid" do
      write_config
      with_daemon do |config|
        stdout, _, status = run_cli("daemon", "status", "--config", config_path)
        expect(status.success?).to be_true
        expect(stdout).to contain("Status: running")
        expect(stdout).to contain("PID: #{File.read(config.daemon_pid_path).strip}")
      end
    end

    # Disabled means nothing is running either, so the exit code says no.
    it "says so when daemon mode is disabled" do
      write_config(daemon: false)
      stdout, _, status = run_cli("daemon", "status", "--config", config_path)
      expect(status.success?).to be_false
      expect(stdout).to contain("disabled")
    end
  end

  describe "daemon stop" do
    it "stops a running daemon and removes its socket" do
      write_config
      with_daemon do |config|
        stdout, _, status = run_cli("daemon", "stop", "--config", config_path)
        expect(status.success?).to be_true
        expect(stdout).to contain("Daemon stopped")
        expect(MnemodocServer.daemon_healthy?(config)).to be_false
      end
    end

    it "cleans up a stale pid file instead of signalling" do
      write_config
      config = MnemodocServer::Config.from_yaml(File.read(config_path))
      config.source_dir = tmp_dir
      config.prepare_index_dir!
      # A pid that is certainly not a live daemon of ours.
      File.write(config.daemon_pid_path, "999999\n")

      stdout, _, status = run_cli("daemon", "stop", "--config", config_path)
      expect(status.success?).to be_true
      expect(stdout).to contain("not running")
      expect(File.exists?(config.daemon_pid_path)).to be_false
    end
  end

  describe "daemon with no subcommand" do
    # The parent command takes no flags of its own: it only lists what is
    # available, so it is invoked bare.
    it "prints help instead of an invalid-subcommand error" do
      stdout, _, status = run_cli("daemon")
      expect(status.success?).to be_true
      expect(stdout).to contain("status")
      expect(stdout).to contain("stop")
    end
  end
end
