# spec/chunk_assembler_spec.cr
require "./spec_helper"

Spectator.describe MnemodocServer::Indexer::ChunkAssembler do
  subject(assembler) { MnemodocServer::Indexer::ChunkAssembler.new }
  let(s) { MnemodocServer::Indexer::Section }

  it "produces one chunk for a single small section" do
    sections = [s.new(nil, nil, "Just some text\nwith no headings.")]
    chunks = assembler.assemble("doc/foo.md", sections, "ignored", mtime: 1000_i64)
    expect(chunks.size).to eq(1)
    expect(chunks.first.heading).to be_nil
    expect(chunks.first.content).to eq("Just some text\nwith no headings.")
  end

  it "treats whole raw_content as a preamble when sections is empty" do
    chunks = assembler.assemble("doc/foo.txt", [] of MnemodocServer::Indexer::Section, "plain body", mtime: 1_i64)
    expect(chunks.size).to eq(1)
    expect(chunks.first.heading).to be_nil
    expect(chunks.first.content).to eq("plain body")
  end

  it "returns no chunks for blank content" do
    chunks = assembler.assemble("doc/foo.txt", [] of MnemodocServer::Indexer::Section, "   \n  ", mtime: 1_i64)
    expect(chunks).to be_empty
  end

  it "sets file_path and mtime on all chunks" do
    sections = [s.new("## A", nil, "content")]
    chunks = assembler.assemble("doc/bar.md", sections, "x", mtime: 9999_i64)
    chunks.each do |chunk|
      expect(chunk.file_path).to eq("doc/bar.md")
      expect(chunk.mtime).to eq(9999_i64)
    end
  end

  it "skips table-of-contents sections" do
    sections = [
      s.new("## Table des matières", nil, "- [A](#a)"),
      s.new("## Real", nil, "Real content."),
    ]
    chunks = assembler.assemble("doc/foo.md", sections, "x", mtime: 1_i64)
    expect(chunks.any? { |chunk| chunk.heading == "## Table des matières" }).to be_false
    expect(chunks.any? { |chunk| chunk.heading == "## Real" }).to be_true
  end

  it "splits an oversized section so no chunk exceeds MAX_TOKENS" do
    rows = (1..800).map { |i| "| col_a_#{i} | col_b_#{i} | col_c_#{i} |" }.join("\n")
    sections = [s.new("## Big", nil, rows)]
    chunks = assembler.assemble("doc/big.md", sections, "x", mtime: 1_i64)
    expect(chunks.size).to be > 1
    chunks.each { |chunk| expect(chunk.token_count).to be <= MnemodocServer::Indexer::ChunkAssembler::MAX_TOKENS }
  end

  it "slices a very long single line into within-limit chunks" do
    sections = [s.new("## Long", nil, "x " * 5000)]
    chunks = assembler.assemble("doc/long.md", sections, "x", mtime: 1_i64)
    expect(chunks.size).to be > 1
    chunks.each { |chunk| expect(chunk.token_count).to be <= MnemodocServer::Indexer::ChunkAssembler::MAX_TOKENS }
  end
end
