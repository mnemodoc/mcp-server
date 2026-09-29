require "./spec_helper"
require "file_utils"
require "http/server"

# Pins the exit of an idle daemon whose teardown has something to log.
#
# When a fiber still holds the index at shutdown — here the boot crawl, parked
# in an embedding call that never returns — the teardown gives up on it after
# SHUTDOWN_GRACE and logs so. In 1.4.0 that last entry was queued on the async log dispatcher
# just before close_log_file! closed the file underneath it: the dispatcher died
# on the write, and the exit-time flush of the Log builder waited on it forever.
# The process then lived on — not serving, not polling, holding the index open —
# which is how daemons measured nine days old came about.
#
# Driven as a real subprocess: the hang sits in the process's own at_exit
# handlers, which no in-process example ever reaches.
Spectator.describe "daemon exit" do
  let(binary) { File.expand_path(File.join(__DIR__, "..", "bin", "mnemodoc-server")) }
  let(tmp_dir) { "/tmp/mnemodoc-daemon-exit-#{Random::Secure.hex(4)}" }
  let(docs_dir) { File.join(tmp_dir, "docs") }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }
  let(log_path) { File.join(tmp_dir, "daemon.log") }

  # daemon_idle_timeout (1 s) + SHUTDOWN_GRACE (5 s) + 10 s of slack.
  EXIT_DEADLINE = 16.seconds

  before_each { Dir.mkdir_p(docs_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Ollama points at a server that accepts and never answers, so the boot
  # crawl holds the index through the idle shutdown.
  private def write_fixture(port : Int32) : Nil
    File.write(File.join(docs_dir, "note.md"), "# Note\n\nBody.\n")
    File.write(config_path, <<-YAML)
    paths:
      - #{docs_dir}
    ollama:
      host: http://127.0.0.1:#{port}
      model: test
      timeout: 120
    db:
      path: #{File.join(tmp_dir, "index.db")}
    server:
      daemon_idle_timeout: 1
      daemon_watch: true
      daemon_watch_interval: 1
      log_file: #{log_path}
      log_level: info
    YAML
  end

  it "exits on its own after an idle shutdown that leaves a fiber behind" do
    skip "build the binary first (mise dev:build)" unless File.exists?(binary)

    hanging = HTTP::Server.new { |_ctx| sleep }
    addr = hanging.bind_tcp("127.0.0.1", 0)
    spawn { hanging.listen }
    Fiber.yield

    write_fixture(addr.port)
    process = Process.new(
      binary,
      ["serve", "--daemon", "--config", config_path],
      output: Process::Redirect::Close,
      error: Process::Redirect::Close
    )

    exited = Channel(Nil).new(1)
    spawn do
      process.wait
      exited.send(nil)
    end

    begin
      outcome =
        select
        when exited.receive
          :exited
        when timeout(EXIT_DEADLINE)
          :still_running
        end
      expect(outcome).to eq(:exited)
      expect(File.read(log_path)).to contain("a fiber still held the index")
    ensure
      process.terminate(graceful: false) rescue nil
      hanging.close
    end
  end
end
