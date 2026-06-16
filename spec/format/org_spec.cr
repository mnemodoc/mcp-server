# spec/format/org_spec.cr
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Org do
  subject(handler) { MnemodocServer::Indexer::Format::Org.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-org-#{Random::Secure.hex(4)}.org" }
  after_each { File.delete(tmp) rescue nil }

  it "splits on * and ** with parent set" do
    File.write(tmp, "* Section A\nbody a\n** Sub A1\nsub body\n* Section B\nbody b")
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["* Section A", "** Sub A1", "* Section B"])
    expect(chunks.map(&.parent_heading)).to eq([nil, "* Section A", nil])
  end

  it "keeps preamble text before the first star heading" do
    File.write(tmp, "intro text\n* Heading\nbody")
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.first.heading).to be_nil
    expect(chunks.first.content).to contain("intro text")
  end
end
