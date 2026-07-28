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

  # The version string ends up in `status`, in `info`, and in bug reports, so
  # it has to be legible even when built outside a git checkout — a source
  # tarball, for one, where the git ref simply is not there to be had.
  describe ".version" do
    it "never reports an empty provenance" do
      expect(MnemodocServer.version).to match(/\S+ \(\S+\)/)
    end
  end
end
