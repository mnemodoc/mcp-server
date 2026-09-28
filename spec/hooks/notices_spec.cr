require "../spec_helper"
require "file_utils"

# The prompt hook runs before every user message. A notice on every prompt of
# an outage would be noise, and silence would hide the outage, so a notice is
# shown once per session and per failure, and the recovery is shown once too.
Spectator.describe MnemodocServer::Hooks::Notices do
  let(state_dir) { "/tmp/mnemodoc-notices-#{Random::Secure.hex(4)}" }

  before_each { Dir.mkdir_p(state_dir) }
  after_each { FileUtils.rm_rf(state_dir) }

  BACKEND  = "mnemodoc: documentation lookup skipped — the embedding backend did not answer (run `mnemodoc-server status`)."
  PAYLOAD  = "mnemodoc: documentation lookup skipped — the hook payload could not be read."
  INTERNAL = "mnemodoc: documentation lookup skipped — internal error (ArgumentError); see the mnemodoc log."
  RESTORED = "mnemodoc: documentation lookup restored."

  private def decide(outcome : String, session : String? = "s-1", dir : String? = state_dir,
                     error_type : String? = nil) : String?
    MnemodocServer::Hooks::Notices.decide(outcome, state_dir: dir, session: session, error_type: error_type)
  end

  it "names each failure in a sentence that carries no prompt and no exception message" do
    expect(decide("backend_error")).to eq(BACKEND)
    expect(decide("invalid_payload", session: "s-2")).to eq(PAYLOAD)
    expect(decide("internal_error", session: "s-3", error_type: "ArgumentError")).to eq(INTERNAL)
  end

  it "shows a failure once per session" do
    expect(decide("backend_error")).to eq(BACKEND)
    expect(decide("backend_error")).to be_nil
  end

  it "shows a different failure again" do
    decide("backend_error")
    expect(decide("internal_error", error_type: "ArgumentError")).to eq(INTERNAL)
  end

  it "shows the recovery once, then goes quiet" do
    decide("backend_error")
    expect(decide("injected")).to eq(RESTORED)
    expect(decide("injected")).to be_nil
  end

  it "says nothing on a decision when nothing had failed" do
    expect(decide("below_threshold")).to be_nil
    expect(decide("no_results")).to be_nil
  end

  it "keeps sessions apart" do
    expect(decide("backend_error", session: "s-a")).to eq(BACKEND)
    expect(decide("backend_error", session: "s-b")).to eq(BACKEND)
    expect(decide("no_results", session: "s-a")).to eq(RESTORED)
    expect(decide("backend_error", session: "s-b")).to be_nil
  end

  it "shows every failure when the session is unknown" do
    expect(decide("backend_error", session: nil)).to eq(BACKEND)
    expect(decide("backend_error", session: nil)).to eq(BACKEND)
  end

  it "shows every failure when there is nowhere to keep the state" do
    expect(decide("backend_error", dir: nil)).to eq(BACKEND)
    expect(decide("backend_error", dir: nil)).to eq(BACKEND)
  end

  # The session id comes from the client's payload and names a file: anything
  # that is not a plain identifier must not reach the filesystem.
  it "never writes a state file for a session id that is not a plain identifier" do
    expect(decide("backend_error", session: "../escape")).to eq(BACKEND)
    expect(decide("backend_error", session: "../escape")).to eq(BACKEND)
    expect(File.exists?(File.join(File.dirname(state_dir), "escape"))).to be_false
    expect(Dir.children(state_dir)).to be_empty
  end
end
