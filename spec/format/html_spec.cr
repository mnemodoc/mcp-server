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

  # HTML is a DOM format: the walk flattens <a> elements to their inner text
  # before anything reaches a body, so strip_link_only_lines has no link markup
  # to match and is a correct no-op. merge_preamble_into_first_section is the
  # lever for HTML: it folds the pre-heading preamble into the first section.
  it "leaves anchor text in place under strip but folds the preamble under merge" do
    html = <<-HTML
    <html><body>
    <p><a href="index.html">Home</a> | <a href="api.html">API</a></p>
    <h2>Section</h2><p>real content here</p>
    </body></html>
    HTML
    File.write(tmp, html)

    cfg = MnemodocServer::ChunkingConfig.from_yaml("strip_link_only_lines: true\nmerge_preamble_into_first_section: true")
    folding = MnemodocServer::Indexer::Format::Html.new(MnemodocServer::Indexer::ChunkAssembler.new(cfg))
    chunks = folding.extract(tmp, mtime: 1_i64)

    # No standalone preamble chunk: the (flattened) breadcrumb text rides with
    # the section, and the anchor text survives because strip cannot see it.
    expect(chunks.any?(&.heading.nil?)).to be_false
    merged = chunks.find! { |chunk| chunk.heading == "Section" }
    expect(merged.content).to contain("Home")
    expect(merged.content).to contain("real content here")
  end
end
