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

  # The CLI prints `Error: #{ex.message}`, so an empty message surfaces as a
  # bare "Error:" with nothing actionable in it.
  it "explains what is missing when no roles are configured" do
    selector = MnemodocServer::Roles::Selector.new([] of MnemodocServer::Roles::Role, nil, nil)
    expect { selector.select(["a.cr"], "", "") }
      .to raise_error(MnemodocServer::Roles::NoRolesError, /context\.roles/)
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

  it "points at context.default when nothing matches and no default is set" do
    roles = [role("crystal", when_files: ["**/*.cr"]), role("rails", when_files: ["**/*.rb"])]
    selector = MnemodocServer::Roles::Selector.new(roles, nil, nil)
    expect { selector.select([] of String, "", "") }
      .to raise_error(MnemodocServer::Roles::NeedSignalError, /context\.default/)
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

  # The semantic tie-break ranks a query against role DESCRIPTIONS, which says
  # nothing about whether a role's rules matched. Letting roles that matched
  # nothing into the shortlist therefore returned an arbitrary role for any
  # prompt that happened to contain one technical word.
  describe "shortlist of roles that actually matched" do
    private def three_disjoint_roles
      [
        role("alpha", when_query: ["pipeline", "transform"], description: "crystal streams"),
        role("beta", when_query: ["button", "display"], description: "rails views"),
        role("gamma", when_query: ["test", "coverage"], description: "coverage"),
      ]
    end

    # A nil embedder is the proof: reaching the tie-break at all would raise
    # NeedSignalError, which is what used to happen here.
    it "returns the only role that matched, without a tie-break" do
      selector = MnemodocServer::Roles::Selector.new(three_disjoint_roles, nil, nil)
      selection = selector.select([] of String, "", "thanks for the test, good evening")

      expect(selection.role.name).to eq("gamma")
      expect(selection.reason).to contain("unique candidate")
    end

    # Same situation with an embedder available: the tie-break must still not
    # be consulted, and above all must not hand back a role scoring zero.
    it "never returns a role whose rules matched nothing" do
      with_mock_embedder do |embedder|
        selector = MnemodocServer::Roles::Selector.new(three_disjoint_roles, nil, embedder)
        selection = selector.select([] of String, "", "a crystal question about the test")

        expect(selection.role.name).to eq("gamma")
        expect(selection.candidates.find! { |candidate| candidate.name == "alpha" }.score).to eq(0)
      end
    end

    it "still arbitrates semantically between roles that both matched" do
      with_mock_embedder do |embedder|
        roles = [
          role("crystal", when_query: ["question"], description: "crystal conventions"),
          role("rails", when_query: ["question"], description: "rails conventions"),
        ]
        selector = MnemodocServer::Roles::Selector.new(roles, nil, embedder)
        selection = selector.select([] of String, "", "a question about rails")

        expect(selection.role.name).to eq("rails")
        expect(selection.reason).to contain("semantic")
      end
    end

    it "carries the winning role's rule score on the selection" do
      selector = MnemodocServer::Roles::Selector.new(three_disjoint_roles, nil, nil)
      selection = selector.select([] of String, "", "add a test for coverage")

      expect(selection.role.name).to eq("gamma")
      expect(selection.score).to eq(2)
    end
  end

  # A keyword used to fire anywhere inside a longer word, and the shorter the
  # keyword the worse it got — with nothing the configuration could do about it.
  describe "word-boundary keyword matching" do
    it "does not fire a keyword inside a longer word" do
      roles = [role("gamma", when_query: ["test"])]
      default = role("generalist")
      selector = MnemodocServer::Roles::Selector.new(roles, default, nil)

      expect(selector.select([] of String, "", "can you tester this").role.name).to eq("generalist")
      expect(selector.select([] of String, "", "an attestation").role.name).to eq("generalist")
    end

    it "fires the keyword as a whole word, whatever punctuation surrounds it" do
      roles = [role("gamma", when_query: ["test"])]
      selector = MnemodocServer::Roles::Selector.new(roles, nil, nil)

      expect(selector.select([] of String, "", "thanks for the test, bye").role.name).to eq("gamma")
      expect(selector.select([] of String, "", "(test)").role.name).to eq("gamma")
      expect(selector.select([] of String, "", "a TEST here").role.name).to eq("gamma")
    end

    # Keywords and prompts alike may be accented, so the boundary has to be
    # Unicode-aware: an accented letter is part of the word, not a separator.
    it "treats accented letters as part of a word" do
      roles = [role("alpha", when_query: ["créé"])]
      default = role("generalist")
      selector = MnemodocServer::Roles::Selector.new(roles, default, nil)

      expect(selector.select([] of String, "", "le fichier créé hier").role.name).to eq("alpha")
      expect(selector.select([] of String, "", "un CAFÉ CRÉÉ").role.name).to eq("alpha")
      expect(selector.select([] of String, "", "recréée deux fois").role.name).to eq("generalist")
    end

    it "applies the same boundary to task keywords" do
      roles = [role("gamma", when_task: ["test"])]
      default = role("generalist")
      selector = MnemodocServer::Roles::Selector.new(roles, default, nil)

      expect(selector.select([] of String, "tester", "").role.name).to eq("generalist")
      expect(selector.select([] of String, "test", "").role.name).to eq("gamma")
    end

    it "restores substring matching when word_boundaries is off" do
      roles = [role("gamma", when_query: ["test"])]
      selector = MnemodocServer::Roles::Selector.new(roles, nil, nil, word_boundaries: false)

      expect(selector.select([] of String, "", "can you tester this").role.name).to eq("gamma")
    end

    # A multi-word keyword is bounded at its ends, not at every space inside it.
    it "matches a multi-word keyword as a whole" do
      roles = [role("alpha", when_query: ["code review"])]
      default = role("generalist")
      selector = MnemodocServer::Roles::Selector.new(roles, default, nil)

      expect(selector.select([] of String, "", "start a code review now").role.name).to eq("alpha")
      expect(selector.select([] of String, "", "a code reviewer").role.name).to eq("generalist")
    end

    # The files channel is untouched by any of this: a glob is not a keyword,
    # and an edited file is a strong, unambiguous signal.
    it "leaves file-glob matching alone" do
      roles = [role("alpha", when_files: ["**/*.cr"])]
      selector = MnemodocServer::Roles::Selector.new(roles, nil, nil)

      expect(selector.select(["src/tester.cr"], "", "").role.name).to eq("alpha")
    end
  end

  # Role names are basenames, so two roles living in different directories can
  # carry the same one. The description cache was keyed on that name, so the
  # second role reused the first's embedding and the tie-break ranked it on
  # somebody else's description — quietly picking the wrong conventions.
  describe "two roles with the same file basename" do
    private def lead(dir : String, description : String) : MnemodocServer::Roles::Role
      cfg = MnemodocServer::RoleConfig.new(
        file: "#{dir}/lead.md", description: description,
        when_query: ["question"], when_files: [] of String, when_task: [] of String,
      )
      MnemodocServer::Roles::Role.new(cfg, "/nonexistent/#{dir}/lead.md")
    end

    it "ranks each on its own description" do
      backend = lead("backend", "crystal conventions")
      frontend = lead("frontend", "rails conventions")

      with_mock_embedder do |embedder|
        selector = MnemodocServer::Roles::Selector.new([backend, frontend], nil, embedder)
        # The bundle speaks of rails, so the frontend role must win. With the
        # cache collision it inherited backend's crystal vector and lost.
        selection = selector.select([] of String, "", "question about rails")
        expect(selection.role.config.file).to eq("frontend/lead.md")
      end
    end
  end
end
