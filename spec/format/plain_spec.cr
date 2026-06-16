# spec/format/plain_spec.cr
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Plain do
  subject(handler) { MnemodocServer::Indexer::Format::Plain.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-plain-#{Random::Secure.hex(4)}.txt" }
  after_each { File.delete(tmp) rescue nil }

  it "produces a single headingless chunk for short text" do
    File.write(tmp, "line one\nline two")
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.size).to eq(1)
    expect(chunks.first.heading).to be_nil
    expect(chunks.first.content).to eq("line one\nline two")
  end

  it "splits long text so no chunk exceeds the budget" do
    File.write(tmp, "word " * 6000)
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.size).to be > 1
    chunks.each { |chunk| expect(chunk.token_count).to be <= MnemodocServer::Indexer::ChunkAssembler::MAX_TOKENS }
  end

  it "returns empty array when unreadable" do
    expect(handler.extract("/tmp/none-#{Random::Secure.hex(4)}.txt", mtime: 1_i64)).to be_empty
  end
end
