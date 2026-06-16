# spec/format/markdown_spec.cr
require "../spec_helper"
require "file_utils"

Spectator.describe MnemodocServer::Indexer::Format::Markdown do
  subject(handler) { MnemodocServer::Indexer::Format::Markdown.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-md-#{Random::Secure.hex(4)}.md" }
  after_each { File.delete(tmp) rescue nil }

  private def chunks_for(content : String)
    File.write(tmp, content)
    handler.extract(tmp, mtime: 1000_i64)
  end

  it "returns one chunk for a file with no headings" do
    chunks = chunks_for("Just some text\nwith no headings.")
    expect(chunks.size).to eq(1)
    expect(chunks.first.heading).to be_nil
    expect(chunks.first.content).to eq("Just some text\nwith no headings.")
  end

  it "splits on ## headings with a preamble for the title line" do
    chunks = chunks_for("# Title\n\n## Section A\n\nContent A.\n\n## Section B\n\nContent B.")
    expect(chunks.any?(&.heading.nil?)).to be_true
    expect(chunks.any? { |chunk| chunk.heading == "## Section A" }).to be_true
    expect(chunks.any? { |chunk| chunk.heading == "## Section B" }).to be_true
  end

  it "splits on ### sub-headings with parent set" do
    chunks = chunks_for("## Section A\n\nIntro A.\n\n### SubA1\n\nsub 1.\n\n### SubA2\n\nsub 2.")
    sub = chunks.select { |chunk| chunk.heading.try(&.starts_with?("### ")) }
    expect(sub.size).to eq(2)
    expect(sub.all? { |chunk| chunk.parent_heading == "## Section A" }).to be_true
  end

  it "skips frontmatter YAML" do
    chunks = chunks_for("---\ntitle: My Doc\n---\n\n## Section\n\nReal content.")
    expect(chunks.first.content).not_to contain("title: My Doc")
    expect(chunks.first.content).to contain("Real content")
  end

  it "indexes .mdx through the same path" do
    File.write(tmp, "## H\n\n<Component/> text")
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.first.content).to contain("text")
  end

  it "returns empty array when the file is unreadable" do
    expect(handler.extract("/tmp/does-not-exist-#{Random::Secure.hex(4)}.md", mtime: 1_i64)).to be_empty
  end
end
