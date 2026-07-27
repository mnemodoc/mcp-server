module MnemodocServer
  module Install
    # Raised when a target file exists but cannot be parsed. Rewriting it would
    # destroy whatever it held, so installation stops instead.
    class UnreadableTarget < Exception
    end

    # Wires MnemoDoc into Claude Code, and unwires it.
    #
    # Three things are written, in two shared files:
    #   * `~/.claude.json` — the MCP server entry.
    #   * `~/.claude/settings.json` — the two hooks and the permission entries.
    #
    # Both files belong to the user and already carry other tools' settings, so
    # everything here is read → modify → write with `JSON::Any`. A typed struct
    # would round-trip only the keys it knows about and silently drop the rest.
    #
    # The MCP entry carries **no** `--config`: the server walks up from the
    # working directory the client launches it in to find its project. A path
    # here would pin one global registration to a single repository.
    class ClaudeCode
      # Tools cleared in advance. Read-only ones only: `ingest_path` and
      # `delete_file` mutate the index, and a blanket `mcp__mnemodoc__*` would
      # grant any tool added later the same standing approval without anyone
      # deciding to.
      ALLOWED_TOOLS = %w(
        mcp__mnemodoc__query_documents
        mcp__mnemodoc__get_project_context
        mcp__mnemodoc__status
      )

      SERVER_NAME = "mnemodoc"

      def initialize(@binary : String, home : String = Path.home.to_s,
                     @hooks : Bool = true, @permissions : Bool = true)
        @claude_json = File.join(home, ".claude.json")
        @settings_json = File.join(home, ".claude", "settings.json")
      end

      # What `install` would write, as `{path => content}`. Computing this is
      # the same code path `apply` runs, so the dry run cannot describe
      # something other than what happens.
      def plan : Hash(String, String)
        changes = {@claude_json => pretty(with_server(read_object(@claude_json)))}
        if @hooks || @permissions
          changes[@settings_json] = pretty(with_settings(read_object(@settings_json)))
        end
        changes
      end

      def apply : Nil
        # Every target is parsed before anything is written, so a file that
        # cannot be read aborts the whole operation rather than leaving half of
        # it applied.
        plan.each { |path, content| write_atomic(path, content) }
      end

      # Removes only what `apply` added, matching hooks by the command string so
      # another tool's entry in the same list is never touched.
      def remove : Nil
        if File.exists?(@claude_json)
          claude = read_object(@claude_json)
          if servers = claude["mcpServers"]?.try(&.as_h?)
            servers.delete(SERVER_NAME)
            claude["mcpServers"] = JSON::Any.new(servers)
            write_atomic(@claude_json, pretty(claude))
          end
        end

        return unless File.exists?(@settings_json)
        settings = read_object(@settings_json)
        strip_permissions(settings)
        strip_hooks(settings)
        write_atomic(@settings_json, pretty(settings))
      end

      # The MCP server entry, exactly as it lands in the file.
      private def server_entry : JSON::Any
        JSON::Any.new({
          "type"    => JSON::Any.new("stdio"),
          "command" => JSON::Any.new(@binary),
          "args"    => JSON::Any.new([JSON::Any.new("serve")]),
        } of String => JSON::Any)
      end

      # The two hook commands, keyed by the event they attach to. PreToolUse
      # matches edits so role conventions arrive before code is written;
      # UserPromptSubmit injects matching passages for the prompt itself.
      private def hook_commands : Hash(String, {String?, String})
        {
          "PreToolUse"       => {"Edit|Write", "#{@binary} context --hook-stdin"},
          "UserPromptSubmit" => {nil, "#{@binary} prompt-hook"},
        }
      end

      private def with_server(hash : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        servers = hash["mcpServers"]?.try(&.as_h?) || {} of String => JSON::Any
        servers[SERVER_NAME] = server_entry
        hash["mcpServers"] = JSON::Any.new(servers)
        hash
      end

      private def with_settings(hash : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
        add_permissions(hash) if @permissions
        add_hooks(hash) if @hooks
        hash
      end

      private def add_permissions(hash : Hash(String, JSON::Any)) : Nil
        permissions = hash["permissions"]?.try(&.as_h?) || {} of String => JSON::Any
        allow = permissions["allow"]?.try(&.as_a?) || [] of JSON::Any
        existing = allow.compact_map(&.as_s?)
        ALLOWED_TOOLS.each do |tool|
          allow << JSON::Any.new(tool) unless existing.includes?(tool)
        end
        permissions["allow"] = JSON::Any.new(allow)
        hash["permissions"] = JSON::Any.new(permissions)
      end

      private def add_hooks(hash : Hash(String, JSON::Any)) : Nil
        hooks = hash["hooks"]?.try(&.as_h?) || {} of String => JSON::Any
        hook_commands.each do |event, (matcher, command)|
          entries = hooks[event]?.try(&.as_a?) || [] of JSON::Any
          next if entries.any? { |entry| entry_commands(entry).includes?(command) }

          entry = {"hooks" => JSON::Any.new([JSON::Any.new({
            "type"    => JSON::Any.new("command"),
            "command" => JSON::Any.new(command),
          } of String => JSON::Any)])} of String => JSON::Any
          matcher.try { |value| entry["matcher"] = JSON::Any.new(value) }
          entries << JSON::Any.new(entry)
          hooks[event] = JSON::Any.new(entries)
        end
        hash["hooks"] = JSON::Any.new(hooks)
      end

      private def strip_permissions(hash : Hash(String, JSON::Any)) : Nil
        permissions = hash["permissions"]?.try(&.as_h?)
        return unless permissions
        allow = permissions["allow"]?.try(&.as_a?)
        return unless allow
        permissions["allow"] = JSON::Any.new(allow.reject { |entry| ALLOWED_TOOLS.includes?(entry.as_s?) })
        hash["permissions"] = JSON::Any.new(permissions)
      end

      # Drops our hook entries and, when that empties a list, the event key
      # itself — a leftover `"UserPromptSubmit": []` is debris, not settings.
      private def strip_hooks(hash : Hash(String, JSON::Any)) : Nil
        hooks = hash["hooks"]?.try(&.as_h?)
        return unless hooks

        ours = hook_commands.values.map { |(_, command)| command }
        hook_commands.each_key do |event|
          entries = hooks[event]?.try(&.as_a?)
          next unless entries
          kept = entries.reject { |entry| !(entry_commands(entry) & ours).empty? }
          if kept.empty?
            hooks.delete(event)
          else
            hooks[event] = JSON::Any.new(kept)
          end
        end
        hash["hooks"] = JSON::Any.new(hooks)
      end

      # The command strings a hook entry carries, tolerating any shape the file
      # happens to hold — this reads a user-owned file, not one we control.
      private def entry_commands(entry : JSON::Any) : Array(String)
        entry["hooks"]?.try(&.as_a?).try(&.compact_map(&.["command"]?.try(&.as_s?))) || [] of String
      end

      # Reads a target as a plain hash. Absent means "start from nothing";
      # present but unparsable means stop, since rewriting it would destroy
      # whatever it held.
      private def read_object(path : String) : Hash(String, JSON::Any)
        return {} of String => JSON::Any unless File.exists?(path)
        JSON.parse(File.read(path)).as_h? || {} of String => JSON::Any
      rescue JSON::ParseException
        raise UnreadableTarget.new("#{path} is not valid JSON; refusing to rewrite it")
      end

      private def pretty(value : Hash(String, JSON::Any)) : String
        "#{JSON::Any.new(value).to_pretty_json}\n"
      end

      # Writes through a temporary file in the same directory, then renames.
      # A crash mid-write then leaves the previous settings intact rather than a
      # truncated file the client would refuse to start with.
      private def write_atomic(path : String, content : String) : Nil
        Dir.mkdir_p(File.dirname(path))
        temp = "#{path}.mnemodoc-#{Random::Secure.hex(6)}"
        File.write(temp, content)
        File.rename(temp, path)
      end
    end
  end
end
