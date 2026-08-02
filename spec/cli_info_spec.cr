require "./spec_helper"

# Exercises the two version surfaces through the compiled binary, because both
# are text contracts only observable from outside the process: `--version` is
# the single line a fleet inventory harvests, `info` is the detail a human
# reads in a bug report. The binary is produced by `mise dev:build`, which
# `mise dev:check` runs before the specs.
Spectator.describe "version surfaces" do
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }

  private def run_binary(args : Array(String))
    out_io = IO::Memory.new
    err_io = IO::Memory.new
    status = Process.run(binary, args, output: out_io, error: err_io)
    {out: out_io.to_s, err: err_io.to_s, code: status.exit_code}
  end

  # Harvested one service per row across a fleet, so it stays on ONE line and
  # names itself: the row's left-hand column is not there any more once the
  # line is copied out.
  describe "--version" do
    it "prints one self-describing line" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      result = run_binary(["--version"])

      expect(result[:code]).to eq(0)
      expect(result[:out].lines.size).to eq(1)
      expect(result[:out].strip).to match(%r{\Amnemodoc-server \S+ \(\S+, \w+/\w+\)\z})
    end
  end

  # Everything the banner deliberately leaves out. Each field is always
  # printed, "unknown" standing in for what a build outside a git checkout
  # cannot know — a missing line would read as a rendering bug.
  describe "info" do
    it "details the provenance in a build block" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      result = run_binary(["info"])

      expect(result[:code]).to eq(0)
      {"version:", "commit:", "tag:", "built:", "target:"}.each do |field|
        expect(result[:out]).to contain(field)
      end
      expect(result[:out]).to contain("crystal:")
    end

    # The block is the detail; the banner is not repeated inside it.
    it "reports the bare version, not the banner" do
      skip "build the binary first (mise dev:build)" unless File.exists?(binary)
      result = run_binary(["info"])

      expect(result[:out]).not_to contain("version: mnemodoc-server")
    end
  end
end
