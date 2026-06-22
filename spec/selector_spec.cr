require "./spec_helper"

Spectator.describe MnemodocServer::Roles::Selector do
  private def role(name : String, *, when_files = [] of String, when_task = [] of String,
                   when_query = [] of String, description = "") : MnemodocServer::Roles::Role
    cfg = MnemodocServer::RoleConfig.new(
      file: "roles/#{name}.md", description: description,
      when_files: when_files, when_task: when_task, when_query: when_query,
    )
    MnemodocServer::Roles::Role.new(cfg, "/nonexistent/#{name}.md")
  end

  private def with_mock_embedder(&)
    server = HTTP::Server.new do |ctx|
      body = ctx.request.body.try(&.gets_to_end) || ""
      inputs = JSON.parse(body)["input"].as_a.map(&.as_s)
      vecs = inputs.map do |text|
        t = text.downcase
        t.includes?("crystal") ? [1.0_f32, 0.0_f32, 0.0_f32] : t.includes?("rails") ? [0.0_f32, 1.0_f32, 0.0_f32] : [0.0_f32, 0.0_f32, 1.0_f32]
      end
      ctx.response.content_type = "application/json"
      ctx.response.print({"embeddings" => vecs}.to_json)
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    cfg = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{addr.port}\nmodel: test")
    embedder = MnemodocServer::Indexer::Embedder.new(cfg)
    begin
      yield embedder
    ensure
      server.close
    end
  end

  it "raises NoRolesError when no roles are configured" do
    selector = MnemodocServer::Roles::Selector.new([] of MnemodocServer::Roles::Role, nil, nil)
    expect { selector.select(["a.cr"], "", "") }.to raise_error(MnemodocServer::Roles::NoRolesError)
  end

  it "returns the decisive role on a clear file-glob win" do
    roles = [role("crystal", when_files: ["**/*.cr"]), role("rails", when_files: ["**/*.rb"])]
    selector = MnemodocServer::Roles::Selector.new(roles, nil, nil)
    selection = selector.select(["src/foo.cr", "spec/foo_spec.cr"], "debug", "")
    expect(selection.role.name).to eq("crystal")
    expect(selection.candidates.first.score).to eq(6)
  end

  it "scores task and query keywords additively" do
    roles = [role("crystal", when_task: ["debug"], when_query: ["type"])]
    selector = MnemodocServer::Roles::Selector.new(roles, nil, nil)
    selection = selector.select([] of String, "debug", "a type issue")
    expect(selection.candidates.first.score).to eq(3)
  end

  it "returns the unique weak candidate without calling the embedder" do
    roles = [role("crystal", when_query: ["type"])]
    selector = MnemodocServer::Roles::Selector.new(roles, nil, nil)
    selection = selector.select([] of String, "", "a type issue")
    expect(selection.role.name).to eq("crystal")
    expect(selection.reason).to contain("weak")
  end

  it "breaks an ambiguous tie semantically" do
    with_mock_embedder do |embedder|
      roles = [
        role("crystal", when_files: ["**/*.cr"], description: "Crystal expert"),
        role("rails", when_files: ["**/*.cr"], description: "Rails ops"),
      ]
      selector = MnemodocServer::Roles::Selector.new(roles, nil, embedder)
      selection = selector.select(["thing.cr"], "", "crystal types question")
      expect(selection.role.name).to eq("crystal")
      expect(selection.reason).to contain("semantic")
    end
  end

  it "falls back to the default when there is no signal" do
    default = role("generalist")
    selector = MnemodocServer::Roles::Selector.new([role("crystal", when_files: ["**/*.cr"])], default, nil)
    selection = selector.select([] of String, "", "")
    expect(selection.role.name).to eq("generalist")
  end

  it "raises NeedSignalError when nothing matches and no default is set" do
    roles = [role("crystal", when_files: ["**/*.cr"]), role("rails", when_files: ["**/*.rb"])]
    selector = MnemodocServer::Roles::Selector.new(roles, nil, nil)
    expect { selector.select([] of String, "", "") }.to raise_error(MnemodocServer::Roles::NeedSignalError)
  end

  it "returns the default (not a semantic guess) when an edited file matches no rule" do
    with_mock_embedder do |embedder|
      default = role("generalist")
      roles = [
        role("backend", when_files: ["app/**"], description: "Backend"),
        role("frontend", when_files: ["app/frontend/**"], description: "Frontend"),
      ]
      selector = MnemodocServer::Roles::Selector.new(roles, default, embedder)
      selection = selector.select(["config/initializers/x.rb"], "", "")
      expect(selection.role.name).to eq("generalist")
      expect(selection.reason).to contain("default")
    end
  end

  it "returns the default without consulting the embedder when no rule matches" do
    default = role("generalist")
    roles = [role("backend", when_files: ["app/**"]), role("frontend", when_files: ["app/frontend/**"])]
    # A nil embedder proves the semantic tie-break is never reached.
    selector = MnemodocServer::Roles::Selector.new(roles, default, nil)
    selection = selector.select(["config/initializers/x.rb"], "", "")
    expect(selection.role.name).to eq("generalist")
  end

  it "raises NeedSignalError when a file matches no rule and no default exists" do
    with_mock_embedder do |embedder|
      roles = [role("backend", when_files: ["app/**"]), role("frontend", when_files: ["app/frontend/**"])]
      selector = MnemodocServer::Roles::Selector.new(roles, nil, embedder)
      expect { selector.select(["config/initializers/x.rb"], "", "") }
        .to raise_error(MnemodocServer::Roles::NeedSignalError)
    end
  end

  # The PreToolUse hook feeds absolute file paths (tool_input.file_path), while
  # when_files globs are relative to the config directory. Anchoring the globs at
  # base_dir lets absolute paths match.
  it "matches an absolute file path against globs anchored at base_dir" do
    default = role("generalist")
    roles = [role("trailblazer", when_files: ["app/concepts/**"])]
    selector = MnemodocServer::Roles::Selector.new(roles, default, nil, base_dir: "/repo")
    selection = selector.select(["/repo/app/concepts/camping/operation/create.rb"], "", "")
    expect(selection.role.name).to eq("trailblazer")
  end

  it "still matches a relative file path against the original globs (non-regression)" do
    default = role("generalist")
    roles = [role("trailblazer", when_files: ["app/concepts/**"])]
    selector = MnemodocServer::Roles::Selector.new(roles, default, nil, base_dir: "/repo")
    selection = selector.select(["app/concepts/camping/operation/create.rb"], "", "")
    expect(selection.role.name).to eq("trailblazer")
  end

  it "ignores an absolute file path outside base_dir and falls back to the default" do
    default = role("generalist")
    roles = [role("trailblazer", when_files: ["app/concepts/**"])]
    selector = MnemodocServer::Roles::Selector.new(roles, default, nil, base_dir: "/repo")
    selection = selector.select(["/tmp/foo.rb"], "", "")
    expect(selection.role.name).to eq("generalist")
  end
end
