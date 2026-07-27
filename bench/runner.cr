require "file_utils"
require "../src/mnemodoc_server"
require "./questions"
require "./report"
require "./token_counter"

module Bench
  # Runs the benchmark end to end: index the fixture corpus into a throwaway
  # store, ask every annotated question, and cost the passages that come back
  # against the cost of loading the whole corpus.
  #
  # The baseline is the corpus in full, counted once — it is what a session
  # pays under the /context-reload ritual this project exists to replace, and
  # it is identical for every question.
  class Runner
    def initialize(@corpus_dir : String, @questions_file : String, @counter : TokenCounter,
                   @top_k : Int32, @ollama_host : String)
    end

    def run : Report
      questions = Questions.load(@questions_file)
      raise "no questions in #{@questions_file}" if questions.empty?

      # A throwaway store, never the project's own index.
      work_dir = File.join(Dir.tempdir, "mnemodoc-bench-#{Random::Secure.hex(6)}")
      Dir.mkdir_p(work_dir)

      begin
        config = build_config(work_dir)
        store = MnemodocServer::Store::SQLite.new(File.join(work_dir, "index.db"))
        embedder = MnemodocServer::Indexer::Embedder.new(config.ollama)

        begin
          index_corpus(config, store, embedder)
          outcomes = questions.map { |question| ask(question, config, store, embedder) }
          Report.new(mode: @counter.mode, baseline_cost: baseline_cost, top_k: @top_k,
            outcomes: outcomes, threshold: config.hook.similarity_threshold)
        ensure
          embedder.close
          store.close
        end
      ensure
        FileUtils.rm_rf(work_dir)
      end
    end

    # The whole corpus as a single blob, in a stable order so two runs of an
    # unchanged corpus produce the same baseline.
    private def baseline_cost : Int32
      whole = corpus_files.map { |path| File.read(path) }.join("\n\n")
      @counter.count(whole)
    end

    private def corpus_files : Array(String)
      Dir.glob(File.join(@corpus_dir, "*.md")).sort!
    end

    private def build_config(work_dir : String) : MnemodocServer::Config
      config = MnemodocServer::Config.from_yaml(<<-YAML)
      paths:
        - #{@corpus_dir}
      ollama:
        host: #{@ollama_host}
      search:
        mode: hybrid
        top_k: #{@top_k}
      server:
        log_level: error
      db:
        path: #{File.join(work_dir, "index.db")}
      YAML
      config.source_dir = work_dir
      config
    end

    private def index_corpus(config : MnemodocServer::Config, store : MnemodocServer::Store::SQLite, embedder : MnemodocServer::Indexer::Embedder) : Nil
      registry = MnemodocServer::Indexer::Format::Registry.new(config)
      result = MnemodocServer::Indexer::Crawler.new([@corpus_dir], registry, config.exclude)
        .run(store, embedder, MnemodocServer::SingleFlight.new, concurrency: config.index.concurrency)

      if result[:indexed].zero?
        raise "indexed nothing from #{@corpus_dir} — the benchmark would measure an empty index"
      end
      # A partially indexed corpus silently shrinks recall; refuse rather than
      # publish a figure that blames the search for a setup failure.
      if result[:failed] > 0
        raise "#{result[:failed]} file(s) failed to index — refusing to report on a partial corpus"
      end
    end

    # Chunk headings keep their markup (`## Recency bias`) while annotations in
    # questions.yml carry the bare text. Comparing them raw silently scores
    # every question a miss — the first defect this harness caught was its own.
    private def normalize_heading(heading : String?) : String
      return "(top)" if heading.nil?
      heading.lstrip.lstrip('#').strip
    end

    private def ask(question : Question, config : MnemodocServer::Config, store : MnemodocServer::Store::SQLite,
                    embedder : MnemodocServer::Indexer::Embedder) : QuestionOutcome
      query_vec = embedder.embed_batch([question.question]).first
      results = MnemodocServer::Search::Hybrid.new(config.search).search(question.question, query_vec, store)

      returned = results.map { |result| "#{File.basename(result.chunk.file_path)} › #{normalize_heading(result.chunk.heading)}" }
      cost = results.sum { |result| @counter.count(result.chunk.content) }

      # Replays the shipped selection rule rather than a copy of it, so what is
      # measured is what the hook would actually inject.
      injected = MnemodocServer::Search::HookSelection.choose(results,
        similarity_threshold: config.hook.similarity_threshold,
        margin_threshold: config.hook.margin_threshold,
        max_passages: config.hook.max_passages)
      similarity = results.first?.try(&.similarity)
      injected_keys = injected.map { |result| "#{File.basename(result.chunk.file_path)} › #{normalize_heading(result.chunk.heading)}" }

      QuestionOutcome.new(
        question: question.question,
        retrieved_cost: cost,
        hit: returned.includes?(question.key),
        expected_file: question.expected_file,
        expected_heading: question.expected_heading,
        returned: returned,
        similarity: similarity,
        fired: !injected.empty?,
        expect_fire: question.expect_fire?,
        injected_count: injected.size,
        injected_cost: injected.sum { |result| @counter.count(result.chunk.content) },
        injected_hit: injected_keys.includes?(question.key),
      )
    end
  end
end
