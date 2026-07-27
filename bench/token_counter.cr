require "http/client"
require "json"
require "uri"

# Measuring instruments for the token benchmark.
#
# Two units are available, and which one is in use is decided **once**, at
# startup, from the environment — never per call. A run that switched unit
# half-way through would produce figures that cannot be compared with each
# other, so an API failure raises rather than degrading to the approximation.
module Bench
  class CounterError < Exception; end

  # Common contract: a cost figure for a piece of text, plus a self-description
  # the report is required to print so no reader mistakes one unit for the other.
  abstract class TokenCounter
    ENDPOINT_PATH     = "/v1/messages/count_tokens"
    ANTHROPIC_BASE    = "https://api.anthropic.com"
    ANTHROPIC_VERSION = "2023-06-01"

    abstract def count(text : String) : Int32

    # Human-readable unit, printed in every report.
    abstract def mode : String

    # True when the figure is a real token count rather than a proxy.
    abstract def exact? : Bool

    # Picks the unit from the available credentials. A blank key counts as
    # absent: an empty ANTHROPIC_API_KEY in the environment is a configuration
    # slip, not a request for exact counting.
    def self.build(model : String, api_key : String? = ENV["ANTHROPIC_API_KEY"]?) : TokenCounter
      if (key = api_key) && !key.empty?
        ApiCounter.new(api_key: key, model: model)
      else
        CharCounter.new
      end
    end
  end

  # Offline proxy: the raw character count. Deliberately not converted into a
  # pseudo-token figure — the characters-to-tokens ratio varies with content, so
  # any fixed divisor would dress an approximation up as a measurement. The
  # report publishes ratios, which are unaffected by the choice of unit.
  class CharCounter < TokenCounter
    def count(text : String) : Int32
      text.size
    end

    def mode : String
      "characters (approximate — ratios are meaningful, absolute values are not tokens)"
    end

    def exact? : Bool
      false
    end
  end

  # Exact counts from the Anthropic count_tokens endpoint. The endpoint is free
  # and rate-limited separately from message creation, so counting costs nothing
  # and cannot disturb normal API usage.
  class ApiCounter < TokenCounter
    def initialize(@api_key : String, @model : String, @base_url : String = ANTHROPIC_BASE)
    end

    def count(text : String) : Int32
      body = {
        model:    @model,
        messages: [{role: "user", content: text}],
      }.to_json

      response = HTTP::Client.post(
        URI.parse(@base_url).resolve(ENDPOINT_PATH),
        headers: HTTP::Headers{
          "x-api-key"         => @api_key,
          "anthropic-version" => ANTHROPIC_VERSION,
          "content-type"      => "application/json",
        },
        body: body,
      )

      unless response.status_code == 200
        raise CounterError.new("count_tokens returned #{response.status_code}: #{response.body}")
      end

      parsed = JSON.parse(response.body)
      tokens = parsed["input_tokens"]?
      raise CounterError.new("count_tokens response carried no input_tokens: #{response.body}") if tokens.nil?

      tokens.as_i
    rescue ex : JSON::ParseException | TypeCastError
      raise CounterError.new("could not read count_tokens response: #{ex.message}")
    rescue ex : IO::Error | Socket::Error
      raise CounterError.new("could not reach count_tokens at #{@base_url}: #{ex.message}")
    end

    def mode : String
      "exact (count_tokens, model #{@model})"
    end

    def exact? : Bool
      true
    end
  end
end
