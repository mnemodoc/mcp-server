# spec/format/odt_spec.cr
require "../spec_helper"
require "compress/zip"

Spectator.describe MnemodocServer::Indexer::Format::Odt do
  subject(handler) { MnemodocServer::Indexer::Format::Odt.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-odt-#{Random::Secure.hex(4)}.odt" }
  after_each { File.delete(tmp) rescue nil }

  # Writes a minimal .odt (a zip whose only part is content.xml).
  private def write_odt(content_xml : String) : String
    File.open(tmp, "w") do |file|
      Compress::Zip::Writer.open(file, &.add("content.xml", content_xml))
    end
    tmp
  end

  it "uses text:outline-level for heading levels and nests by parent" do
    content = <<-XML
    <office xmlns:office="urn:o" xmlns:text="urn:t">
      <office:body><office:text>
        <text:h text:outline-level="1">Top</text:h>
        <text:p>intro</text:p>
        <text:h text:outline-level="2">Sub</text:h>
        <text:p>sub body</text:p>
      </office:text></office:body>
    </office>
    XML
    chunks = handler.extract(write_odt(content), mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Top", "Sub"])
    expect(chunks.map(&.parent_heading)).to eq([nil, "Top"])
    expect(chunks.first.content).to contain("intro")
  end

  it "returns an empty array for a corrupt (non-zip) file" do
    File.write(tmp, "not a zip")
    expect(handler.extract(tmp, mtime: 1_i64)).to be_empty
  end
end
