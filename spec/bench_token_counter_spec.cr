require "./spec_helper"
require "../bench/token_counter"

# The counter is the benchmark's measuring instrument, so its contract matters
# more than its implementation: which unit it reports, that it says so, and that
# it fails loudly rather than silently changing unit mid-run.
Spectator.describe Bench::TokenCounter do
  describe Bench::CharCounter do
    let(counter) { Bench::CharCounter.new }

    # No invented characters-to-tokens ratio: the raw count is honest, and the
    # report only ever publishes ratios, which are scale-invariant.
    it "counts raw characters" do
      expect(counter.count("hello")).to eq(5)
      expect(counter.count("")).to eq(0)
    end

    it "announces its unit as approximate" do
      expect(counter.mode).to contain("character")
      expect(counter.exact?).to be_false
    end
  end

  describe Bench::ApiCounter do
    # Mock count_tokens endpoint: asserts the documented request shape and
    # returns the documented response.
    private def with_mock_api(status : Int32 = 200, body : String = %({"input_tokens": 14}), &)
      received = {} of String => String
      server = HTTP::Server.new do |ctx|
        received["path"] = ctx.request.path
        received["method"] = ctx.request.method
        received["version"] = ctx.request.headers["anthropic-version"]? || ""
        received["key"] = ctx.request.headers["x-api-key"]? || ""
        received["body"] = ctx.request.body.try(&.gets_to_end) || ""
        ctx.response.status_code = status
        ctx.response.content_type = "application/json"
        ctx.response.print(body)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield
      begin
        yield "http://127.0.0.1:#{addr.port}", received
      ensure
        server.close
      end
    end

    it "posts the documented payload and reads input_tokens" do
      with_mock_api do |base, received|
        counter = Bench::ApiCounter.new(api_key: "test-key", model: "claude-opus-5", base_url: base)
        expect(counter.count("Hello, Claude")).to eq(14)

        expect(received["method"]).to eq("POST")
        expect(received["path"]).to eq("/v1/messages/count_tokens")
        expect(received["version"]).to eq("2023-06-01")
        expect(received["key"]).to eq("test-key")

        payload = JSON.parse(received["body"])
        expect(payload["model"].as_s).to eq("claude-opus-5")
        expect(payload["messages"][0]["role"].as_s).to eq("user")
        expect(payload["messages"][0]["content"].as_s).to eq("Hello, Claude")
      end
    end

    it "announces its unit as exact, naming the model" do
      counter = Bench::ApiCounter.new(api_key: "k", model: "claude-opus-5", base_url: "http://127.0.0.1:1")
      expect(counter.mode).to contain("claude-opus-5")
      expect(counter.exact?).to be_true
    end

    # A run that silently degraded to another unit half-way through would
    # produce figures that cannot be compared with each other.
    it "raises on an API error instead of falling back" do
      with_mock_api(status: 429, body: %({"error": "rate limited"})) do |base, _|
        counter = Bench::ApiCounter.new(api_key: "k", model: "m", base_url: base)
        expect { counter.count("x") }.to raise_error(Bench::CounterError, /429/)
      end
    end

    it "raises when the response carries no input_tokens" do
      with_mock_api(body: %({"unexpected": true})) do |base, _|
        counter = Bench::ApiCounter.new(api_key: "k", model: "m", base_url: base)
        expect { counter.count("x") }.to raise_error(Bench::CounterError)
      end
    end
  end

  # The unit is decided once, at startup, from the environment — never per call.
  describe ".build" do
    it "selects the API counter when a key is present" do
      counter = Bench::TokenCounter.build(model: "claude-opus-5", api_key: "some-key")
      expect(counter.exact?).to be_true
    end

    it "falls back to characters when the key is absent or blank" do
      expect(Bench::TokenCounter.build(model: "m", api_key: nil).exact?).to be_false
      expect(Bench::TokenCounter.build(model: "m", api_key: "").exact?).to be_false
    end
  end
end
