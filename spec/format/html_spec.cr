# spec/format/html_spec.cr
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Html do
  subject(handler) { MnemodocServer::Indexer::Format::Html.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-html-#{Random::Secure.hex(4)}.html" }
  after_each { File.delete(tmp) rescue nil }

  it "splits on h1/h2 headings with parent set and strips script/style" do
    html = <<-HTML
    <html><head><title>ignored</title></head><body>
    <h1>Top</h1><p>intro text</p>
    <h2>Sub</h2><p>sub text</p>
    <script>var x = 1;</script>
    </body></html>
    HTML
    File.write(tmp, html)
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Top", "Sub"])
    expect(chunks.map(&.parent_heading)).to eq([nil, "Top"])
    expect(chunks[0].content).to contain("intro text")
    expect(chunks.join(" ", &.content)).not_to contain("var x")
  end

  it "returns empty array when unreadable" do
    expect(handler.extract("/tmp/none-#{Random::Secure.hex(4)}.html", mtime: 1_i64)).to be_empty
  end

  it "exposes parse_sections that splits HTML text into sections by heading" do
    sections = handler.parse_sections("<h1>Top</h1><p>intro</p><h2>Sub</h2><p>more</p>")
    expect(sections.map(&.heading)).to eq(["Top", "Sub"])
    expect(sections.map(&.parent_heading)).to eq([nil, "Top"])
    expect(sections.first.body).to contain("intro")
  end
end
