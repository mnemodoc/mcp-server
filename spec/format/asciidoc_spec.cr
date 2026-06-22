# spec/format/asciidoc_spec.cr
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::AsciiDoc do
  subject(handler) { MnemodocServer::Indexer::Format::AsciiDoc.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-adoc-#{Random::Secure.hex(4)}.adoc" }
  after_each { File.delete(tmp) rescue nil }

  it "splits on == and === with parent set" do
    File.write(tmp, "= Title\nintro\n== Section\nbody\n=== Sub\nsub body")
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["= Title", "== Section", "=== Sub"])
    expect(chunks.map(&.parent_heading)).to eq([nil, "= Title", "== Section"])
  end

  # AsciiDoc link macros, URL macros and cross-references reach section bodies
  # verbatim, so strip_link_only_lines must drop pure-breadcrumb lines while
  # keeping mixed text+link lines intact.
  context "with strip_link_only_lines enabled" do
    subject(stripping) do
      cfg = MnemodocServer::ChunkingConfig.from_yaml("strip_link_only_lines: true")
      MnemodocServer::Indexer::Format::AsciiDoc.new(MnemodocServer::Indexer::ChunkAssembler.new(cfg))
    end

    it "drops a pure breadcrumb but keeps real content and mixed link lines" do
      content = <<-ADOC
      == Section
      link:index.adoc[Home] | <<installation,Installation>> | https://example.com/api[API]

      Visit https://ollama.com[ollama.com] to download the model before running the server.
      ADOC
      File.write(tmp, content)
      chunks = stripping.extract(tmp, mtime: 1_i64)
      body = chunks.join(" ", &.content)
      expect(body).not_to contain("Home")
      expect(body).not_to contain("Installation")
      expect(body).to contain("download the model")
    end
  end
end
