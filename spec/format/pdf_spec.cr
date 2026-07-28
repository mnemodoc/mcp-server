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

  # Process.run has no timeout, so a pdftotext that never returns parks the
  # worker fiber for good. With index.concurrency workers, that many malformed
  # PDFs and the whole indexing run stops — waiting on results that will not
  # come, with nothing logged to say why.
  it "gives up on a converter that never returns" do
    hang = File.join(Dir.tempdir, "hang-#{Random::Secure.hex(4)}.sh")
    # exec, so the script IS the sleeping process: killing a shell that
    # merely spawned it would leave the child holding the output pipe.
    File.write(hang, "#!/bin/sh\nexec sleep 300\n")
    File.chmod(hang, 0o755)
    pdf = File.join(Dir.tempdir, "slow-#{Random::Secure.hex(4)}.pdf")
    File.write(pdf, "%PDF-1.4\n")

    handler = MnemodocServer::Indexer::Format::Pdf.new(
      MnemodocServer::Indexer::ChunkAssembler.new, command: hang, timeout: 1.second)
    begin
      started = Time.monotonic
      chunks = handler.extract(pdf, 1_i64)
      elapsed = Time.monotonic - started
      expect(chunks).to be_empty
      expect(elapsed).to be < 30.seconds
    ensure
      File.delete(hang) rescue nil
      File.delete(pdf) rescue nil
    end
  end
end
