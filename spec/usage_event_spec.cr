# spec/usage_event_spec.cr
require "./spec_helper"

Spectator.describe MnemodocServer::Usage::UsageEvent do
  private def result_with(structured : Hash(String, JSON::Any)) : MCP::ToolResult
    MCP::ToolResult.new(structured_content: JSON::Any.new(structured))
  end

  # query_documents returns many passages, each naming its file.
  it "takes one file per chunk from a search payload" do
    result = result_with({
      "chunks" => JSON::Any.new([
        JSON::Any.new({"file" => JSON::Any.new("/docs/a.md")} of String => JSON::Any),
        JSON::Any.new({"file" => JSON::Any.new("/docs/b.md")} of String => JSON::Any),
      ]),
    } of String => JSON::Any)
    expect(MnemodocServer::Usage::UsageEvent.files_from(result)).to eq(["/docs/a.md", "/docs/b.md"])
  end

  # Several passages routinely come from one document. Recording it once per
  # passage made "served N times" count passages on the MCP surface and calls on
  # the CLI one, so the same figure meant two different things.
  it "names a document once however many of its passages were returned" do
    result = result_with({
      "chunks" => JSON::Any.new([
        JSON::Any.new({"file" => JSON::Any.new("/docs/a.md")} of String => JSON::Any),
        JSON::Any.new({"file" => JSON::Any.new("/docs/a.md")} of String => JSON::Any),
        JSON::Any.new({"file" => JSON::Any.new("/docs/b.md")} of String => JSON::Any),
      ]),
    } of String => JSON::Any)
    expect(MnemodocServer::Usage::UsageEvent.files_from(result)).to eq(["/docs/a.md", "/docs/b.md"])
  end

  # The count is what a call returned, not how many documents it touched: three
  # passages from one file is three results, and only a genuinely empty answer
  # may read as zero, since that is what the misses view keys on.
  it "counts what the call returned, not the documents it touched" do
    chunks = result_with({
      "chunks" => JSON::Any.new([
        JSON::Any.new({"file" => JSON::Any.new("/docs/a.md")} of String => JSON::Any),
        JSON::Any.new({"file" => JSON::Any.new("/docs/a.md")} of String => JSON::Any),
      ]),
    } of String => JSON::Any)
    expect(MnemodocServer::Usage::UsageEvent.result_count_from(chunks)).to eq(2)

    single = result_with({"file" => JSON::Any.new("/docs/guide.md")} of String => JSON::Any)
    expect(MnemodocServer::Usage::UsageEvent.result_count_from(single)).to eq(1)

    none = result_with({"status" => JSON::Any.new("ok")} of String => JSON::Any)
    expect(MnemodocServer::Usage::UsageEvent.result_count_from(none)).to eq(0)

    empty = result_with({"chunks" => JSON::Any.new([] of JSON::Any)} of String => JSON::Any)
    expect(MnemodocServer::Usage::UsageEvent.result_count_from(empty)).to eq(0)
  end

  it "takes the single file from a read or outline payload" do
    result = result_with({"file" => JSON::Any.new("/docs/guide.md")} of String => JSON::Any)
    expect(MnemodocServer::Usage::UsageEvent.files_from(result)).to eq(["/docs/guide.md"])
  end

  # A tool that serves no document — list_files, status — is still an event, it
  # simply attributes no file. So is a shape nobody anticipated.
  it "returns no file for a payload carrying neither shape" do
    result = result_with({"files" => JSON::Any.new([] of JSON::Any)} of String => JSON::Any)
    expect(MnemodocServer::Usage::UsageEvent.files_from(result)).to be_empty
  end

  it "returns no file when there is no structured content at all" do
    expect(MnemodocServer::Usage::UsageEvent.files_from(MCP::ToolResult.text("plain"))).to be_empty
  end

  it "survives a chunks entry that is not an object" do
    result = result_with({"chunks" => JSON::Any.new([JSON::Any.new("oops")])} of String => JSON::Any)
    expect(MnemodocServer::Usage::UsageEvent.files_from(result)).to be_empty
  end

  it "round-trips through JSON" do
    event = MnemodocServer::Usage::UsageEvent.new(
      at: 1_700_000_000_i64, source: "tool", action: "query_documents",
      query: "retry policy", result_count: 2, elapsed_ms: 12,
      session: nil, agent: nil, files: ["/docs/a.md"],
    )
    back = MnemodocServer::Usage::UsageEvent.from_json(event.to_json)
    expect(back.action).to eq("query_documents")
    expect(back.query).to eq("retry policy")
    expect(back.files).to eq(["/docs/a.md"])
    expect(back.result_count).to eq(2)
  end
end
