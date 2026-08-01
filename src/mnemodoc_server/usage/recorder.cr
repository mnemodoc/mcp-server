module MnemodocServer
  module Usage
    # The one place that knows what a usage event is. The three families of
    # producers — MCP tools, CLI subcommands, the prompt hook — do nothing but
    # call it, so the shape of an event has a single definition.
    module Recorder
      Log = ::Log.for("mnemodoc-server.usage.recorder")

      # Records an event from explicit fields. Never raises: this is
      # observability, and it has no claim on the path that serves
      # documentation.
      def self.record(config : Config, source : String, action : String, query : String?,
                      result_count : Int32, elapsed_ms : Int32?, files : Array(String),
                      session : String? = nil, agent : String? = nil) : Nil
        return unless config.usage.enabled?

        # Deduplicated here, once, rather than by each caller: a document served
        # twice by one call is one document served.
        Transport.send(config, UsageEvent.new(
          at: Time.utc.to_unix, source: source, action: action, query: query,
          result_count: result_count, elapsed_ms: elapsed_ms,
          session: session, agent: agent, files: files.uniq,
        ))
      rescue ex
        Log.debug { "usage recording failed: #{ex.message}" }
      end

      # Records an event from a tool result, deriving the served documents and
      # the result count from the payload rather than from the caller — so the
      # MCP and CLI surfaces cannot disagree about what a call served.
      def self.record_tool(config : Config, source : String, action : String,
                           result : MCP::ToolResult, query : String?, elapsed_ms : Int32?) : Nil
        return unless config.usage.enabled?

        record(config, source: source, action: action, query: query,
          result_count: UsageEvent.result_count_from(result), elapsed_ms: elapsed_ms,
          files: UsageEvent.files_from(result))
      rescue ex
        Log.debug { "usage recording failed: #{ex.message}" }
      end
    end
  end
end
