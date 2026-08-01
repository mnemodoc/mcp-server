require "./spec_helper"

# Progress and the log both write to stderr, and the progress bar rewrites its
# line in place: an info line landing mid-bar produces "20%2026-08-01T... INFO"
# and neither is readable afterwards. Only one of them may own the stream while
# the bar is up, so the info-level chatter is held back and released after.
#
# Warnings and errors are deliberately NOT held back: they are rare, and losing
# one to keep a bar tidy would be a bad trade.
Spectator.describe "log hushing while progress owns stderr" do
  after_each { MnemodocServer.release_log! }

  # A synchronous dispatcher, so an entry is in the buffer by the time the
  # block returns: the default backend hands entries to a fiber, and the
  # assertion would race it.
  private def captured_log(&) : String
    io = IO::Memory.new
    ::Log.setup do |builder|
      builder.bind "mnemodoc-server.*", :info, ::Log::IOBackend.new(io, dispatcher: ::Log::DispatchMode::Sync)
    end
    yield
    io.to_s
  end

  it "holds back info while hushed and lets warnings through" do
    output = captured_log do
      MnemodocServer.hush_log!
      ::Log.for("mnemodoc-server.test").info { "chatter" }
      ::Log.for("mnemodoc-server.test").warn { "trouble" }
    end

    expect(output).not_to contain("chatter")
    expect(output).to contain("trouble")
  end

  it "restores info once the bar is gone" do
    output = captured_log do
      MnemodocServer.hush_log!
      MnemodocServer.release_log!
      ::Log.for("mnemodoc-server.test").info { "after" }
    end

    expect(output).to contain("after")
  end

  # Called from an ensure block on paths that may never have hushed anything.
  it "tolerates a release that was never hushed" do
    expect { MnemodocServer.release_log! }.not_to raise_error
  end
end
