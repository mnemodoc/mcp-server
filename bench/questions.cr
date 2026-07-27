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

    def initialize(@question, @expected_file, @expected_heading)
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
