require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Fodp do
  let(assembler) { MnemodocServer::Indexer::ChunkAssembler.new }
  let(odp) { MnemodocServer::Indexer::Format::Odp.new(assembler) }
  subject(handler) { MnemodocServer::Indexer::Format::Fodp.new(assembler, odp) }
  let(tmp) { "/tmp/mnemodoc-fodp-#{Random::Secure.hex(4)}.fodp" }
  after_each { File.delete(tmp) rescue nil }

  it "gathers slide paragraph text into one headingless section" do
    File.write(tmp, <<-XML)
    <office xmlns:office="urn:o" xmlns:text="urn:t" xmlns:draw="urn:d">
      <office:body><office:presentation>
        <draw:page><draw:frame><draw:text-box>
          <text:p>first slide</text:p>
        </draw:text-box></draw:frame></draw:page>
        <draw:page><draw:frame><draw:text-box>
          <text:p>second slide</text:p>
        </draw:text-box></draw:frame></draw:page>
      </office:presentation></office:body>
    </office>
    XML
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.size).to eq(1)
    expect(chunks.first.heading).to be_nil
    expect(chunks.first.content).to contain("first slide")
    expect(chunks.first.content).to contain("second slide")
  end

  it "returns an empty array when the file is unreadable" do
    expect(handler.extract("/tmp/none-#{Random::Secure.hex(4)}.fodp", mtime: 1_i64)).to be_empty
  end
end
