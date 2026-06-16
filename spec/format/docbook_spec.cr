require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::DocBook do
  subject(handler) { MnemodocServer::Indexer::Format::DocBook.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-dbk-#{Random::Secure.hex(4)}.dbk" }
  after_each { File.delete(tmp) rescue nil }

  it "assigns heading levels by section nesting and keeps paragraphs" do
    File.write(tmp, <<-XML)
    <book>
      <title>Guide</title>
      <para>overview of the guide</para>
      <chapter>
        <title>Chapter One</title>
        <para>chapter intro</para>
        <section>
          <title>Details</title>
          <para>nested body</para>
        </section>
      </chapter>
    </book>
    XML
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Guide", "Chapter One", "Details"])
    expect(chunks.last.parent_heading).to eq("Chapter One")
    expect(chunks.any?(&.content.includes?("nested body"))).to be_true
  end

  it "emits a DocBook 5 title nested in <info> at its section's depth" do
    File.write(tmp, <<-XML)
    <chapter>
      <info><title>Setup</title></info>
      <para>install steps</para>
    </chapter>
    XML
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Setup"])
    expect(chunks.first.content).to contain("install steps")
  end

  it "returns an empty array when the file is unreadable" do
    expect(handler.extract("/tmp/none-#{Random::Secure.hex(4)}.dbk", mtime: 1_i64)).to be_empty
  end
end
