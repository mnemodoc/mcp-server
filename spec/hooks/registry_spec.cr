require "../spec_helper"

Spectator.describe MnemodocServer::Hooks::Registry do
  it "returns the Claude Code adapter for 'claude-code'" do
    adapter = MnemodocServer::Hooks::Registry.for("claude-code")
    expect(adapter).to be_a(MnemodocServer::Hooks::ClaudeCode)
  end

  it "raises UnknownClientError for an unknown client" do
    expect { MnemodocServer::Hooks::Registry.for("notepad") }
      .to raise_error(MnemodocServer::Hooks::UnknownClientError)
  end
end
