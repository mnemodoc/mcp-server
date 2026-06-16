# spec/format/rst_spec.cr
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Rst do
  subject(handler) { MnemodocServer::Indexer::Format::Rst.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-rst-#{Random::Secure.hex(4)}.rst" }
  after_each { File.delete(tmp) rescue nil }

  it "assigns levels by order of first appearance of the underline character" do
    content = <<-RST
    Top Title
    =========

    intro

    First Section
    -------------

    body a

    Second Section
    --------------

    body b
    RST
    chunks = handler.extract(tmp_write(content), mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Top Title", "First Section", "Second Section"])
    # `=` seen first => level 1 (parent nil); `-` second => level 2 (parent = Top Title)
    expect(chunks.map(&.parent_heading)).to eq([nil, "Top Title", "Top Title"])
  end

  # RST link markup reaches section bodies verbatim, so strip_link_only_lines
  # must drop pure-breadcrumb lines while keeping mixed text+link lines intact.
  context "with strip_link_only_lines enabled" do
    subject(stripping) do
      cfg = MnemodocServer::ChunkingConfig.from_yaml("strip_link_only_lines: true")
      MnemodocServer::Indexer::Format::Rst.new(MnemodocServer::Indexer::ChunkAssembler.new(cfg))
    end

    it "drops a pure breadcrumb but keeps real content and mixed link lines" do
      content = <<-RST
      Section
      =======

      `Home <index.html>`_ | `API <api.html>`_ | `Reference <reference.html>`_

      See `the configuration guide <config.html>`_ for full details on all options.
      RST
      File.write(tmp, content)
      chunks = stripping.extract(tmp, mtime: 1_i64)
      body = chunks.join(" ", &.content)
      expect(body).not_to contain("Home")
      expect(body).to contain("for full details on all options")
    end
  end

  private def tmp_write(content : String) : String
    File.write(tmp, content)
    tmp
  end
end
