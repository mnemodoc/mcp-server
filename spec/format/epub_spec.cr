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
    chunks = handler.extract(tmp, mtime: 1_i64).chunks
    expect(chunks.map(&.heading)).to eq(["Chapter One", "Chapter Two"])
    expect(chunks.first.content).to contain("alpha")
  end

  it "returns an empty array for a corrupt (non-zip) file" do
    File.write(tmp, "not a zip")
    expect(handler.extract(tmp, mtime: 1_i64).chunks).to be_empty
  end

  # Alphabetical order is not reading order: ch10 sorts before ch2. The book's
  # own order lives in the OPF spine, and chunks carry the document's sequence,
  # so getting it wrong scrambles which chapter a passage belongs to.
  it "follows the spine's order, not the filenames'" do
    File.open(tmp, "w") do |file|
      Compress::Zip::Writer.open(file) do |zip|
        zip.add("META-INF/container.xml", <<-XML)
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
        </container>
        XML
        zip.add("OEBPS/content.opf", <<-XML)
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="c2" href="ch2.xhtml"/>
            <item id="c10" href="ch10.xhtml"/>
          </manifest>
          <spine><itemref idref="c2"/><itemref idref="c10"/></spine>
        </package>
        XML
        zip.add("OEBPS/ch2.xhtml", "<html><body><h1>Deux</h1><p>second chapter</p></body></html>")
        zip.add("OEBPS/ch10.xhtml", "<html><body><h1>Dix</h1><p>tenth chapter</p></body></html>")
      end
    end

    chunks = handler.extract(tmp, mtime: 1_i64).chunks
    expect(chunks.map(&.heading)).to eq(["Deux", "Dix"])
  end
end
