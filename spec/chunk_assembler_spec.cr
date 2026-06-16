# spec/chunk_assembler_spec.cr
require "./spec_helper"

Spectator.describe MnemodocServer::Indexer::ChunkAssembler do
  subject(assembler) { MnemodocServer::Indexer::ChunkAssembler.new }
  let(s) { MnemodocServer::Indexer::Section }

  it "produces one chunk for a single small section" do
    sections = [s.new(nil, nil, "Just some text\nwith no headings.")]
    chunks = assembler.assemble("doc/foo.md", sections, "ignored", mtime: 1000_i64)
    expect(chunks.size).to eq(1)
    expect(chunks.first.heading).to be_nil
    expect(chunks.first.content).to eq("Just some text\nwith no headings.")
  end

  it "treats whole raw_content as a preamble when sections is empty" do
    chunks = assembler.assemble("doc/foo.txt", [] of MnemodocServer::Indexer::Section, "plain body", mtime: 1_i64)
    expect(chunks.size).to eq(1)
    expect(chunks.first.heading).to be_nil
    expect(chunks.first.content).to eq("plain body")
  end

  it "returns no chunks for blank content" do
    chunks = assembler.assemble("doc/foo.txt", [] of MnemodocServer::Indexer::Section, "   \n  ", mtime: 1_i64)
    expect(chunks).to be_empty
  end

  it "sets file_path and mtime on all chunks" do
    sections = [s.new("## A", nil, "content")]
    chunks = assembler.assemble("doc/bar.md", sections, "x", mtime: 9999_i64)
    chunks.each do |chunk|
      expect(chunk.file_path).to eq("doc/bar.md")
      expect(chunk.mtime).to eq(9999_i64)
    end
  end

  it "skips table-of-contents sections" do
    sections = [
      s.new("## Table des matières", nil, "- [A](#a)"),
      s.new("## Real", nil, "Real content."),
    ]
    chunks = assembler.assemble("doc/foo.md", sections, "x", mtime: 1_i64)
    expect(chunks.any? { |chunk| chunk.heading == "## Table des matières" }).to be_false
    expect(chunks.any? { |chunk| chunk.heading == "## Real" }).to be_true
  end

  it "splits an oversized section so no chunk exceeds MAX_TOKENS" do
    rows = (1..800).map { |i| "| col_a_#{i} | col_b_#{i} | col_c_#{i} |" }.join("\n")
    sections = [s.new("## Big", nil, rows)]
    chunks = assembler.assemble("doc/big.md", sections, "x", mtime: 1_i64)
    expect(chunks.size).to be > 1
    chunks.each { |chunk| expect(chunk.token_count).to be <= MnemodocServer::Indexer::ChunkAssembler::MAX_TOKENS }
  end

  it "slices a very long single line into within-limit chunks" do
    sections = [s.new("## Long", nil, "x " * 5000)]
    chunks = assembler.assemble("doc/long.md", sections, "x", mtime: 1_i64)
    expect(chunks.size).to be > 1
    chunks.each { |chunk| expect(chunk.token_count).to be <= MnemodocServer::Indexer::ChunkAssembler::MAX_TOKENS }
  end

  describe ".link_only_line?" do
    it "is false for a blank line (handled elsewhere)" do
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?("   ")).to be_false
    end

    it "is false for a line mixing text and a link" do
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?("Voir [X](y) pour les détails.")).to be_false
    end

    it "is true for a pure breadcrumb of links and separators" do
      line = "← [Index](../README.md) — [Racine](../../README.md) — [Carte](../../MAP.md)"
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?(line)).to be_true
    end

    it "is true for a single bare link" do
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?("[Index](../README.md)")).to be_true
    end

    # --- Org-mode (detection scoped to ORG_LINKS) ---
    it "is true for an Org breadcrumb of bracketed links" do
      line = "[[file:index.org][Home]] — [[file:api.org][API]] — [[file:guide.org][Guide]]"
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?(line, MnemodocServer::Indexer::ChunkAssembler::ORG_LINKS)).to be_true
    end

    it "is false for an Org line mixing text and a link" do
      line = "See [[file:api.org][the API reference]] for details on authentication."
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?(line, MnemodocServer::Indexer::ChunkAssembler::ORG_LINKS)).to be_false
    end

    # --- AsciiDoc (detection scoped to ASCIIDOC_LINKS) ---
    it "is true for an AsciiDoc breadcrumb of link macros and xrefs" do
      line = "link:index.adoc[Home] | <<installation,Installation>> | https://example.com/api[API]"
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?(line, MnemodocServer::Indexer::ChunkAssembler::ASCIIDOC_LINKS)).to be_true
    end

    it "is false for an AsciiDoc line mixing text and a link" do
      line = "See link:api.adoc[the API reference] for the full list of parameters."
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?(line, MnemodocServer::Indexer::ChunkAssembler::ASCIIDOC_LINKS)).to be_false
    end

    # --- reStructuredText (detection scoped to RST_LINKS) ---
    it "is true for an RST breadcrumb of named references" do
      line = "`Home <index.html>`_ | `API <api.html>`_ | `Reference <reference.html>`_"
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?(line, MnemodocServer::Indexer::ChunkAssembler::RST_LINKS)).to be_true
    end

    it "is false for an RST line mixing text and a link" do
      line = "See `the configuration guide <config.html>`_ for full details on all options."
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?(line, MnemodocServer::Indexer::ChunkAssembler::RST_LINKS)).to be_false
    end

    # --- No cross-format leakage (defends against over-stripping) ---
    # With the Markdown pattern set (the default), other formats' grammars must
    # NOT fire: a Markdown line of snake_case-trailing-underscore tokens or of
    # Hugo/Antora <<shortcodes>> is real content, not a breadcrumb.
    it "does not treat trailing-underscore words as links under Markdown" do
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?("deprecated_  removed_  experimental_")).to be_false
    end

    it "does not treat <<shortcodes>> as links under Markdown" do
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?("<<install>> | <<configure>>")).to be_false
    end

    # And those same tokens are no-ops even in the RST/AsciiDoc sets that the
    # over-broad patterns were removed from / scoped to.
    it "does not strip trailing-underscore words under RST (bare word_ form dropped)" do
      expect(MnemodocServer::Indexer::ChunkAssembler.link_only_line?("deprecated_  removed_", MnemodocServer::Indexer::ChunkAssembler::RST_LINKS)).to be_false
    end
  end

  describe ".link_patterns_for" do
    it "selects each line-based markup's own grammar by extension" do
      ca = MnemodocServer::Indexer::ChunkAssembler
      expect(ca.link_patterns_for("doc/x.md")).to eq(MnemodocServer::Indexer::ChunkAssembler::MARKDOWN_LINKS)
      expect(ca.link_patterns_for("doc/x.org")).to eq(MnemodocServer::Indexer::ChunkAssembler::ORG_LINKS)
      expect(ca.link_patterns_for("doc/x.adoc")).to eq(MnemodocServer::Indexer::ChunkAssembler::ASCIIDOC_LINKS)
      expect(ca.link_patterns_for("doc/x.rst")).to eq(MnemodocServer::Indexer::ChunkAssembler::RST_LINKS)
      # Unknown / DOM / plain → Markdown's unambiguous pattern (harmless no-op).
      expect(ca.link_patterns_for("doc/x.html")).to eq(MnemodocServer::Indexer::ChunkAssembler::MARKDOWN_LINKS)
      expect(ca.link_patterns_for("doc/x.txt")).to eq(MnemodocServer::Indexer::ChunkAssembler::MARKDOWN_LINKS)
    end
  end

  describe "chunking options" do
    # A document body: title, breadcrumb, description, then a real section.
    let(preamble) { "# Title\n\n← [Index](../README.md) — [Map](../MAP.md)\n\n**Description:** one-liner." }

    it "strip_link_only_lines drops the breadcrumb but keeps title and description" do
      cfg = MnemodocServer::ChunkingConfig.from_yaml("strip_link_only_lines: true")
      a = MnemodocServer::Indexer::ChunkAssembler.new(cfg)
      sections = [s.new(nil, nil, preamble), s.new("## Real", nil, "Real content.")]
      chunks = a.assemble("doc/foo.md", sections, "x", mtime: 1_i64)
      preamble_chunk = chunks.find! { |chunk| chunk.heading.nil? }
      expect(preamble_chunk.content).not_to contain("[Index]")
      expect(preamble_chunk.content).to contain("Title")
      expect(preamble_chunk.content).to contain("Description")
    end

    it "merge_preamble_into_first_section folds the preamble into the first section" do
      cfg = MnemodocServer::ChunkingConfig.from_yaml("merge_preamble_into_first_section: true")
      a = MnemodocServer::Indexer::ChunkAssembler.new(cfg)
      sections = [s.new(nil, nil, preamble), s.new("## Real", nil, "Real content.")]
      chunks = a.assemble("doc/foo.md", sections, "x", mtime: 1_i64)
      # No standalone preamble chunk remains; the description rides with the section.
      expect(chunks.any? { |chunk| chunk.heading.nil? }).to be_false
      merged = chunks.find! { |chunk| chunk.heading == "## Real" }
      expect(merged.content).to contain("Description")
      expect(merged.content).to contain("Real content.")
    end

    it "defaults leave a standalone preamble chunk unchanged (back-compat)" do
      sections = [s.new(nil, nil, preamble), s.new("## Real", nil, "Real content.")]
      chunks = assembler.assemble("doc/foo.md", sections, "x", mtime: 1_i64)
      preamble_chunk = chunks.find! { |chunk| chunk.heading.nil? }
      # Untouched: breadcrumb still present, preamble is its own chunk.
      expect(preamble_chunk.content).to contain("[Index]")
      expect(chunks.any? { |chunk| chunk.heading == "## Real" }).to be_true
    end
  end
end
