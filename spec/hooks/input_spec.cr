require "../spec_helper"

Spectator.describe MnemodocServer::Hooks::HookInput do
  it "defaults to empty files/task/query and nil attribution" do
    input = MnemodocServer::Hooks::HookInput.new
    expect(input.files).to be_empty
    expect(input.task).to eq("")
    expect(input.query).to eq("")
    expect(input.session_id).to be_nil
  end

  it "renders agent_label as '<id> (<type>)' when both present" do
    input = MnemodocServer::Hooks::HookInput.new(agent_id: "ag_1", agent_type: "Explore")
    expect(input.agent_label).to eq("ag_1 (Explore)")
  end

  it "renders agent_label as the lone present field" do
    expect(MnemodocServer::Hooks::HookInput.new(agent_id: "ag_1").agent_label).to eq("ag_1")
    expect(MnemodocServer::Hooks::HookInput.new(agent_type: "Explore").agent_label).to eq("Explore")
  end

  it "renders agent_label as empty when neither present" do
    expect(MnemodocServer::Hooks::HookInput.new.agent_label).to eq("")
  end
end
