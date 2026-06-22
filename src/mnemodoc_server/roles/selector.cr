module MnemodocServer
  module Roles
    # Raised when the context section declares no roles.
    class NoRolesError < Exception; end

    # Raised when no rule matches, no default role is set, and the context
    # bundle is empty so a semantic tie-break is impossible.
    class NeedSignalError < Exception; end

    # One role's rule score, exposed to the client for transparency.
    struct Candidate
      getter name : String
      getter score : Int32

      def initialize(@name : String, @score : Int32)
      end
    end

    # The outcome of a selection: the chosen role, a human-readable reason, and
    # every role's rule score.
    class Selection
      getter role : Role
      getter reason : String
      getter candidates : Array(Candidate)

      def initialize(@role : Role, @reason : String, @candidates : Array(Candidate))
      end
    end

    # Selects the role to adopt from the current files/task/query (B3 algorithm).
    # Rules decide when decisive (score above threshold and clear margin over
    # runner-up); the embedder arbitrates ambiguous shortlists.
    class Selector
      FILE_WEIGHT  = 3
      TASK_WEIGHT  = 2
      QUERY_WEIGHT = 1
      # Minimum gap between the top score and the runner-up for the top to be
      # decisive. Below it, rules are ambiguous and semantics arbitrate.
      MARGIN = 2
      # A top score below this is weak (e.g. a single query keyword) and is not
      # trusted on its own; semantics arbitrate among the contenders.
      WEAK_THRESHOLD = 3

      # base_dir is the config file's directory: when_files globs are relative to
      # it, so anchoring them there lets absolute file paths (fed by PreToolUse
      # hooks) match. Nil keeps the historical relative-only matching.
      def initialize(@roles : Array(Role), @default : Role?, @embedder : Indexer::Embedder?,
                     @base_dir : String? = nil)
        @desc_cache = {} of String => Array(Float32)
      end

      # Builds a selector from the context section of the config, resolving each
      # role file path against the config file's directory. This is the single
      # wiring point shared by the get_project_context MCP tool and the `context`
      # CLI command, so both channels select roles identically.
      def self.from_config(config : Config, embedder : Indexer::Embedder?) : Selector
        roles = config.context.roles.map do |role_config|
          Role.new(role_config, config.resolve_context_path(role_config.file))
        end
        default_role = config.context.default.try do |path|
          Role.new(RoleConfig.new(file: path), config.resolve_context_path(path))
        end
        new(roles, default_role, embedder, config.source_dir)
      end

      # Runs the B3 cascade and returns the chosen role with its rationale.
      def select(files : Array(String), task : String, query : String) : Selection
        raise NoRolesError.new if @roles.empty?

        scored = score_all(files, task, query)
        candidates = scored.map { |entry| Candidate.new(entry[:role].name, entry[:score]) }
        top = scored.first
        runner_score = scored.size > 1 ? scored[1][:score] : 0

        if top[:score] >= WEAK_THRESHOLD && (top[:score] - runner_score) >= MARGIN
          return Selection.new(top[:role], rule_reason(top[:role], files, task, query, top[:score]), candidates)
        end

        shortlist = scored.select { |entry| entry[:score] >= top[:score] - MARGIN }.map { |entry| entry[:role] }

        # A positive-but-weak score with no rival is still a real, unique signal,
        # so it wins outright. The `> 0` guard matters: a top score of 0 means no
        # rule fired at all, which must fall through to the default path below
        # rather than be announced as a "unique candidate".
        if shortlist.size == 1 && top[:score] > 0
          return Selection.new(shortlist.first,
            "weak rule match, unique candidate → #{shortlist.first.name} (score #{top[:score]})", candidates)
        end

        # No rule fired at all (top score 0): there is nothing for the semantic
        # tie-break to arbitrate. The context bundle would be just the raw
        # basename of an out-of-domain file, and embedding it yields an
        # arbitrary, misleading role. Fall back to the configured default, or
        # signal the caller. This guard MUST precede the semantic tie-break,
        # which is only meaningful among roles that actually matched a rule.
        if top[:score] == 0
          if default = @default
            return Selection.new(default, "no matching rule; default role", candidates)
          end
          raise NeedSignalError.new
        end

        # top score > 0 here: at least one input matched a rule, so the bundle
        # is non-empty and the semantic tie-break has real contenders to rank.
        bundle = context_bundle(files, task, query)

        pick = semantic_pick(shortlist, bundle)
        Selection.new(pick[:role],
          "rules ambiguous (top #{top[:score]}); semantic tie-break → #{pick[:role].name} (cos #{pick[:cosine].round(2)})",
          candidates)
      end

      private def score_all(files : Array(String), task : String, query : String)
        @roles.map { |role| {role: role, score: score_role(role, files, task, query)} }
          .sort_by! { |entry| -entry[:score] }
      end

      private def score_role(role : Role, files : Array(String), task : String, query : String) : Int32
        file_hits(role, files) * FILE_WEIGHT +
          task_hits(role, task) * TASK_WEIGHT +
          query_hits(role, query) * QUERY_WEIGHT
      end

      private def file_hits(role : Role, files : Array(String)) : Int32
        files.count { |path| role.config.when_files.any? { |glob| glob_match?(glob, path) } }
      end

      # Matches a file path against a when_files glob. The glob is relative to the
      # config directory, so we try it both verbatim (relative input, e.g. the CLI
      # --files flag) and anchored at base_dir (absolute input, e.g. a PreToolUse
      # hook's tool_input.file_path). Globstar semantics are preserved on both
      # forms. An absolute path outside base_dir matches neither and falls through
      # to the default role.
      private def glob_match?(glob : String, path : String) : Bool
        return true if File.match?(glob, path)
        if base = @base_dir
          return true if File.match?(File.join(base, glob), path)
        end
        false
      end

      private def task_hits(role : Role, task : String) : Int32
        return 0 if task.empty?
        lower = task.downcase
        role.config.when_task.count { |keyword| lower.includes?(keyword.downcase) }
      end

      private def query_hits(role : Role, query : String) : Int32
        return 0 if query.empty?
        lower = query.downcase
        role.config.when_query.count { |keyword| lower.includes?(keyword.downcase) }
      end

      private def context_bundle(files : Array(String), task : String, query : String) : String
        parts = files.map { |path| File.basename(path) }
        parts << task unless task.empty?
        parts << query unless query.empty?
        parts.join(" ").strip
      end

      private def semantic_pick(shortlist : Array(Role), bundle : String)
        embedder = @embedder || raise NeedSignalError.new
        bundle_vec = embedder.embed_batch([bundle]).first
        best = shortlist.first
        best_cosine = -1.0
        shortlist.each do |role|
          cosine = Search::Semantic.cosine_similarity(bundle_vec, description_embedding(embedder, role))
          if cosine > best_cosine
            best_cosine = cosine
            best = role
          end
        end
        {role: best, cosine: best_cosine}
      end

      private def description_embedding(embedder : Indexer::Embedder, role : Role) : Array(Float32)
        @desc_cache[role.name] ||= embedder.embed_batch([role.config.description]).first
      end

      private def rule_reason(role : Role, files : Array(String), task : String, query : String, score : Int32) : String
        parts = [] of String
        fh = file_hits(role, files)
        parts << "files: #{fh} matched (→#{fh * FILE_WEIGHT})" if fh > 0
        th = task_hits(role, task)
        parts << "task: #{th} kw (→#{th * TASK_WEIGHT})" if th > 0
        qh = query_hits(role, query)
        parts << "query: #{qh} kw (→#{qh * QUERY_WEIGHT})" if qh > 0
        "#{parts.join("; ")} → score #{score}, net"
      end
    end
  end
end
