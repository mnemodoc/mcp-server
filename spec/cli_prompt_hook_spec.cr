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

  private def run_hook(prompt : String)
    payload = {hook_event_name: "UserPromptSubmit", prompt: prompt}.to_json
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("./bin/mnemodoc-server",
      ["prompt-hook", "--config", config_path],
      input: IO::Memory.new(payload), output: stdout, error: stderr)
    {stdout.to_s, stderr.to_s, status}
  end

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
  private def real_ollama? : Bool
    client = HTTP::Client.new(URI.parse(REAL_OLLAMA))
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

  # Every failure mode below would, if it escaped, surface as noise or an error
  # in front of the user on a turn that had nothing to do with documentation.
  describe "never gets in the way" do
    it "exits cleanly on unparseable stdin" do
      write_config
      index!
      stdout = IO::Memory.new
      status = Process.run("./bin/mnemodoc-server", ["prompt-hook", "--config", config_path],
        input: IO::Memory.new("not json at all"), output: stdout, error: Process::Redirect::Close)
      expect(status.success?).to be_true
      expect(stdout.to_s).to be_empty
    end

    it "exits cleanly when Ollama is unreachable" do
      write_config(ollama: "http://127.0.0.1:1")
      stdout, _, status = run_hook("how do I exclude a directory from indexing?")
      expect(status.success?).to be_true
      expect(stdout).to be_empty
    end

    it "exits cleanly on an empty index" do
      write_config
      stdout, _, status = run_hook("how do I exclude a directory from indexing?")
      expect(status.success?).to be_true
      expect(stdout).to be_empty
    end

    it "exits cleanly when the config file does not exist" do
      stdout = IO::Memory.new
      payload = {hook_event_name: "UserPromptSubmit", prompt: "anything"}.to_json
      status = Process.run("./bin/mnemodoc-server",
        ["prompt-hook", "--config", File.join(tmp_dir, "absent.yml")],
        input: IO::Memory.new(payload), output: stdout, error: Process::Redirect::Close)
      expect(status.success?).to be_true
      expect(stdout.to_s).to be_empty
    end
  end
end
