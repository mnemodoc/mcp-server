require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Fodt do
  let(assembler) { MnemodocServer::Indexer::ChunkAssembler.new }
  let(odt) { MnemodocServer::Indexer::Format::Odt.new(assembler) }
  subject(handler) { MnemodocServer::Indexer::Format::Fodt.new(assembler, odt) }
  let(tmp) { "/tmp/mnemodoc-fodt-#{Random::Secure.hex(4)}.fodt" }
  after_each { File.delete(tmp) rescue nil }

  it "parses a flat ODF document reusing the Odt walk" do
    File.write(tmp, <<-XML)
    <office xmlns:office="urn:o" xmlns:text="urn:t">
      <office:body><office:text>
        <text:h text:outline-level="1">Top</text:h>
        <text:p>intro</text:p>
        <text:h text:outline-level="2">Sub</text:h>
        <text:p>sub body</text:p>
      </office:text></office:body>
    </office>
    XML
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Top", "Sub"])
    expect(chunks.map(&.parent_heading)).to eq([nil, "Top"])
  end

  it "returns an empty array when the file is unreadable" do
    expect(handler.extract("/tmp/none-#{Random::Secure.hex(4)}.fodt", mtime: 1_i64)).to be_empty
  end
end
