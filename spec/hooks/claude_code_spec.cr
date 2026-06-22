require "../spec_helper"

Spectator.describe MnemodocServer::Hooks::ClaudeCode do
  subject(adapter) { MnemodocServer::Hooks::ClaudeCode.new }

  it "maps a PreToolUse payload to files plus attribution" do
    json = JSON.parse(<<-JSON)
    {
      "session_id": "sess_42",
      "hook_event_name": "PreToolUse",
      "tool_name": "Edit",
      "tool_input": {"file_path": "src/foo.cr"},
      "transcript_path": "/t/x.jsonl",
      "cwd": "/proj"
    }
    JSON
    input = adapter.parse(json)
    expect(input.event).to eq("PreToolUse")
    expect(input.files).to eq(["src/foo.cr"])
    expect(input.query).to eq("")
    expect(input.session_id).to eq("sess_42")
    expect(input.transcript_path).to eq("/t/x.jsonl")
    expect(input.cwd).to eq("/proj")
  end

  it "maps a UserPromptSubmit payload to the query" do
    json = JSON.parse(<<-JSON)
    {
      "session_id": "sess_7",
      "hook_event_name": "UserPromptSubmit",
      "prompt": "how do roles work?"
    }
    JSON
    input = adapter.parse(json)
    expect(input.event).to eq("UserPromptSubmit")
    expect(input.query).to eq("how do roles work?")
    expect(input.files).to be_empty
    expect(input.session_id).to eq("sess_7")
  end

  it "carries agent attribution when present" do
    json = JSON.parse(<<-JSON)
    {"hook_event_name": "PreToolUse", "tool_input": {"file_path": "a.cr"},
     "agent_id": "ag_9", "agent_type": "Explore"}
    JSON
    input = adapter.parse(json)
    expect(input.agent_id).to eq("ag_9")
    expect(input.agent_type).to eq("Explore")
  end

  it "yields attribution only for an unhandled event" do
    json = JSON.parse(%({"hook_event_name": "Stop", "session_id": "s"}))
    input = adapter.parse(json)
    expect(input.event).to eq("Stop")
    expect(input.files).to be_empty
    expect(input.query).to eq("")
    expect(input.session_id).to eq("s")
  end

  it "does not raise on missing keys" do
    input = adapter.parse(JSON.parse("{}"))
    expect(input.event).to be_nil
    expect(input.files).to be_empty
    expect(input.query).to eq("")
    expect(input.session_id).to be_nil
  end
end
