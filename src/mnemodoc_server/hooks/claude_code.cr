module MnemodocServer
  module Hooks
    # Adapter for Claude Code hooks. Branches on `hook_event_name`: a PreToolUse
    # payload carries a single edited path under `tool_input.file_path`, a
    # UserPromptSubmit payload carries the user's text under `prompt`. Every
    # event shares the attribution fields (session_id, agent_id/agent_type,
    # transcript_path, cwd). Unknown events yield attribution only.
    class ClaudeCode < Adapter
      def parse(json : JSON::Any) : HookInput
        # The payload is whatever the client sent. JSON::Any#[]? reads as the
        # lenient accessor but raises on a receiver that is neither a hash nor
        # nil, so a root that is an array or a scalar used to take the whole
        # `context` command down — during a PreToolUse hook, in front of the
        # user. The adapter's own contract says it must not raise on missing or
        # unexpected keys; this is what makes that true.
        root = json.as_h?
        return HookInput.new unless root

        event = root["hook_event_name"]?.try(&.as_s?)
        files = [] of String
        query = ""

        case event
        when "PreToolUse"
          path = root["tool_input"]?.try(&.as_h?).try(&.["file_path"]?).try(&.as_s?)
          files << path if path && !path.empty?
        when "UserPromptSubmit"
          query = root["prompt"]?.try(&.as_s?) || ""
        end

        HookInput.new(
          event: event,
          files: files,
          query: query,
          session_id: root["session_id"]?.try(&.as_s?),
          agent_id: root["agent_id"]?.try(&.as_s?),
          agent_type: root["agent_type"]?.try(&.as_s?),
          transcript_path: root["transcript_path"]?.try(&.as_s?),
          cwd: root["cwd"]?.try(&.as_s?),
        )
      end
    end
  end
end
