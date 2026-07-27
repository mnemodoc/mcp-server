require "./spec_helper"
require "../bench/questions"

# Recall is only a measure of retrieval if every annotation points at a passage
# that exists. These tests are the guard against a corpus edit quietly turning
# the recall figure into a measure of nothing.
Spectator.describe Bench::Questions do
  let(root) { File.expand_path("../bench", __DIR__) }
  let(questions) { Bench::Questions.load(File.join(root, "questions.yml")) }
  let(corpus) { File.join(root, "corpus") }

  it "loads a non-empty set" do
    expect(questions.size).to be > 0
  end

  it "annotates every question with a file and a heading" do
    questions.each do |entry|
      expect(entry.question).not_to be_empty
      expect(entry.expected_file).not_to be_empty
      expect(entry.expected_heading).not_to be_empty
    end
  end

  it "points every annotation at a corpus file that exists" do
    missing = questions.map(&.expected_file).uniq!.reject { |name| File.exists?(File.join(corpus, name)) }
    expect(missing).to be_empty
  end

  it "points every annotation at a heading that exists in that file" do
    dangling = questions.reject do |entry|
      path = File.join(corpus, entry.expected_file)
      next false unless File.exists?(path)
      File.read(path).lines.any? do |line|
        stripped = line.lstrip
        stripped.starts_with?("#") && stripped.lstrip('#').strip == entry.expected_heading
      end
    end.map { |entry| "#{entry.expected_file} › #{entry.expected_heading}" }

    expect(dangling).to be_empty
  end

  # Every corpus file should be exercised, or part of the baseline is being
  # charged to the benchmark without any question ever reaching it.
  it "covers every corpus file with at least one question" do
    indexed = questions.map(&.expected_file).to_set
    uncovered = Dir.glob(File.join(corpus, "*.md")).map { |path| File.basename(path) }.reject { |name| indexed.includes?(name) }
    expect(uncovered).to be_empty
  end
end
