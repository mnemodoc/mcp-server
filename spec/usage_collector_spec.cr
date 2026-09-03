# spec/usage_collector_spec.cr
require "./spec_helper"
require "file_utils"

Spectator.describe MnemodocServer::Usage::Collector do
  let(tmp_dir) { "/tmp/mnemodoc-usagecol-#{Random::Secure.hex(4)}" }
  let(db_path) { File.join(tmp_dir, "index.db") }
  let(config) do
    MnemodocServer::Config.from_yaml("paths:\n  - #{tmp_dir}\ndb:\n  path: #{db_path}\n")
  end
  let(store) { MnemodocServer::Store::SQLite.new(db_path) }

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each do
    store.close
    delete_db(db_path)
    FileUtils.rm_rf(tmp_dir)
  end

  private def event(at : Int64, action : String = "query_documents",
                    files : Array(String) = ["/docs/a.md"]) : MnemodocServer::Usage::UsageEvent
    MnemodocServer::Usage::UsageEvent.new(
      at: at, source: "tool", action: action, query: "q", result_count: files.size,
      elapsed_ms: 3, session: nil, agent: nil, files: files)
  end

  # The periodic sweep used to be an unbounded `loop` in Daemon#run_internal,
  # with no reference to the collector's stopping flag. Shutdown closed the
  # store while that fiber slept, and its next purge prepared a statement on a
  # freed sqlite3 handle — a SIGSEGV in libsqlite3, which no `rescue` can catch.
  # Measured on CI: dev:spec-mt died in sqlite3HashFind, reached from
  # Usage::Collector#purge_expired.
  it "returns from the periodic sweep once it is stopped" do
    collector = MnemodocServer::Usage::Collector.new(config, store)
    done = Channel(Nil).new(1)
    # An interval far longer than the test: stopping must interrupt the wait,
    # not be noticed only at the next tick.
    spawn do
      collector.sweep_until_stopped(1.hour)
      done.send(nil)
    end
    Fiber.yield

    collector.stop
    select
    when done.receive
      # Unwound, so the store can be closed safely after this point.
    when timeout(5.seconds)
      fail "the periodic sweep did not return after #stop"
    end
  end

  it "inserts an event delivered over the socket" do
    collector = MnemodocServer::Usage::Collector.new(config, store)
    ready = Channel(Nil).new
    spawn { collector.listen(ready) }
    ready.receive

    expect(MnemodocServer::Usage::Transport.send(config, event(100_i64))).to eq(:socket)
    # The daemon inserts on its own fiber; yield until it lands.
    10.times do
      break if store.usage.count > 0
      sleep 20.milliseconds
    end
    collector.stop

    expect(store.usage.count).to eq(1_i64)
    expect(store.usage.documents(0_i64).map(&.[:path])).to eq(["/docs/a.md"])
  end

  it "removes its socket when it stops" do
    collector = MnemodocServer::Usage::Collector.new(config, store)
    ready = Channel(Nil).new
    spawn { collector.listen(ready) }
    ready.receive
    expect(File.exists?(config.usage_socket_path)).to be_true

    collector.stop
    10.times do
      break unless File.exists?(config.usage_socket_path)
      sleep 20.milliseconds
    end
    expect(File.exists?(config.usage_socket_path)).to be_false
  end

  # A socket left behind by a hard kill must not stop the next daemon binding.
  it "replaces a stale socket file at startup" do
    File.write(config.usage_socket_path, "")
    collector = MnemodocServer::Usage::Collector.new(config, store)
    ready = Channel(Nil).new
    spawn { collector.listen(ready) }
    ready.receive
    expect(File.info(config.usage_socket_path).type.socket?).to be_true
    collector.stop
  end

  it "imports the spool and deletes it" do
    File.write(config.usage_spool_path, "#{event(100_i64).to_json}\n#{event(200_i64).to_json}\n")
    collector = MnemodocServer::Usage::Collector.new(config, store)

    expect(collector.import_spool).to eq(2)
    expect(store.usage.count).to eq(2_i64)
    expect(File.exists?(config.usage_spool_path)).to be_false
  end

  # One bad line must cost that line, not the batch: the spool is written by
  # processes that can be killed mid-write.
  it "skips a malformed line without losing the rest" do
    File.write(config.usage_spool_path,
      "#{event(100_i64).to_json}\n{not json\n#{event(200_i64).to_json}\n")
    collector = MnemodocServer::Usage::Collector.new(config, store)

    expect(collector.import_spool).to eq(2)
    expect(store.usage.count).to eq(2_i64)
  end

  it "does nothing when there is no spool" do
    collector = MnemodocServer::Usage::Collector.new(config, store)
    expect(collector.import_spool).to eq(0)
  end

  it "purges events older than the window" do
    now = Time.utc.to_unix
    store.usage.insert(event(now - 100_i64 * 86_400))
    store.usage.insert(event(now))
    collector = MnemodocServer::Usage::Collector.new(config, store)

    expect(collector.purge_expired).to eq(1)
    expect(store.usage.count).to eq(1_i64)
  end
end
