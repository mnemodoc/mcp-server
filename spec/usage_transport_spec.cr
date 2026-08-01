# spec/usage_transport_spec.cr
require "./spec_helper"
require "file_utils"

Spectator.describe MnemodocServer::Usage::Transport do
  let(tmp_dir) { "/tmp/mnemodoc-usagetx-#{Random::Secure.hex(4)}" }
  let(config) do
    MnemodocServer::Config.from_yaml(
      "paths:\n  - #{tmp_dir}\ndb:\n  path: #{File.join(tmp_dir, "index.db")}\n")
  end

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  private def event : MnemodocServer::Usage::UsageEvent
    MnemodocServer::Usage::UsageEvent.new(
      at: 1_700_000_000_i64, source: "tool", action: "query_documents", query: "q",
      result_count: 1, elapsed_ms: 3, session: nil, agent: nil, files: ["/docs/a.md"],
    )
  end

  it "delivers one JSON line to a listening socket" do
    received = Channel(String).new(1)
    server = UNIXServer.new(config.usage_socket_path)
    spawn do
      client = server.accept
      received.send(client.gets || "")
      client.close
    end
    Fiber.yield

    expect(MnemodocServer::Usage::Transport.send(config, event)).to eq(:socket)
    line = received.receive
    server.close

    parsed = MnemodocServer::Usage::UsageEvent.from_json(line)
    expect(parsed.action).to eq("query_documents")
    expect(parsed.files).to eq(["/docs/a.md"])
    expect(File.exists?(config.usage_spool_path)).to be_false
  end

  # No daemon is a supported configuration, not a failure: the event has to
  # survive it, or the numbers understate without saying so.
  it "spools the event when nothing is listening" do
    expect(MnemodocServer::Usage::Transport.send(config, event)).to eq(:spooled)
    expect(MnemodocServer::Usage::UsageEvent.from_json(File.read(config.usage_spool_path).lines.first).action)
      .to eq("query_documents")
  end

  it "spools when the socket path is a plain file nobody accepts on" do
    File.write(config.usage_socket_path, "")
    expect(MnemodocServer::Usage::Transport.send(config, event)).to eq(:spooled)
    expect(File.exists?(config.usage_spool_path)).to be_true
  end

  it "appends rather than overwriting" do
    2.times { MnemodocServer::Usage::Transport.send(config, event) }
    expect(File.read(config.usage_spool_path).lines.size).to eq(2)
  end

  # The guard the whole design rests on: an unwritable spool must not raise into
  # the caller, because the caller is serving documentation.
  it "reports a drop instead of raising when even the spool fails" do
    File.delete(config.usage_spool_path) if File.exists?(config.usage_spool_path)
    Dir.mkdir_p(config.usage_spool_path)
    expect(MnemodocServer::Usage::Transport.send(config, event)).to eq(:dropped)
  end
end
