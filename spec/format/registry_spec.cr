require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Registry do
  let(config) { MnemodocServer::Config.from_yaml("paths:\n  - x/") }

  it "dispatches known extensions case-insensitively" do
    registry = MnemodocServer::Indexer::Format::Registry.new(config)
    expect(registry.for("/a/b.md", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Markdown)
    expect(registry.for("/a/b.RST", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Rst)
    expect(registry.for("/a/b.ipynb", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Notebook)
    expect(registry.for("/a/b.docx", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Docx)
    expect(registry.for("/a/b.odt", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Odt)
    expect(registry.for("/a/b.pptx", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Pptx)
    expect(registry.for("/a/b.epub", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Epub)
    expect(registry.for("/a/b.odp", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Odp)
    # Macro-enabled and template variants dispatch to the same handlers.
    expect(registry.for("/a/b.docm", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Docx)
    expect(registry.for("/a/b.pptm", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Pptx)
    expect(registry.for("/a/b.ott", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Odt)
    expect(registry.for("/a/b.otp", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Odp)
    # Aliases of existing formats dispatch to the same handlers.
    expect(registry.for("/a/b.xhtml", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Html)
    expect(registry.for("/a/b.qmd", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Markdown)
    expect(registry.for("/a/b.rmd", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Markdown)
    expect(registry.for("/a/b.text", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Plain)
    # Flat-ODF and nested-section XML document formats.
    expect(registry.for("/a/b.fodt", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Fodt)
    expect(registry.for("/a/b.fodp", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Fodp)
    expect(registry.for("/a/b.dbk", explicit: false)).to be_a(MnemodocServer::Indexer::Format::DocBook)
    expect(registry.for("/a/b.dita", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Dita)
    expect(registry.for("/a/b.fb2", explicit: false)).to be_a(MnemodocServer::Indexer::Format::FictionBook)
  end

  it "skips unknown extensions when discovered, falls back to Plain when explicit" do
    registry = MnemodocServer::Indexer::Format::Registry.new(config)
    expect(registry.for("/a/CHANGELOG", explicit: false)).to be_nil
    expect(registry.for("/a/CHANGELOG", explicit: true)).to be_a(MnemodocServer::Indexer::Format::Plain)
  end

  it "registers PDF only when enabled and the tool is available" do
    pdf_config = MnemodocServer::Config.from_yaml("index:\n  pdf: true")
    with_tool = MnemodocServer::Indexer::Format::Registry.new(pdf_config, pdf_available: true)
    expect(with_tool.for("/a/b.pdf", explicit: false)).to be_a(MnemodocServer::Indexer::Format::Pdf)

    without_tool = MnemodocServer::Indexer::Format::Registry.new(pdf_config, pdf_available: false)
    expect(without_tool.for("/a/b.pdf", explicit: false)).to be_nil

    disabled = MnemodocServer::Indexer::Format::Registry.new(config, pdf_available: true)
    expect(disabled.for("/a/b.pdf", explicit: false)).to be_nil
  end

  it "exposes supported extensions for the crawler glob" do
    registry = MnemodocServer::Indexer::Format::Registry.new(config)
    expect(registry.supported?(".md")).to be_true
    expect(registry.supported?(".adoc")).to be_true
    expect(registry.supported?(".png")).to be_false
  end
end
