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

  # The adapter's contract says it must not raise on missing or extra keys, and
  # a hook payload is whatever the client sends. JSON::Any#[]? looks lenient but
  # raises on a receiver that is neither a hash nor nil, so a root that is an
  # array or a scalar took the whole `context` command down — in the middle of a
  # PreToolUse hook, in front of the user.
  describe "a payload that is valid JSON but not an object" do
    it "yields an empty input instead of raising" do
      [%([]), %("just a string"), %(null), %(42)].each do |body|
        input = MnemodocServer::Hooks::ClaudeCode.new.parse(JSON.parse(body))
        expect(input.files).to be_empty
        expect(input.query).to be_empty
      end
    end

    it "survives a tool_input that is not an object" do
      body = %({"hook_event_name": "PreToolUse", "tool_input": ["oops"]})
      input = MnemodocServer::Hooks::ClaudeCode.new.parse(JSON.parse(body))
      expect(input.files).to be_empty
    end
  end
end

# How a prompt-hook answer reaches Claude Code. Plain text on stdout is added to
# Claude's context but never shown to the user, and stderr from a hook exiting 0
# goes to the debug log only; `systemMessage` in a JSON answer is the one field
# shown to the user. So a notice forces the JSON form, and the passages then
# travel in `additionalContext` rather than as plain text.
Spectator.describe "Claude Code prompt-hook rendering" do
  subject(adapter) { MnemodocServer::Hooks::ClaudeCode.new }

  it "passes passages through as plain text when there is no notice" do
    expect(adapter.render(passages: "<project-documentation>x</project-documentation>\n", notice: nil))
      .to eq("<project-documentation>x</project-documentation>\n")
  end

  it "prints nothing when there is neither a passage nor a notice" do
    expect(adapter.render(passages: "", notice: nil)).to eq("")
  end

  it "answers a notice alone with a systemMessage and no context" do
    rendered = JSON.parse(adapter.render(passages: "", notice: "lookup skipped"))
    expect(rendered.as_h.keys).to eq(["systemMessage"])
    expect(rendered["systemMessage"].as_s).to eq("lookup skipped")
  end

  it "carries the passages in additionalContext when a notice accompanies them" do
    rendered = JSON.parse(adapter.render(passages: "passage text\n", notice: "lookup restored"))
    expect(rendered["systemMessage"].as_s).to eq("lookup restored")
    expect(rendered["hookSpecificOutput"]["hookEventName"].as_s).to eq("UserPromptSubmit")
    expect(rendered["hookSpecificOutput"]["additionalContext"].as_s).to eq("passage text\n")
  end
end
