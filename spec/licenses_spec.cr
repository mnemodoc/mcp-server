require "./spec_helper"

Spectator.describe MnemodocServer::Licenses do
  # Licenses.get raises NoSuchFileError when absent, so a successful read also
  # asserts the file was baked — no nil handling needed.
  it "bakes the sqlite-vec MIT license" do
    expect(MnemodocServer::Licenses.get("sqlite-vec.txt").gets_to_end).to contain("MIT")
  end

  it "bakes a grouped clib notice with liblzma under 0BSD (not GPL)" do
    text = MnemodocServer::Licenses.get("clib-0BSD.txt").gets_to_end
    expect(text).to contain("liblzma")
    expect(text).not_to contain("GNU GENERAL PUBLIC LICENSE")
  end

  it "does not bake any GMP notice" do
    paths = MnemodocServer::Licenses.files.map(&.path)
    expect(paths.any?(&.downcase.includes?("gmp"))).to be_false
  end
end
