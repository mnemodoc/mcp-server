# spec/tools_outline_spec.cr
require "./spec_helper"
require "file_utils"

Spectator.describe MnemodocServer::Tools::Outline do
  let(root) { File.join(Dir.tempdir, "mnemodoc-outline-#{Random::Secure.hex(6)}") }
  let(db_path) { File.join(root, "index.db") }
  let(doc_path) { File.join(root, "guide.md") }
  let(store) { MnemodocServer::Store::SQLite.new(db_path) }
  subject(tool) { MnemodocServer::Tools::Outline.new(store) }

  before_each do
    Dir.mkdir_p(root)
    File.write(doc_path, "# Guide\n\nintro\n\n## Setup\n\nstep one\nstep two\n\n## Usage\n\nrun it\n")
    store.index_file(
      doc_path, File.info(doc_path).modification_time.to_unix,
      [MnemodocServer::Chunk.new(
        file_path: doc_path, heading: "## Setup", parent_heading: "# Guide",
        content: "step one", embedding: Array(Float32).new(768, 0.1_f32), token_count: 2, mtime: 1000_i64,
      )],
      text: File.read(doc_path), verbatim: true,
      outline: [
        MnemodocServer::Indexer::OutlineEntry.new(1, "# Guide", 1),
        MnemodocServer::Indexer::OutlineEntry.new(2, "## Setup", 5),
        MnemodocServer::Indexer::OutlineEntry.new(2, "## Usage", 10),
      ],
    )
  end

  after_each do
    store.close
    delete_db(db_path)
    FileUtils.rm_rf(root)
  end

  private def outline(args : Hash(String, JSON::Any::Type)) : Hash(String, JSON::Any)
    result = tool.call(args.transform_values { |value| JSON::Any.new(value) })
    result.structured_content.try(&.as_h) || {} of String => JSON::Any
  end

  it "lists every heading with its level and start line" do
    sections = outline({"path" => doc_path})["sections"].as_a
    expect(sections.map(&.["title"].as_s)).to eq(["# Guide", "## Setup", "## Usage"])
    expect(sections.map(&.["level"].as_i)).to eq([1, 2, 2])
    expect(sections.map(&.["start_line"].as_i)).to eq([1, 5, 10])
  end

  # A section ends one line before the next one starts, and the last ends at the
  # document's last line. This is what lets an agent see a section is small
  # enough to read whole before asking for it.
  it "closes each section on the line before the next one" do
    sections = outline({"path" => doc_path})["sections"].as_a
    expect(sections.map(&.["end_line"].as_i)).to eq([4, 9, 12])
    expect(sections.map(&.["lines"].as_i)).to eq([4, 5, 3])
  end

  # The markup is redundant with `level`, and kept anyway: it is the only thing
  # tying a passage returned by query_documents back to its outline entry.
  it "keeps the heading markup" do
    expect(outline({"path" => doc_path})["sections"].as_a.first["title"].as_s).to eq("# Guide")
  end

  it "reports the document's size and verbatim flag" do
    result = outline({"path" => doc_path})
    expect(result["line_count"].as_i).to eq(12)
    expect(result["verbatim"].as_bool).to be_true
  end

  it "returns an empty section list for a document with no headings" do
    store.@db.exec("DELETE FROM outline WHERE file_path = ?", doc_path)
    expect(outline({"path" => doc_path})["sections"].as_a).to be_empty
  end

  it "raises when the path is not indexed" do
    expect { outline({"path" => "/nope/absent.md"}) }.to raise_error(MCP::ToolError, /not found in index/)
  end

  it "flags a document whose file changed since indexing" do
    File.write(doc_path, "rewritten\n")
    File.touch(doc_path, Time.utc + 1.hour)
    expect(outline({"path" => doc_path})["stale"].as_bool).to be_true
  end
end
