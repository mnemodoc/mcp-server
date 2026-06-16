require "file_utils"
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Pdf do
  let(assembler) { MnemodocServer::Indexer::ChunkAssembler.new }
  let(dir) { "/tmp/mnemodoc-pdf-#{Random::Secure.hex(4)}" }
  let(pdf) { File.join(dir, "doc.pdf") }
  before_each do
    Dir.mkdir_p(dir)
    File.write(pdf, "%PDF-1.4 fake")
  end
  after_each { FileUtils.rm_rf(dir) }

  # Writes an executable fake "pdftotext" that emits text and exits 0.
  private def fake_ok : String
    script = File.join(dir, "pdftotext-ok")
    File.write(script, "#!/bin/sh\necho \"## Heading\\n\\nextracted body\"\n")
    File.chmod(script, 0o755)
    script
  end

  # Writes an executable fake that exits non-zero.
  private def fake_fail : String
    script = File.join(dir, "pdftotext-fail")
    File.write(script, "#!/bin/sh\nexit 1\n")
    File.chmod(script, 0o755)
    script
  end

  it "produces chunks from extracted text on success" do
    handler = MnemodocServer::Indexer::Format::Pdf.new(assembler, command: fake_ok)
    chunks = handler.extract(pdf, mtime: 1_i64)
    expect(chunks.any?(&.content.includes?("extracted body"))).to be_true
  end

  it "returns empty array when pdftotext exits non-zero" do
    handler = MnemodocServer::Indexer::Format::Pdf.new(assembler, command: fake_fail)
    expect(handler.extract(pdf, mtime: 1_i64)).to be_empty
  end

  it "returns empty array when the command does not exist" do
    handler = MnemodocServer::Indexer::Format::Pdf.new(assembler, command: "/nonexistent/pdftotext")
    expect(handler.extract(pdf, mtime: 1_i64)).to be_empty
  end
end
