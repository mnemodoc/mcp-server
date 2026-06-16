require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::FictionBook do
  subject(handler) { MnemodocServer::Indexer::Format::FictionBook.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-fb2-#{Random::Secure.hex(4)}.fb2" }
  after_each { File.delete(tmp) rescue nil }

  it "splits on nested sections with their titles and keeps paragraphs" do
    File.write(tmp, <<-XML)
    <FictionBook>
      <body>
        <section>
          <title><p>Chapter</p></title>
          <p>opening line</p>
          <section>
            <title><p>Scene</p></title>
            <p>inner line</p>
          </section>
        </section>
      </body>
    </FictionBook>
    XML
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Chapter", "Scene"])
    expect(chunks.map(&.parent_heading)).to eq([nil, "Chapter"])
    expect(chunks.first.content).to contain("opening line")
  end

  it "returns an empty array when the file is unreadable" do
    expect(handler.extract("/tmp/none-#{Random::Secure.hex(4)}.fb2", mtime: 1_i64)).to be_empty
  end
end
