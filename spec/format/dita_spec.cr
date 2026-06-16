require "../spec_helper"

Spectator.describe MnemodocServer::Indexer::Format::Dita do
  subject(handler) { MnemodocServer::Indexer::Format::Dita.new(MnemodocServer::Indexer::ChunkAssembler.new) }
  let(tmp) { "/tmp/mnemodoc-dita-#{Random::Secure.hex(4)}.dita" }
  after_each { File.delete(tmp) rescue nil }

  it "opens a heading at the topic title and keeps body paragraphs" do
    File.write(tmp, <<-XML)
    <topic>
      <title>Install</title>
      <body>
        <p>run the installer</p>
        <section>
          <title>Options</title>
          <p>pick a directory</p>
        </section>
      </body>
    </topic>
    XML
    chunks = handler.extract(tmp, mtime: 1_i64)
    expect(chunks.map(&.heading)).to eq(["Install", "Options"])
    expect(chunks.first.content).to contain("run the installer")
    expect(chunks.last.parent_heading).to eq("Install")
  end

  it "returns an empty array when the file is unreadable" do
    expect(handler.extract("/tmp/none-#{Random::Secure.hex(4)}.dita", mtime: 1_i64)).to be_empty
  end
end
