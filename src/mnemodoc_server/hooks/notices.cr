module MnemodocServer
  module Hooks
    # Decides what the prompt hook tells the user about its own failures.
    #
    # The hook runs before every user message, so it has two ways to get this
    # wrong: stay silent, and an outage reads as "the documentation had nothing
    # to say"; speak on every prompt, and an outage fills the session with the
    # same line. A notice is therefore shown once per session and per failure,
    # and the recovery is shown once as well, so the user learns both that
    # injection stopped and that it came back.
    #
    # Each hook call is its own process, so the state lives on disk: one file
    # per session under the project's index directory, holding the failure last
    # shown. Sessions never read one another's file, which is what keeps two
    # parallel sessions from silencing each other.
    #
    # No sentence here carries the prompt or an exception message: a parse
    # error's message quotes the payload, and the payload is the prompt.
    module Notices
      Log = ::Log.for("mnemodoc-server.hooks.notices")

      FAILURES = {"backend_error", "invalid_payload", "internal_error"}

      RESTORED = "mnemodoc: documentation lookup restored."

      # A session id names a file, and it comes from the client's payload: only
      # a plain identifier may reach the filesystem.
      SESSION_ID = /\A[A-Za-z0-9_-]{1,128}\z/

      STATE_SUBDIR = "hook-notices"

      # A session that ends while failing leaves its file behind; files older
      # than this are swept whenever a new one is written. A session running
      # longer than that sees its failure notice once more, which is harmless.
      STATE_TTL = 7.days

      def self.failure?(outcome : String) : Bool
        FAILURES.includes?(outcome)
      end

      def self.message_for(outcome : String, error_type : String? = nil) : String
        case outcome
        when "backend_error"
          "mnemodoc: documentation lookup skipped — the embedding backend did not answer (run `mnemodoc-server status`)."
        when "invalid_payload"
          "mnemodoc: documentation lookup skipped — the hook payload could not be read."
        else
          "mnemodoc: documentation lookup skipped — internal error (#{error_type || "unknown"}); see the mnemodoc log."
        end
      end

      # Returns the notice to show for this call, or nil. Never raises: a notice
      # that cannot be rate-limited is shown rather than lost, and a recovery
      # that cannot be recorded is simply not announced.
      def self.decide(outcome : String, state_dir : String?, session : String?,
                      error_type : String? = nil) : String?
        file = state_file(state_dir, session)
        if failure?(outcome)
          return message_for(outcome, error_type) unless file
          key = failure_key(outcome, error_type)
          return nil if read_state(file) == key
          write_state(file, key)
          message_for(outcome, error_type)
        else
          return nil unless file && File.exists?(file)
          File.delete?(file)
          RESTORED
        end
      rescue ex
        Log.debug { "notice state unavailable: #{ex.class.name}" }
        failure?(outcome) ? message_for(outcome, error_type) : nil
      end

      # Two internal errors of different kinds are two different failures.
      private def self.failure_key(outcome : String, error_type : String?) : String
        outcome == "internal_error" ? "#{outcome}:#{error_type}" : outcome
      end

      private def self.state_file(state_dir : String?, session : String?) : String?
        return nil unless state_dir && session && SESSION_ID.matches?(session)
        return nil unless Dir.exists?(state_dir)
        File.join(state_dir, STATE_SUBDIR, session)
      end

      private def self.read_state(file : String) : String?
        File.exists?(file) ? File.read(file).strip : nil
      end

      private def self.write_state(file : String, key : String) : Nil
        dir = File.dirname(file)
        Dir.mkdir_p(dir)
        sweep(dir)
        File.write(file, key)
      end

      private def self.sweep(dir : String) : Nil
        cutoff = Time.utc - STATE_TTL
        Dir.each_child(dir) do |name|
          path = File.join(dir, name)
          File.delete?(path) if File.info(path).modification_time < cutoff
        end
      end
    end
  end
end
