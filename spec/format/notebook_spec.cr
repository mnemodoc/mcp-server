# spec/format/notebook_spec.cr
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Notebook do
  let(assembler) { MnemodocServer::Indexer::ChunkAssembler.new }
  let(markdown) { MnemodocServer::Indexer::Format::Markdown.new(assembler) }
  subject(handler) { MnemodocServer::Indexer::Format::Notebook.new(markdown, assembler) }
  let(tmp) { "/tmp/mnemodoc-ipynb-#{Random::Secure.hex(4)}.ipynb" }
  after_each { File.delete(tmp) rescue nil }

  it "parses markdown cells into sections and attaches code under the last heading" do
    nb = {
      "cells" => [
        {"cell_type" => "markdown", "source" => ["## Setup\n", "explain"]},
        {"cell_type" => "code", "source" => ["import os\n", "print(os)"]},
      ],
    }.to_json
    File.write(tmp, nb)
    chunks = handler.extract(tmp, mtime: 1_i64)
    setup = chunks.find! { |chunk| chunk.heading == "## Setup" }
    expect(setup.content).to contain("explain")
    expect(setup.content).to contain("import os")
  end

  it "returns empty array on invalid JSON" do
    File.write(tmp, "{ not json")
    expect(handler.extract(tmp, mtime: 1_i64)).to be_empty
  end
end
