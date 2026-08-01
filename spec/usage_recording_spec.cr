# spec/usage_recording_spec.cr
require "./spec_helper"
require "file_utils"

Spectator.describe MnemodocServer::Usage::Recorder do
  let(tmp_dir) { "/tmp/mnemodoc-usagerec-#{Random::Secure.hex(4)}" }
  let(config) do
    MnemodocServer::Config.from_yaml(
      "paths:\n  - #{tmp_dir}\ndb:\n  path: #{File.join(tmp_dir, "index.db")}\n")
  end

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # With no daemon listening every event lands in the spool, which makes it the
  # simplest place to read back what was recorded.
  private def spooled : Array(MnemodocServer::Usage::UsageEvent)
    return [] of MnemodocServer::Usage::UsageEvent unless File.exists?(config.usage_spool_path)
    File.read(config.usage_spool_path).lines.reject(&.blank?)
      .map { |line| MnemodocServer::Usage::UsageEvent.from_json(line) }
  end

  it "records an event with the fields it was given" do
    MnemodocServer::Usage::Recorder.record(
      config, source: "hook", action: "prompt_hook", query: "how do I deploy",
      result_count: 2, elapsed_ms: 40, files: ["/docs/a.md", "/docs/b.md"],
      session: "s-1", agent: "a-1 (explorer)")

    event = spooled.first
    expect(event.source).to eq("hook")
    expect(event.action).to eq("prompt_hook")
    expect(event.query).to eq("how do I deploy")
    expect(event.result_count).to eq(2)
    expect(event.files).to eq(["/docs/a.md", "/docs/b.md"])
    expect(event.session).to eq("s-1")
    expect(event.agent).to eq("a-1 (explorer)")
    expect(event.at).to be > 0
  end

  it "derives files and result count from a search payload" do
    result = MCP::ToolResult.new(structured_content: JSON::Any.new({
      "chunks" => JSON::Any.new([
        JSON::Any.new({"file" => JSON::Any.new("/docs/a.md")} of String => JSON::Any),
        JSON::Any.new({"file" => JSON::Any.new("/docs/b.md")} of String => JSON::Any),
      ]),
    } of String => JSON::Any))

    MnemodocServer::Usage::Recorder.record_tool(
      config, source: "tool", action: "query_documents", result: result,
      query: "retry", elapsed_ms: 7)

    event = spooled.first
    expect(event.files).to eq(["/docs/a.md", "/docs/b.md"])
    expect(event.result_count).to eq(2)
  end

  it "records a call that served no document as an event with no files" do
    result = MCP::ToolResult.new(structured_content: JSON::Any.new(
      {"status" => JSON::Any.new("ok")} of String => JSON::Any))
    MnemodocServer::Usage::Recorder.record_tool(
      config, source: "tool", action: "status", result: result, query: nil, elapsed_ms: 1)

    event = spooled.first
    expect(event.action).to eq("status")
    expect(event.files).to be_empty
    expect(event.result_count).to eq(0)
  end

  it "records nothing at all when the journal is disabled" do
    config.usage.enabled = false
    MnemodocServer::Usage::Recorder.record(
      config, source: "tool", action: "status", query: nil,
      result_count: 0, elapsed_ms: 1, files: [] of String)
    expect(File.exists?(config.usage_spool_path)).to be_false
  end
end

Spectator.describe "tool call recording" do
  let(tmp_dir) { "/tmp/mnemodoc-usagetool-#{Random::Secure.hex(4)}" }
  let(db_path) { File.join(tmp_dir, "index.db") }
  let(config) do
    MnemodocServer::Config.from_yaml(
      "paths:\n  - #{tmp_dir}\ndb:\n  path: #{db_path}\nollama:\n  host: http://127.0.0.1:1\n")
  end
  let(store) { MnemodocServer::Store::SQLite.new(db_path) }

  before_each do
    Dir.mkdir_p(tmp_dir)
    restore_project_state
  end

  after_each do
    store.close
    delete_db(db_path)
    FileUtils.rm_rf(tmp_dir)
  end

  private def spooled : Array(MnemodocServer::Usage::UsageEvent)
    return [] of MnemodocServer::Usage::UsageEvent unless File.exists?(config.usage_spool_path)
    File.read(config.usage_spool_path).lines.reject(&.blank?)
      .map { |line| MnemodocServer::Usage::UsageEvent.from_json(line) }
  end

  it "records a tool call made through the registry" do
    built = MnemodocServer::ToolRegistry.build(config, store)
    begin
      built[:server].dispatch("list_files", {} of String => JSON::Any)
    ensure
      built[:embedder].close
    end

    event = spooled.find(&.action.== "list_files")
    expect(event).not_to be_nil
    expect(event.try(&.source)).to eq("tool")
    expect(event.try(&.elapsed_ms)).not_to be_nil
  end

  # The guard the design rests on: recording is observability, and must never be
  # able to break the call it observes. A spool that cannot be written is the
  # cheapest way to make every write path fail at once.
  it "answers normally even when nothing can be recorded" do
    Dir.mkdir_p(config.usage_spool_path)

    built = MnemodocServer::ToolRegistry.build(config, store)
    begin
      result = built[:server].dispatch("list_files", {} of String => JSON::Any)
      expect(result.is_error?).to be_false
      expect(result.structured_content.try(&.["files"]?)).not_to be_nil
    ensure
      built[:embedder].close
    end
  end
end

Spectator.describe "prompt hook recording" do
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }
  let(tmp_dir) { "/tmp/mnemodoc-usagehook-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }
  let(spool) { File.join(tmp_dir, ".mnemodoc", "usage.jsonl") }

  before_each { Dir.mkdir_p(File.join(tmp_dir, ".mnemodoc")) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # A working embedder over an empty index: the search returns nothing, so the
  # selection gate injects nothing. That is genuine silence — a decision — and
  # not the same thing as Ollama being down, which raises before the hook ever
  # reaches its decision and is deliberately not recorded as silence.
  private def fake_ollama(&)
    server = HTTP::Server.new do |ctx|
      ctx.response.status_code = 200
      ctx.response.content_type = "application/json"
      body = ctx.request.body.try(&.gets_to_end) || ""
      count = JSON.parse(body)["input"].as_a.size rescue 1
      ctx.response.print({"embeddings" => Array.new(count, Array(Float32).new(768, 0.1_f32))}.to_json)
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield addr.port
    ensure
      server.close
    end
  end

  private def write_fixture(port : Int32)
    File.write(config_path, <<-YAML)
    paths:
      - #{tmp_dir}
    db:
      path: #{File.join(tmp_dir, ".mnemodoc", "index.db")}
    ollama:
      host: http://127.0.0.1:#{port}
    YAML
  end

  it "records the hook call even when it injects nothing" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)
    fake_ollama do |port|
      write_fixture(port)
      payload = {hook_event_name: "UserPromptSubmit", prompt: "how do I deploy",
                 session_id: "s-42"}.to_json

      Process.run(binary, ["prompt-hook", "--config", config_path],
        input: IO::Memory.new(payload),
        output: Process::Redirect::Close, error: Process::Redirect::Close)

      expect(File.exists?(spool)).to be_true
      event = MnemodocServer::Usage::UsageEvent.from_json(File.read(spool).lines.first)
      expect(event.source).to eq("hook")
      expect(event.action).to eq("prompt_hook")
      expect(event.result_count).to eq(0)
      expect(event.query).to eq("how do I deploy")
      expect(event.session).to eq("s-42")
    end
  end
end
