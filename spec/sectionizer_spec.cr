# spec/sectionizer_spec.cr
require "./spec_helper"

Spectator.describe MnemodocServer::Indexer::Sectionizer do
  it "creates a preamble section with nil heading for text before any heading" do
    sz = MnemodocServer::Indexer::Sectionizer.new
    sz.text("intro line")
    sz.heading(2, "## A")
    sz.text("body a")
    sections = sz.sections
    expect(sections.size).to eq(2)
    expect(sections[0].heading).to be_nil
    expect(sections[0].body.strip).to eq("intro line")
    expect(sections[1].heading).to eq("## A")
  end

  it "sets parent_heading to the nearest strictly-shallower heading" do
    sz = MnemodocServer::Indexer::Sectionizer.new
    sz.heading(2, "## A")
    sz.text("a")
    sz.heading(3, "### A1")
    sz.text("a1")
    sz.heading(2, "## B")
    sz.text("b")
    sections = sz.sections
    expect(sections.map(&.heading)).to eq(["## A", "### A1", "## B"])
    expect(sections.map(&.parent_heading)).to eq([nil, "## A", nil])
  end

  it "drops blank-only bodies" do
    sz = MnemodocServer::Indexer::Sectionizer.new
    sz.heading(2, "## Empty")
    sz.text("   ")
    expect(sz.sections).to be_empty
  end
end
