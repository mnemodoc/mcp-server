module MnemodocServer
  module Hooks
    # The normalised, client-agnostic shape an Adapter produces from a raw hook
    # payload. The Context CLI command consumes only this struct, so it never
    # learns any client's JSON layout. All fields are optional: a hook event may
    # carry files OR a query, never both, and attribution fields may be absent.
    struct HookInput
      getter event : String?
      getter files : Array(String)
      getter task : String
      getter query : String
      getter session_id : String?
      getter agent_id : String?
      getter agent_type : String?
      getter transcript_path : String?
      getter cwd : String?

      def initialize(
        @event : String? = nil,
        @files : Array(String) = [] of String,
        @task : String = "",
        @query : String = "",
        @session_id : String? = nil,
        @agent_id : String? = nil,
        @agent_type : String? = nil,
        @transcript_path : String? = nil,
        @cwd : String? = nil,
      )
      end

      # Renders the sub-agent attribution for the audit log: "<id> (<type>)"
      # when both are present, whichever single field is present otherwise, and
      # an empty string when neither is (the common main-session case).
      def agent_label : String
        id = @agent_id
        type = @agent_type
        if id && type
          "#{id} (#{type})"
        elsif id
          id
        elsif type
          type
        else
          ""
        end
      end
    end
  end
end
