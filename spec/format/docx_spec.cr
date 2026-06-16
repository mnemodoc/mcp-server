require "../spec_helper"
require "compress/zip"

Spectator.describe MnemodocServer::Indexer::Format::Docx do
  subject(handler) { MnemodocServer::Indexer::Format::Docx.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-docx-#{Random::Secure.hex(4)}.docx" }
  after_each { File.delete(tmp) rescue nil }

  # Writes a minimal .docx (a zip whose only part is word/document.xml).
  private def write_docx(document_xml : String) : String
    File.open(tmp, "w") do |file|
      Compress::Zip::Writer.open(file) { |zip| zip.add("word/document.xml", document_xml) }
    end
    tmp
  end

  it "splits on heading styles and concatenates a paragraph's runs" do
    doc = <<-XML
    <w:document xmlns:w="urn:w">
      <w:body>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Intro</w:t></w:r></w:p>
        <w:p><w:r><w:t>body </w:t></w:r><w:r><w:t>joined.</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Sub</w:t></w:r></w:p>
        <w:p><w:r><w:t>sub body</w:t></w:r></w:p>
      </w:body>
    </w:document>
    XML
    chunks = handler.extract(write_docx(doc), mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Intro", "Sub"])
    expect(chunks.map(&.parent_heading)).to eq([nil, "Intro"])
    expect(chunks.first.content).to contain("body joined.")
  end

  it "treats an unrecognized style as body text, not a heading" do
    doc = <<-XML
    <w:document xmlns:w="urn:w">
      <w:body>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Real</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr><w:r><w:t>quoted line</w:t></w:r></w:p>
      </w:body>
    </w:document>
    XML
    chunks = handler.extract(write_docx(doc), mtime: 1_i64)
    expect(chunks.any? { |chunk| chunk.heading == "Quote" }).to be_false
    expect(chunks.first.content).to contain("quoted line")
  end

  it "returns an empty array for a corrupt (non-zip) file" do
    File.write(tmp, "this is not a zip")
    expect(handler.extract(tmp, mtime: 1_i64)).to be_empty
  end

  it "returns an empty array when word/document.xml is absent" do
    File.open(tmp, "w") do |file|
      Compress::Zip::Writer.open(file, &.add("other.xml", "<x/>"))
    end
    expect(handler.extract(tmp, mtime: 1_i64)).to be_empty
  end
end
