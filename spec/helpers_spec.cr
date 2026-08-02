require "./spec_helper"

Spectator.describe "MnemodocServer helpers" do
  describe ".format_bytes" do
    it "picks the largest fitting unit" do
      expect(MnemodocServer.format_bytes(512_i64)).to eq("512 B")
      expect(MnemodocServer.format_bytes(2_048_i64)).to eq("2.0 KB")
      expect(MnemodocServer.format_bytes(5_242_880_i64)).to eq("5.0 MB")
      expect(MnemodocServer.format_bytes(3_221_225_472_i64)).to eq("3.0 GB")
    end

    it "handles the unit boundaries" do
      expect(MnemodocServer.format_bytes(1_023_i64)).to eq("1023 B")
      expect(MnemodocServer.format_bytes(1_024_i64)).to eq("1.0 KB")
    end
  end

  # Reported at the end of a run that just took a visible amount of time, so
  # the unit has to match what the user was waiting on: milliseconds for a
  # re-index that had nothing to do, minutes for a first crawl of a large
  # repository. A single unit throughout would print either "0.4s" or
  # "184000ms".
  describe ".format_duration" do
    it "picks the largest fitting unit" do
      expect(MnemodocServer.format_duration(120.milliseconds)).to eq("120ms")
      expect(MnemodocServer.format_duration(2.seconds)).to eq("2.0s")
      expect(MnemodocServer.format_duration(3.minutes + 4.seconds)).to eq("3m04s")
    end

    it "handles the unit boundaries" do
      expect(MnemodocServer.format_duration(999.milliseconds)).to eq("999ms")
      expect(MnemodocServer.format_duration(1.second)).to eq("1.0s")
      expect(MnemodocServer.format_duration(59.seconds)).to eq("59.0s")
      expect(MnemodocServer.format_duration(60.seconds)).to eq("1m00s")
    end

    it "reports a zero duration rather than an empty string" do
      expect(MnemodocServer.format_duration(Time::Span.zero)).to eq("0ms")
    end
  end

  # The version string ends up in `status`, in `info`, and in bug reports, so
  # it has to be legible even when built outside a git checkout — a source
  # tarball, for one, where the git ref simply is not there to be had.
  describe ".version" do
    # The tarball case: with no repository to ask, every field still says
    # something ("unknown"), so the string never degrades to "1.0.0 ()".
    it "never reports an empty provenance" do
      expect(MnemodocServer.version).to match(/\A\S+ \(\S(?:.*\S)?\)\z/)
      expect(MnemodocServer.commit).not_to be_empty
    end

    # The platform is what tells a wrongly pulled arm64 image from the amd64
    # one it should have been, and this project ships static binaries for both.
    # The `-dirty` suffix is the other half: without it a binary built from a
    # patched working tree reports the very string a pristine release reports,
    # which is not an omission but a false statement.
    it "carries the build target and flags a patched tree" do
      expect(MnemodocServer.version)
        .to match(%r{\A\S+ \((?:[0-9a-f]{8}(?:-dirty)?|unknown), \w+/\w+\)\z})
    end

    # This string is the MCP serverInfo's `version`, whose `name` is a separate
    # field, and the `status` tool's own `version` key. Folding the program
    # name in here would duplicate it in both.
    it "does not carry the program name" do
      expect(MnemodocServer.version).not_to contain("mnemodoc-server")
    end
  end

  # The one-line banner a fleet inventory harvests, one service per row. A bare
  # version number is unattributable the moment it leaves the table that named
  # it — a pasted bug report, typically.
  describe ".version_line" do
    it "prefixes the provenance with the program name" do
      expect(MnemodocServer.version_line).to eq("mnemodoc-server #{MnemodocServer.version}")
    end
  end
end
