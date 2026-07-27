require "./spec_helper"
require "file_utils"

# Exercises `init` and `uninit` through the built binary, for the same reason as
# cli_context_spec: what matters is what lands on disk and the process exit
# code, both only observable from outside.
#
# `init` is the deliberate act that turns a directory into a MnemoDoc project.
# It exists because the server is meant to be registered once, globally: nothing
# else may create the marker, so this command has to do everything a project
# needs in one step — marker, configuration, first index.
Spectator.describe "init CLI command" do
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }
  let(root) { File.join(Dir.tempdir, "mnemodoc-init-#{Random::Secure.hex(6)}") }

  before_each { Dir.mkdir_p(root) }
  after_each { FileUtils.rm_rf(root) }

  private def run_init(args : Array(String) = [] of String)
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(binary, ["init"] + args,
      chdir: root, output: output, error: error)
    {code: status.exit_code, out: output.to_s, err: error.to_s}
  end

  describe "the marker" do
    it "creates the index directory with its self-ignoring .gitignore" do
      Dir.mkdir_p(File.join(root, "docs"))
      expect(run_init()[:code]).to eq(0)

      gitignore = File.join(root, ".mnemodoc", ".gitignore")
      expect(Dir.exists?(File.join(root, ".mnemodoc"))).to be_true
      expect(File.read(gitignore)).to contain("!.gitignore")
    end

    it "makes the directory discoverable as a project afterwards" do
      Dir.mkdir_p(File.join(root, "docs"))
      run_init()
      expect(MnemodocServer.discover_project(root)).to eq(File.realpath(root))
    end
  end

  describe "path detection" do
    it "writes the documentation directories it actually found" do
      Dir.mkdir_p(File.join(root, "docs"))
      Dir.mkdir_p(File.join(root, "src"))
      run_init()

      config = File.read(File.join(root, ".mnemodoc.yml"))
      expect(config).to contain("docs/")
      expect(config).not_to contain("src/")
    end

    # Never invent a path: a directory that is not there must not end up in the
    # generated configuration, where it would sit as a permanent lie.
    it "falls back to the project root when no documentation directory exists" do
      File.write(File.join(root, "README.md"), "# Readme\n\nSome text.\n")
      run_init()

      config = File.read(File.join(root, ".mnemodoc.yml"))
      expect(config).to contain("paths:")
      expect(config).not_to contain("docs/")
    end
  end

  describe "re-running" do
    it "leaves an existing configuration untouched and still succeeds" do
      Dir.mkdir_p(File.join(root, "docs"))
      File.write(File.join(root, ".mnemodoc.yml"), "paths:\n  - hand-written/\n")
      expect(run_init()[:code]).to eq(0)
      expect(File.read(File.join(root, ".mnemodoc.yml"))).to contain("hand-written/")
    end

    it "regenerates the configuration under --force" do
      Dir.mkdir_p(File.join(root, "docs"))
      File.write(File.join(root, ".mnemodoc.yml"), "paths:\n  - hand-written/\n")
      run_init(["--force"])
      expect(File.read(File.join(root, ".mnemodoc.yml"))).not_to contain("hand-written/")
    end
  end

  describe "machine output" do
    it "reports the project, the detected paths and the config it wrote" do
      Dir.mkdir_p(File.join(root, "docs"))
      result = run_init(["--json"])
      payload = JSON.parse(result[:out])

      expect(payload["project"].as_s).to eq(File.realpath(root))
      expect(payload["paths"].as_a.map(&.as_s)).to contain("docs/")
      expect(payload["config"].as_s).to end_with(".mnemodoc.yml")
      expect(payload["files_indexed"].as_i).to be >= 0
    end

    it "prints nothing under --quiet and still reports through the exit code" do
      Dir.mkdir_p(File.join(root, "docs"))
      result = run_init(["--quiet"])
      expect(result[:out]).to be_empty
      expect(result[:code]).to eq(0)
    end
  end

  describe "uninit" do
    it "removes the marker but leaves the generated configuration in place" do
      Dir.mkdir_p(File.join(root, "docs"))
      run_init()

      status = Process.run(binary, ["uninit", "--yes"], chdir: root)
      expect(status.exit_code).to eq(0)
      expect(Dir.exists?(File.join(root, ".mnemodoc"))).to be_false
      expect(File.exists?(File.join(root, ".mnemodoc.yml"))).to be_true
    end

    it "exits non-zero when there is no project to remove" do
      status = Process.run(binary, ["uninit", "--yes"], chdir: root,
        output: Process::Redirect::Close, error: Process::Redirect::Close)
      expect(status.exit_code).not_to eq(0)
    end
  end
end
