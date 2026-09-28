require "./spec_helper"
require "file_utils"

# The prompt hook runs before every user message, synchronously, in the client's
# critical path. Two properties matter more than what it prints: it must stay
# silent unless the prompt measurably concerns this corpus, and it must never
# fail in a way that blocks or annoys — whatever is wrong, exit 0 and say
# nothing.
Spectator.describe "prompt-hook CLI" do
  let(tmp_dir) { "/tmp/mnemodoc-hook-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }

  before_each do
    Dir.mkdir_p(File.join(tmp_dir, "doc"))
    File.write(File.join(tmp_dir, "doc", "excluding.md"), <<-MD)
    # Indexing

    ## Excluding paths

    Glob patterns listed under the exclude key are matched against absolute
    paths and skipped. Exclusion is evaluated during the walk, so an excluded
    directory is never descended into.
    MD
  end
  after_each { FileUtils.rm_rf(tmp_dir) }

  private def write_config(threshold : Float64 = 0.5, ollama : String = "http://localhost:11434") : Nil
    File.write(config_path, <<-YAML)
    paths:
      - doc/
    ollama:
      host: #{ollama}
    server:
      log_level: error
      daemon: false
    hook:
      similarity_threshold: #{threshold}
    db:
      path: #{File.join(tmp_dir, "index.db")}
    YAML
  end

  private def run_hook(prompt : String, session : String? = nil, extra : Array(String) = [] of String)
    payload = {hook_event_name: "UserPromptSubmit", prompt: prompt, session_id: session}.to_json
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("./bin/mnemodoc-server",
      ["prompt-hook", "--config", config_path] + extra,
      input: IO::Memory.new(payload), output: stdout, error: stderr)
    {stdout.to_s, stderr.to_s, status}
  end

  BACKEND_NOTICE  = "mnemodoc: documentation lookup skipped — the embedding backend did not answer (run `mnemodoc-server status`)."
  PAYLOAD_NOTICE  = "mnemodoc: documentation lookup skipped — the hook payload could not be read."
  CONFIG_NOTICE   = "mnemodoc: documentation lookup skipped — internal error (ArgumentError); see the mnemodoc log."
  RESTORED_NOTICE = "mnemodoc: documentation lookup restored."

  private def index! : Nil
    Process.run("./bin/mnemodoc-server",
      ["index", File.join(tmp_dir, "doc"), "--config", config_path, "--quiet"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
  end

  # vec0 declares its virtual table as float[768]: a vector of any other size is
  # skipped at insert time rather than rejected, so the mock must match it or the
  # semantic half of the search silently finds nothing.
  DIMS = 768

  # Where a real Ollama is expected. Overridable so the skip below can itself be
  # exercised — pointing this at a dead port is how one checks that the suite
  # skips rather than fails when no model is available.
  REAL_OLLAMA = ENV["MNEMODOC_SPEC_OLLAMA_HOST"]? || "http://localhost:11434"

  private def unit_vector(axis : Int32) : Array(Float32)
    Array.new(DIMS) { |i| i == axis ? 1.0_f32 : 0.0_f32 }
  end

  # Unit vector sitting at the given cosine from unit_vector(0), in the plane
  # spanned by the first two axes.
  private def vector_at_cosine(cosine : Float64) : Array(Float32)
    Array.new(DIMS) do |i|
      case i
      when 0 then cosine.to_f32
      when 1 then Math.sqrt(1.0 - cosine * cosine).to_f32
      else        0.0_f32
      end
    end
  end

  # Deterministic stand-in for Ollama, so the similarity gate is exercised on
  # every platform instead of only where a model happens to be installed.
  #
  # The three families are placed deliberately FAR from the threshold rather
  # than tuned against it: the passage and an on-topic prompt sit at cosine 0.9,
  # an off-topic prompt is orthogonal to both. The assertions below therefore
  # hold whether `similarity` carries a true cosine (0.9 vs 0.0) or the
  # 1/(1+L2) value the vec0 backend yields today (0.69 vs 0.41) — the test is
  # about the gate's behaviour, not about one scale's arithmetic.
  #
  # Order matters in the classifier: the passage's own body contains the word
  # "exclude" too, so it must be recognised by its distinctive phrase first.
  private def fake_ollama(&)
    passage = unit_vector(0)
    on_topic = vector_at_cosine(0.9)
    off_topic = unit_vector(2)

    server = HTTP::Server.new do |context|
      body = context.request.body.try(&.gets_to_end) || ""
      inputs = begin
        JSON.parse(body)["input"].as_a.map(&.as_s)
      rescue
        [] of String
      end
      vectors = inputs.map do |text|
        if text.includes?("Glob patterns")
          passage
        elsif text.downcase.includes?("exclud")
          on_topic
        else
          off_topic
        end
      end
      context.response.status_code = 200
      context.response.content_type = "application/json"
      context.response.print({"embeddings" => vectors}.to_json)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield "http://127.0.0.1:#{address.port}"
    ensure
      server.close
    end
  end

  # True when a real Ollama answers. Only the end-to-end example needs one.
  # Dialled like the server dials it: a plain HTTP::Client settles on the dead
  # ::1 address of `localhost` on macOS, and this example was skipped with
  # Ollama running.
  private def real_ollama? : Bool
    client = MnemodocServer::VerifiedClient.new(URI.parse(REAL_OLLAMA))
    client.connect_timeout = 1.second
    client.read_timeout = 2.seconds
    begin
      client.get("/api/tags").status_code == 200
    ensure
      client.close
    end
  rescue
    false
  end

  describe "when the prompt concerns the corpus" do
    it "injects the best passage, naming its source" do
      fake_ollama do |host|
        write_config(ollama: host)
        index!
        stdout, _, status = run_hook("how do I exclude a directory from indexing?")
        expect(status.success?).to be_true
        expect(stdout).to contain("Glob patterns")
        expect(stdout).to contain("excluding.md")
        expect(stdout).to contain("Excluding paths")
      end
    end

    # The mock pins the plumbing and the gate; only a real model can say whether
    # the corpus and the question actually meet above the threshold. Skipped
    # where no model is installed rather than failing there.
    it "injects against a real model, end to end" do
      skip "no Ollama at #{REAL_OLLAMA} (start it with `mise dev:ollama`)" unless real_ollama?
      write_config(ollama: REAL_OLLAMA)
      index!
      stdout, _, status = run_hook("how do I exclude a directory from indexing?")
      expect(status.success?).to be_true
      expect(stdout).to contain("Glob patterns")
      expect(stdout).to contain("excluding.md")
    end
  end

  describe "when it does not" do
    # The whole point of the gate: conversational filler must cost nothing.
    # Note this example is only meaningful with an index that HAS something in
    # it: against an empty one it would pass for the wrong reason, which is
    # exactly what it did in CI before the mock existed.
    it "stays silent on an off-topic prompt" do
      fake_ollama do |host|
        write_config(ollama: host)
        index!
        stdout, _, status = run_hook("write me a haiku about cats")
        expect(status.success?).to be_true
        expect(stdout).to be_empty
      end
    end

    it "stays silent when the threshold is unreachable" do
      fake_ollama do |host|
        write_config(threshold: 1.0, ollama: host)
        index!
        stdout, _, status = run_hook("how do I exclude a directory from indexing?")
        expect(status.success?).to be_true
        expect(stdout).to be_empty
      end
    end
  end

  # A failure never blocks the prompt: the hook still exits 0 and injects no
  # passage. But it is no longer indistinguishable from a decision to stay
  # silent — the user is told, through the one field Claude Code shows them.
  describe "never gets in the way, but says when it could not look" do
    it "exits cleanly on unparseable stdin, with a notice" do
      write_config
      index!
      stdout = IO::Memory.new
      status = Process.run("./bin/mnemodoc-server", ["prompt-hook", "--config", config_path],
        input: IO::Memory.new("not json at all"), output: stdout, error: Process::Redirect::Close)
      expect(status.success?).to be_true
      expect(JSON.parse(stdout.to_s)["systemMessage"].as_s).to eq(PAYLOAD_NOTICE)
    end

    it "exits cleanly when Ollama is unreachable, with a notice and no passage" do
      write_config(ollama: "http://127.0.0.1:1")
      stdout, _, status = run_hook("how do I exclude a directory from indexing?")
      expect(status.success?).to be_true
      answer = JSON.parse(stdout)
      expect(answer.as_h.keys).to eq(["systemMessage"])
      expect(answer["systemMessage"].as_s).to eq(BACKEND_NOTICE)
      expect(stdout).not_to contain("exclude a directory")
    end

    # A working backend over an index with nothing in it: the search returns
    # nothing, which is a decision, so there is nothing to announce.
    it "exits cleanly on an empty index, silently" do
      fake_ollama do |host|
        write_config(ollama: host)
        stdout, _, status = run_hook("how do I exclude a directory from indexing?")
        expect(status.success?).to be_true
        expect(stdout).to be_empty
      end
    end

    it "exits cleanly when the config file does not exist, with a notice" do
      stdout = IO::Memory.new
      payload = {hook_event_name: "UserPromptSubmit", prompt: "anything"}.to_json
      status = Process.run("./bin/mnemodoc-server",
        ["prompt-hook", "--config", File.join(tmp_dir, "absent.yml")],
        input: IO::Memory.new(payload), output: stdout, error: Process::Redirect::Close)
      expect(status.success?).to be_true
      expect(JSON.parse(stdout.to_s)["systemMessage"].as_s).to eq(CONFIG_NOTICE)
    end

    # The hook is registered once, globally, so it runs in every repository the
    # client opens. Outside a mnemodoc project there is nothing to look up, and
    # an outage of a backend that project never uses is none of its business.
    it "stays silent outside a mnemodoc project, even with the backend down" do
      outside = File.join(tmp_dir, "elsewhere")
      Dir.mkdir_p(outside)
      stdout = IO::Memory.new
      payload = {hook_event_name: "UserPromptSubmit", prompt: "anything", session_id: "s-out"}.to_json
      status = Process.run(File.expand_path("./bin/mnemodoc-server"), ["prompt-hook"],
        input: IO::Memory.new(payload), output: stdout, error: Process::Redirect::Close,
        chdir: outside, env: {"MNEMODOC_OLLAMA_HOST" => "http://127.0.0.1:1"})
      expect(status.success?).to be_true
      expect(stdout.to_s).to be_empty
    end
  end

  describe "notices across a session" do
    it "shows a failure once per session, not on every prompt" do
      write_config(ollama: "http://127.0.0.1:1")
      first, _, _ = run_hook("first question about indexing", session: "sess-a")
      second, _, status = run_hook("second question about indexing", session: "sess-a")
      expect(JSON.parse(first)["systemMessage"].as_s).to eq(BACKEND_NOTICE)
      expect(status.success?).to be_true
      expect(second).to be_empty
    end

    it "does not let one session silence another" do
      write_config(ollama: "http://127.0.0.1:1")
      run_hook("a question", session: "sess-a")
      other, _, _ = run_hook("a question", session: "sess-b")
      expect(JSON.parse(other)["systemMessage"].as_s).to eq(BACKEND_NOTICE)
    end

    it "shows the recovery once, alongside the passage it injects" do
      write_config(ollama: "http://127.0.0.1:1")
      run_hook("how do I exclude a directory from indexing?", session: "sess-r")
      fake_ollama do |host|
        write_config(ollama: host)
        index!
        recovered, _, status = run_hook("how do I exclude a directory from indexing?", session: "sess-r")
        expect(status.success?).to be_true
        answer = JSON.parse(recovered)
        expect(answer["systemMessage"].as_s).to eq(RESTORED_NOTICE)
        expect(answer["hookSpecificOutput"]["hookEventName"].as_s).to eq("UserPromptSubmit")
        expect(answer["hookSpecificOutput"]["additionalContext"].as_s).to contain("Glob patterns")

        again, _, _ = run_hook("how do I exclude a directory from indexing?", session: "sess-r")
        expect(again).to start_with("<project-documentation")
        expect(again).to contain("Glob patterns")
      end
    end
  end

  describe "--diagnostic" do
    it "writes the decision to stderr without the prompt" do
      write_config(ollama: "http://127.0.0.1:1")
      _, stderr, status = run_hook("how do I exclude a directory from indexing?", extra: ["--diagnostic"])
      expect(status.success?).to be_true
      line = stderr.lines.find!(&.includes?("mnemodoc.prompt-hook"))
      decision = JSON.parse(line)
      expect(decision["status"].as_s).to eq("backend_error")
      expect(decision["passages"].as_i).to eq(0)
      expect(decision["error_type"].as_s).to start_with("MnemodocServer::Indexer::Embedder")
      expect(stderr).not_to contain("exclude a directory")
    end

    it "reports a decision to stay silent as a decision" do
      fake_ollama do |host|
        write_config(ollama: host)
        index!
        _, stderr, _ = run_hook("write me a haiku about cats", extra: ["--diagnostic"])
        line = stderr.lines.find!(&.includes?("mnemodoc.prompt-hook"))
        expect(JSON.parse(line)["status"].as_s).to eq("below_threshold")
      end
    end
  end
end
