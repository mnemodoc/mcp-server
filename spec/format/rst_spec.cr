# spec/format/rst_spec.cr
require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Rst do
  subject(handler) { MnemodocServer::Indexer::Format::Rst.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-rst-#{Random::Secure.hex(4)}.rst" }
  after_each { File.delete(tmp) rescue nil }

  # A title spans two or three lines. start_line designates the title text
  # line, not its adornment — otherwise a framed title reports the rule above
  # it, which is not where the section begins.
  it "starts an underlined title on its text line" do
    document = handler.extract(tmp_write("intro\n\nTitle\n=====\n\nbody\n"), mtime: 1_i64)
    expect(document.outline.map(&.title)).to eq(["Title"])
    expect(document.outline.first.start_line).to eq(3)
  end

  it "starts a framed title on its text line, not on the overline" do
    document = handler.extract(tmp_write("=====\nTitle\n=====\n\nbody\n"), mtime: 1_i64)
    expect(document.outline.first.start_line).to eq(2)
  end

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
    chunks = handler.extract(tmp_write(content), mtime: 1_i64).chunks
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
      chunks = stripping.extract(tmp, mtime: 1_i64).chunks
      body = chunks.join(" ", &.content)
      expect(body).not_to contain("Home")
      expect(body).to contain("for full details on all options")
    end
  end

  private def tmp_write(content : String) : String
    File.write(tmp, content)
    tmp
  end

  # reStructuredText allows a title to be framed above and below. The parser
  # only knew the underlined form, so the top rule was consumed as body text
  # and ended up inside the preceding chunk.
  it "recognises a title framed above and below" do
    File.write(tmp, "======\nTitre\n======\n\nCorps du texte.\n")
    chunks = handler.extract(tmp, mtime: 1_i64).chunks
    expect(chunks.map(&.heading)).to eq(["Titre"])
    expect(chunks.first.content).to eq("Corps du texte.")
  end
end
