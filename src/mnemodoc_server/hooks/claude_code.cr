module MnemodocServer
  module Hooks
    # Adapter for Claude Code hooks. Branches on `hook_event_name`: a PreToolUse
    # payload carries a single edited path under `tool_input.file_path`, a
    # UserPromptSubmit payload carries the user's text under `prompt`. Every
    # event shares the attribution fields (session_id, agent_id/agent_type,
    # transcript_path, cwd). Unknown events yield attribution only.
    class ClaudeCode < Adapter
      def parse(json : JSON::Any) : HookInput
        event = json["hook_event_name"]?.try(&.as_s?)
        files = [] of String
        query = ""

        case event
        when "PreToolUse"
          path = json.dig?("tool_input", "file_path").try(&.as_s?)
          files << path if path && !path.empty?
        when "UserPromptSubmit"
          query = json["prompt"]?.try(&.as_s?) || ""
        end

        HookInput.new(
          event: event,
          files: files,
          query: query,
          session_id: json["session_id"]?.try(&.as_s?),
          agent_id: json["agent_id"]?.try(&.as_s?),
          agent_type: json["agent_type"]?.try(&.as_s?),
          transcript_path: json["transcript_path"]?.try(&.as_s?),
          cwd: json["cwd"]?.try(&.as_s?),
        )
      end
    end
  end
end
