require "../spec_helper"
require "file_utils"

# The contract every format handler owes the crawler, tested once for all of
# them rather than restated per handler: whatever the bytes on disk, extract
# returns chunks or an empty array, and never raises.
#
# A raise here does not merely lose one file. The crawler catches it, so the
# file is left unindexed and its mtime unrecorded — which means the next run
# tries again, fails again, and the daemon's watcher repeats that on every
# tick, forever.
Spectator.describe "format handler contract" do
  let(tmp_dir) { "/tmp/mnemodoc-contract-#{Random::Secure.hex(4)}" }
  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Every extension the registry dispatches on, taken from the handlers' own
  # declarations so this list cannot drift from them.
  private def all_extensions : Array(String)
    [
      MnemodocServer::Indexer::Format::Markdown::EXTENSIONS,
      MnemodocServer::Indexer::Format::Org::EXTENSIONS,
      MnemodocServer::Indexer::Format::AsciiDoc::EXTENSIONS,
      MnemodocServer::Indexer::Format::Rst::EXTENSIONS,
      MnemodocServer::Indexer::Format::Html::EXTENSIONS,
      MnemodocServer::Indexer::Format::Notebook::EXTENSIONS,
      MnemodocServer::Indexer::Format::Plain::EXTENSIONS,
      MnemodocServer::Indexer::Format::Docx::EXTENSIONS,
      MnemodocServer::Indexer::Format::Odt::EXTENSIONS,
      MnemodocServer::Indexer::Format::Pptx::EXTENSIONS,
      MnemodocServer::Indexer::Format::Epub::EXTENSIONS,
      MnemodocServer::Indexer::Format::Odp::EXTENSIONS,
      MnemodocServer::Indexer::Format::Fodt::EXTENSIONS,
      MnemodocServer::Indexer::Format::Fodp::EXTENSIONS,
      MnemodocServer::Indexer::Format::DocBook::EXTENSIONS,
      MnemodocServer::Indexer::Format::Dita::EXTENSIONS,
      MnemodocServer::Indexer::Format::FictionBook::EXTENSIONS,
    ].flatten
  end

  private def registry : MnemodocServer::Indexer::Format::Registry
    MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml(""))
  end

  # "Café text" in latin-1: 0xE9 is a perfectly ordinary byte in a French file
  # written by an older editor, and not valid UTF-8.
  private def latin1_bytes : Bytes
    Bytes[0x43, 0x61, 0x66, 0xE9, 0x20, 0x74, 0x65, 0x78, 0x74, 0x0A]
  end

  private def extract_all(bytes : Bytes) : Array(String)
    reg = registry
    failures = [] of String
    all_extensions.each do |ext|
      path = File.join(tmp_dir, "sample#{ext}")
      File.write(path, bytes)
      begin
        reg.for(path, explicit: true).try(&.extract(path, 0_i64))
      rescue ex
        failures << "#{ext} -> #{ex.class}: #{ex.message}"
      end
    end
    failures
  end

  it "never raises on content that is not valid UTF-8" do
    expect(extract_all(latin1_bytes)).to be_empty
  end

  it "never raises on arbitrary binary content" do
    expect(extract_all(Bytes[0x00, 0xFF, 0xFE, 0x01, 0x80, 0x00, 0xC3])).to be_empty
  end

  # The counterpart of the two above: making bad bytes survivable must not cost
  # the accents of the files that were fine all along.
  it "preserves valid UTF-8 accents" do
    path = File.join(tmp_dir, "accents.md")
    File.write(path, "# Déploiement\n\n## Prérequis\n\nUn café, une clé SSH.\n")
    handler = registry.for(path, explicit: true)
    expect(handler).not_to be_nil
    chunks = handler.try(&.extract(path, 0_i64)) || [] of MnemodocServer::Chunk
    expect(chunks.map(&.content).join("\n")).to contain("Un café, une clé SSH.")
  end

  # A notebook is JSON, and JSON that parses is not necessarily a notebook.
  it "never raises on JSON that parses but is not a notebook" do
    [%([1, 2]), %("just a string"), %({"cells": ["oops"]}), %({"cells": [{"cell_type": 3}]})].each do |body|
      path = File.join(tmp_dir, "nb-#{Random::Secure.hex(2)}.ipynb")
      File.write(path, body)
      handler = registry.for(path, explicit: true)
      expect(handler).not_to be_nil
      expect { handler.try(&.extract(path, 0_i64)) }.not_to raise_error
    end
  end
end
