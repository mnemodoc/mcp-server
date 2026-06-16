# spec/format/rst_spec.cr
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Rst do
  subject(handler) { MnemodocServer::Indexer::Format::Rst.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-rst-#{Random::Secure.hex(4)}.rst" }
  after_each { File.delete(tmp) rescue nil }

  it "assigns levels by order of first appearance of the underline character" do
    content = <<-RST
    Top Title
    =========

    intro

    First Section
    -------------

    body a

    Second Section
    --------------

    body b
    RST
    chunks = handler.extract(tmp_write(content), mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Top Title", "First Section", "Second Section"])
    # `=` seen first => level 1 (parent nil); `-` second => level 2 (parent = Top Title)
    expect(chunks.map(&.parent_heading)).to eq([nil, "Top Title", "Top Title"])
  end

  private def tmp_write(content : String) : String
    File.write(tmp, content)
    tmp
  end
end
