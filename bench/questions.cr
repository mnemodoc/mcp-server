require "yaml"

module Bench
  # One annotated question: what a user would ask, and where the answer lives.
  #
  # The annotation is what turns a cost figure into a claim — without it the
  # benchmark could only report how little it returned, not whether what it
  # returned was right.
  struct Question
    include YAML::Serializable

    getter question : String
    getter expected_file : String
    getter expected_heading : String

    # Whether the prompt hook is expected to fire on this prompt. Off-topic
    # entries set it to false: a gate calibrated only on prompts that should
    # fire is calibrated on half the problem.
    @[YAML::Field(key: "expect_fire")]
    getter? expect_fire : Bool = true

    def initialize(@question, @expected_file, @expected_heading, @expect_fire = true)
    end

    # How the harness identifies a returned passage, and therefore how a hit is
    # decided: same file, same heading.
    def key : String
      "#{expected_file} › #{expected_heading}"
    end
  end

  module Questions
    def self.load(path : String) : Array(Question)
      Array(Question).from_yaml(File.read(path))
    end
  end
end
