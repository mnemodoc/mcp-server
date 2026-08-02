require "./spec_helper"

# A reader that walks away is not a failure of this program: `| head` takes its
# lines and leaves, `| less` is quit halfway. Crystal ignores SIGPIPE at startup
# (`Signal::PIPE.ignore` in its runtime), so the write comes back EPIPE and
# raises instead of killing the process — and the entry point's catch-all used
# to answer that with a full stack trace and a non-zero exit.
#
# `info --licenses` is the vehicle because the baked-in licence texts run to
# tens of kilobytes: the write that lands after the reader is gone is a
# certainty rather than a race, which is what makes this example deterministic.
# It also needs no project, no config and no Ollama.
Spectator.describe "a truncated pipe" do
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }

  # bash, not sh: PIPESTATUS is what gives us the *binary's* exit code rather
  # than `head`'s, and POSIX sh has no equivalent.
  private def run_piped(command : String)
    out_io = IO::Memory.new
    err_io = IO::Memory.new
    status = Process.run("bash", ["-c", command], output: out_io, error: err_io)
    {out: out_io.to_s, err: err_io.to_s, code: status.exit_code}
  end

  it "leaves no backtrace on stderr and exits 0" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    result = run_piped("'#{binary}' info --licenses | head -1 > /dev/null; exit ${PIPESTATUS[0]}")

    expect(result[:err]).to be_empty
    expect(result[:code]).to eq(0)
  end

  # The reader stays: nothing is truncated, and the command reports normally.
  # Without this, "never fails on a pipe" could be satisfied by never failing.
  it "still reports a real failure through a pipe that stays open" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    result = run_piped("'#{binary}' search hello --config /nonexistent/.mnemodoc.yml | cat; exit ${PIPESTATUS[0]}")

    expect(result[:code]).not_to eq(0)
    expect(result[:err]).not_to be_empty
  end
end
