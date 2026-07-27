require "option_parser"
require "./runner"

# Entry point for `mise bench:tokens`.
#
# Measures what MnemoDoc's retrieval costs against the cost of loading the whole
# documentation set, and reports that saving **with** the recall it was achieved
# at — a saving on its own is not a valid output of this harness.
module Bench
  ROOT = File.expand_path("..", __DIR__)

  # The application's own logging is not part of the measurement: indexing
  # progress interleaved with the report makes the output unusable in a pipe.
  ::Log.setup(:error)

  model = "claude-opus-5"
  top_k = 5
  as_json = false
  ollama_host = ENV["MNEMODOC_OLLAMA_HOST"]? || "http://localhost:11434"

  OptionParser.parse do |parser|
    parser.banner = "Usage: bench [options]"
    parser.on("--model MODEL", "Model whose tokenizer is used for exact counts (default: #{model})") { |v| model = v }
    parser.on("--top-k N", "Passages retrieved per question (default: #{top_k})") { |v| top_k = v.to_i }
    parser.on("--json", "Emit the report as JSON") { as_json = true }
    parser.on("-h", "--help", "Show this help") do
      puts parser
      exit 0
    end
  end

  counter = TokenCounter.build(model: model)

  unless counter.exact?
    STDERR.puts "note: ANTHROPIC_API_KEY is unset — counting characters instead of tokens."
    STDERR.puts "      Ratios stay meaningful; absolute values are not token counts."
  end

  begin
    report = Runner.new(
      corpus_dir: File.join(ROOT, "bench", "corpus"),
      questions_file: File.join(ROOT, "bench", "questions.yml"),
      counter: counter,
      top_k: top_k,
      ollama_host: ollama_host,
    ).run

    puts as_json ? report.to_json : report.to_s
    # A run whose recall is zero has not measured a saving; say so in the exit
    # code too, so a script cannot mistake it for a good result.
    exit 1 unless report.meaningful?
  rescue ex : MnemodocServer::Indexer::EmbedderError
    STDERR.puts "Error: could not reach Ollama at #{ollama_host}: #{ex.message}"
    STDERR.puts "       Start it with `mise dev:ollama`."
    exit 1
  rescue ex : CounterError
    STDERR.puts "Error: token counting failed: #{ex.message}"
    exit 1
  rescue ex : Exception
    STDERR.puts "Error: #{ex.message}"
    exit 1
  end
end
