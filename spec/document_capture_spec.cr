# spec/document_capture_spec.cr
require "./spec_helper"

Spectator.describe MnemodocServer::Indexer::Sectionizer do
  it "records one outline entry per heading, with its level" do
    sz = MnemodocServer::Indexer::Sectionizer.new
    sz.heading(2, "## A")
    sz.text("body a")
    sz.heading(3, "### A1")
    sz.text("body a1")
    expect(sz.outline.map(&.level)).to eq([2, 3])
    expect(sz.outline.map(&.title)).to eq(["## A", "### A1"])
  end

  it "numbers heading start lines against the text it accumulated" do
    sz = MnemodocServer::Indexer::Sectionizer.new
    sz.text("intro")
    sz.heading(2, "## A")
    sz.text("body a")
    sz.heading(2, "## B")
    expect(sz.outline.map(&.start_line)).to eq([2, 4])
    expect(sz.normalized_text).to eq("intro\n## A\nbody a\n## B\n")
  end

  it "lets a handler override the line number with the true source line" do
    sz = MnemodocServer::Indexer::Sectionizer.new
    sz.heading(1, "= Title", source_line: 12)
    expect(sz.outline.first.start_line).to eq(12)
  end

  # A heading carrying only sub-headings produces no section, because the
  # sectionizer drops blank bodies. It is still a place in the document, so it
  # must still appear in the outline: the outline describes the document, not
  # the chunks.
  it "keeps a heading in the outline even when its body is blank" do
    sz = MnemodocServer::Indexer::Sectionizer.new
    sz.heading(1, "# Parent")
    sz.heading(2, "## Child")
    sz.text("only the child has a body")
    expect(sz.sections.map(&.heading)).to eq(["## Child"])
    expect(sz.outline.map(&.title)).to eq(["# Parent", "## Child"])
  end
end

Spectator.describe MnemodocServer::Indexer::Document do
  it "counts the lines of its own text" do
    doc = MnemodocServer::Indexer::Document.new(
      text: "one\ntwo\nthree\n",
      verbatim: true,
      outline: [] of MnemodocServer::Indexer::OutlineEntry,
      chunks: [] of MnemodocServer::Chunk,
    )
    expect(doc.line_count).to eq(3)
  end

  it "reports an empty document as empty everywhere" do
    doc = MnemodocServer::Indexer::Document.empty
    expect(doc.text).to be_empty
    expect(doc.chunks).to be_empty
    expect(doc.outline).to be_empty
    expect(doc.line_count).to eq(0)
    expect(doc.verbatim?).to be_false
  end
end
