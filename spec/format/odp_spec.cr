require "../spec_helper"
require "compress/zip"

Spectator.describe MnemodocServer::Indexer::Format::Odp do
  subject(handler) { MnemodocServer::Indexer::Format::Odp.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-odp-#{Random::Secure.hex(4)}.odp" }
  after_each { File.delete(tmp) rescue nil }

  # Writes a minimal .odp (a zip whose only part is content.xml).
  private def write_odp(content_xml : String) : String
    File.open(tmp, "w") do |file|
      Compress::Zip::Writer.open(file, &.add("content.xml", content_xml))
    end
    tmp
  end

  it "gathers slide paragraph text into one headingless section" do
    content = <<-XML
    <office xmlns:office="urn:o" xmlns:text="urn:t" xmlns:draw="urn:d">
      <office:body><office:presentation>
        <draw:page><draw:frame><draw:text-box>
          <text:p>first slide title</text:p>
          <text:p>first slide body</text:p>
        </draw:text-box></draw:frame></draw:page>
        <draw:page><draw:frame><draw:text-box>
          <text:p>second slide</text:p>
        </draw:text-box></draw:frame></draw:page>
      </office:presentation></office:body>
    </office>
    XML
    chunks = handler.extract(write_odp(content), mtime: 1_i64)
    expect(chunks.size).to eq(1)
    expect(chunks.first.heading).to be_nil
    body = chunks.first.content
    expect(body).to contain("first slide body")
    expect(body).to contain("second slide")
  end

  it "returns an empty array for a corrupt (non-zip) file" do
    File.write(tmp, "not a zip")
    expect(handler.extract(tmp, mtime: 1_i64)).to be_empty
  end
end
