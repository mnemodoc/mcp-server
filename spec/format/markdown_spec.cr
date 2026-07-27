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

  # This used to assert the opposite — that the title line became a preamble
  # chunk of its own. That was the defect, not the contract: such a chunk
  # carried nothing but the title, yet was embedded, indexed and returned.
  it "splits on ## headings, with the title as their parent" do
    chunks = chunks_for("# Title\n\n## Section A\n\nContent A.\n\n## Section B\n\nContent B.")
    expect(chunks.any?(&.heading.nil?)).to be_false
    expect(chunks.any? { |chunk| chunk.heading == "## Section A" }).to be_true
    expect(chunks.any? { |chunk| chunk.heading == "## Section B" }).to be_true
    expect(chunks.all? { |chunk| chunk.parent_heading == "# Title" }).to be_true
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

  # End-to-end strip through the Markdown handler: a pure breadcrumb is dropped
  # while real content and mixed text+link lines survive.
  context "with strip_link_only_lines enabled" do
    subject(stripping) do
      cfg = MnemodocServer::ChunkingConfig.from_yaml("strip_link_only_lines: true")
      MnemodocServer::Indexer::Format::Markdown.new(MnemodocServer::Indexer::ChunkAssembler.new(cfg))
    end

    it "drops a pure breadcrumb but keeps real content and mixed link lines" do
      content = <<-MD
      ## Section

      ← [Index](../README.md) — [Map](../MAP.md)

      See [the API reference](api.md) for details on authentication.
      MD
      File.write(tmp, content)
      chunks = stripping.extract(tmp, mtime: 1_i64)
      body = chunks.join(" ", &.content)
      expect(body).not_to contain("Index")
      expect(body).not_to contain("Map")
      expect(body).to contain("authentication")
    end
  end
  # A level-1 title was not recognised as a heading, so it fell into the
  # preamble and became a chunk whose entire content was the title line —
  # embedded, indexed, returned in results, and close enough to anything to
  # clear a similarity gate ("write me a haiku about cats" scored 0.510
  # against `# Indexing`). Org and AsciiDoc already accept their level-1
  # marker; Markdown was the outlier.
  describe "level-1 headings" do
    it "does not emit a chunk for a title with nothing under it" do
      chunks = chunks_for(<<-MD)
      # Indexing

      ## Excluding paths

      Glob patterns are skipped.
      MD
      expect(chunks.map(&.content)).not_to contain("# Indexing")
      expect(chunks.size).to eq(1)
    end

    it "makes the document title the parent of its sections" do
      chunks = chunks_for(<<-MD)
      # Indexing

      ## Excluding paths

      Glob patterns are skipped.
      MD
      section = chunks.first
      expect(section.heading).to eq("## Excluding paths")
      expect(section.parent_heading).to eq("# Indexing")
    end

    # A title followed by real prose still carries information: that prose is
    # a legitimate chunk and must survive.
    it "keeps an introduction written under the title" do
      chunks = chunks_for(<<-MD)
      # Indexing

      This document explains how files are selected.

      ## Excluding paths

      Glob patterns are skipped.
      MD
      intro = chunks.find { |chunk| chunk.content.includes?("how files are selected") }
      expect(intro).not_to be_nil
      expect(intro.try(&.heading)).to eq("# Indexing")
    end

    it "nests level 2 and 3 under it" do
      chunks = chunks_for(<<-MD)
      # Top

      ## Middle

      ### Leaf

      body text
      MD
      leaf = chunks.first
      expect(leaf.heading).to eq("### Leaf")
      expect(leaf.parent_heading).to eq("## Middle")
    end
  end
end
