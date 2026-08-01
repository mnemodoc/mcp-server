# spec/tools_read_spec.cr
require "./spec_helper"
require "file_utils"

Spectator.describe MnemodocServer::Tools::Read do
  let(root) { File.join(Dir.tempdir, "mnemodoc-read-#{Random::Secure.hex(6)}") }
  let(db_path) { File.join(root, "index.db") }
  let(doc_path) { File.join(root, "guide.md") }
  let(store) { MnemodocServer::Store::SQLite.new(db_path) }
  subject(tool) { MnemodocServer::Tools::Read.new(store) }

  before_each do
    Dir.mkdir_p(root)
    File.write(doc_path, (1..10).join('\n') { |i| "line #{i}" } + "\n")
    store.index_file(
      doc_path, File.info(doc_path).modification_time.to_unix,
      [MnemodocServer::Chunk.new(
        file_path: doc_path, heading: nil, parent_heading: nil, content: "line 1",
        embedding: Array(Float32).new(768, 0.1_f32), token_count: 2, mtime: 1000_i64,
      )],
      text: File.read(doc_path), verbatim: true,
      outline: [] of MnemodocServer::Indexer::OutlineEntry,
    )
  end

  after_each do
    store.close
    delete_db(db_path)
    FileUtils.rm_rf(root)
  end

  private def read(args : Hash(String, JSON::Any::Type)) : Hash(String, JSON::Any)
    result = tool.call(args.transform_values { |value| JSON::Any.new(value) })
    result.structured_content.try(&.as_h) || {} of String => JSON::Any
  end

  it "returns numbered lines from the requested offset" do
    result = read({"path" => doc_path, "offset" => 3_i64, "limit" => 2_i64})
    expect(result["returned"].as_i).to eq(2)
    expect(result["content"].as_s).to eq("   3\tline 3\n   4\tline 4\n")
    expect(result["eof"].as_bool).to be_false
  end

  it "reports verbatim so the agent knows whose line numbers these are" do
    expect(read({"path" => doc_path})["verbatim"].as_bool).to be_true
  end

  it "clamps a non-positive offset to the first line rather than failing" do
    result = read({"path" => doc_path, "offset" => -5_i64, "limit" => 1_i64})
    expect(result["offset"].as_i).to eq(1)
    expect(result["content"].as_s).to eq("   1\tline 1\n")
  end

  it "clamps a limit above the ceiling" do
    result = read({"path" => doc_path, "limit" => 99_999_i64})
    expect(result["limit"].as_i).to eq(MnemodocServer::Tools::Read::MAX_LIMIT)
  end

  # Probing past the end is a legitimate thing for an agent to do; an error
  # would teach it to stop probing.
  it "reports eof without an error when the offset is past the end" do
    result = read({"path" => doc_path, "offset" => 500_i64})
    expect(result["returned"].as_i).to eq(0)
    expect(result["content"].as_s).to be_empty
    expect(result["eof"].as_bool).to be_true
  end

  it "sets eof when the window reaches the last line" do
    expect(read({"path" => doc_path, "offset" => 9_i64, "limit" => 5_i64})["eof"].as_bool).to be_true
  end

  it "resolves a path by unique suffix, like delete_file" do
    expect(read({"path" => "guide.md"})["file"].as_s).to eq(doc_path)
  end

  it "raises when the path is not indexed" do
    expect { read({"path" => "/nope/absent.md"}) }.to raise_error(MCP::ToolError, /not found in index/)
  end

  it "flags a document whose file changed since indexing" do
    File.write(doc_path, "rewritten\n")
    File.touch(doc_path, Time.utc + 1.hour)
    result = read({"path" => doc_path})
    expect(result["stale"].as_bool).to be_true
    expect(result["warnings"].as_a.map(&.as_s).join(" ")).to contain("changed on disk")
    # The stored copy is what is served, so a widened passage still matches the
    # chunks the search returned.
    expect(result["content"].as_s).to contain("line 1")
  end

  it "flags a document whose file has been removed" do
    File.delete(doc_path)
    result = read({"path" => doc_path})
    expect(result["stale"].as_bool).to be_true
    expect(result["warnings"].as_a.map(&.as_s).join(" ")).to contain("no longer on disk")
  end

  it "raises when the file is indexed but carries no stored document" do
    store.@db.exec("DELETE FROM documents WHERE file_path = ?", doc_path)
    expect { read({"path" => doc_path}) }.to raise_error(MCP::ToolError, /re-index/)
  end
end
