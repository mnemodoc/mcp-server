# spec/format/epub_spec.cr
require "../spec_helper"
require "compress/zip"

Spectator.describe MnemodocServer::Indexer::Format::Epub do
  let(assembler) { MnemodocServer::Indexer::ChunkAssembler.new }
  let(html) { MnemodocServer::Indexer::Format::Html.new(assembler) }
  subject(handler) { MnemodocServer::Indexer::Format::Epub.new(assembler, html) }
  let(tmp) { "/tmp/mnemodoc-epub-#{Random::Secure.hex(4)}.epub" }
  after_each { File.delete(tmp) rescue nil }

  it "concatenates sections from each XHTML chapter in filename order" do
    File.open(tmp, "w") do |file|
      Compress::Zip::Writer.open(file) do |zip|
        zip.add("OEBPS/ch1.xhtml", "<html><body><h1>Chapter One</h1><p>alpha</p></body></html>")
        zip.add("OEBPS/ch2.xhtml", "<html><body><h1>Chapter Two</h1><p>beta</p></body></html>")
        zip.add("META-INF/container.xml", "<container/>")
      end
    end
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Chapter One", "Chapter Two"])
    expect(chunks.first.content).to contain("alpha")
  end

  it "returns an empty array for a corrupt (non-zip) file" do
    File.write(tmp, "not a zip")
    expect(handler.extract(tmp, mtime: 1_i64)).to be_empty
  end
end
