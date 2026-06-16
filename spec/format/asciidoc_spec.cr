# spec/format/asciidoc_spec.cr
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::AsciiDoc do
  subject(handler) { MnemodocServer::Indexer::Format::AsciiDoc.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-adoc-#{Random::Secure.hex(4)}.adoc" }
  after_each { File.delete(tmp) rescue nil }

  it "splits on == and === with parent set" do
    File.write(tmp, "= Title\nintro\n== Section\nbody\n=== Sub\nsub body")
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["= Title", "== Section", "=== Sub"])
    expect(chunks.map(&.parent_heading)).to eq([nil, "= Title", "== Section"])
  end
end
