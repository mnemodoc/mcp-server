require "./spec_helper"
require "file_utils"

# A globally registered server is launched in whatever directory a client
# session opens. When that directory belongs to no MnemoDoc project, the server
# must stay useful and honest: it answers every tool with what to do about it,
# rather than returning an empty result the agent would read as "the
# documentation says nothing on this".
Spectator.describe "uninitialized project" do
  let(root) { File.join(Dir.tempdir, "mnemodoc-uninit-tools-#{Random::Secure.hex(6)}") }

  before_each do
    Dir.mkdir_p(root)
    MnemodocServer.init_app!("", from: root)
  end

  after_each do
    FileUtils.rm_rf(root)
    restore_project_state
  end

  private def registry
    config = MnemodocServer.config
    MnemodocServer::ToolRegistry.build(config, MnemodocServer.open_store(config))
  end

  it "answers query_documents with the way out, not an empty result" do
    built = registry
    result = built[:server].dispatch("query_documents", {"query" => JSON::Any.new("how does indexing work")})
    text = result.content.join(" ", &.to_json_object.["text"].as_s)
    expect(text).to contain("init")
    expect(result.structured_content.try(&.["project_initialized"]?).try(&.as_bool)).to be_false
  end

  it "gives every tool the same answer" do
    built = registry
    %w(list_files status get_project_context).each do |name|
      result = built[:server].dispatch(name, {} of String => JSON::Any)
      expect(result.structured_content.try(&.["project_initialized"]?).try(&.as_bool)).to be_false
    end
  end

  # Reporting a missing project is not a tool failure: the agent should fall
  # back to its own file tools, not treat the call as broken.
  it "does not report the short-circuit as an error" do
    built = registry
    expect(built[:server].dispatch("status", {} of String => JSON::Any).is_error?).to be_false
  end
end
