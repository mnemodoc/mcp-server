# spec/format/pptx_spec.cr
require "../spec_helper"
require "compress/zip"

Spectator.describe MnemodocServer::Indexer::Format::Pptx do
  subject(handler) { MnemodocServer::Indexer::Format::Pptx.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-pptx-#{Random::Secure.hex(4)}.pptx" }
  after_each { File.delete(tmp) rescue nil }

  it "reads slides in numeric order and concatenates their <a:t> text" do
    File.open(tmp, "w") do |file|
      Compress::Zip::Writer.open(file) do |zip|
        zip.add("ppt/slides/slide2.xml", %(<p:sld xmlns:a="urn:a"><a:t>second slide</a:t></p:sld>))
        zip.add("ppt/slides/slide1.xml", %(<p:sld xmlns:a="urn:a"><a:t>first slide</a:t></p:sld>))
        zip.add("ppt/presentation.xml", "<p:presentation/>")
      end
    end
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.size).to eq(1)
    expect(chunks.first.heading).to be_nil
    body = chunks.first.content
    expect(body).to contain("first slide")
    expect(body).to contain("second slide")
    expect(body.index!("first slide")).to be < body.index!("second slide")
  end

  it "returns an empty array for a corrupt (non-zip) file" do
    File.write(tmp, "not a zip")
    expect(handler.extract(tmp, mtime: 1_i64)).to be_empty
  end
end
