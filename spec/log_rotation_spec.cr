require "./spec_helper"
require "file_utils"

# SIGUSR1 makes the server reopen its log file so logrotate can move the old
# one aside. Reopening dropped the handle without closing it: every rotation
# leaked a descriptor AND kept the rotated file alive on disk, so a long-lived
# daemon slowly accumulated both.
Spectator.describe "log file rotation" do
  let(tmp_dir) { "/tmp/mnemodoc-logrot-#{Random::Secure.hex(4)}" }
  let(config_path) { File.join(tmp_dir, ".mnemodoc.yml") }
  let(log_path) { File.join(tmp_dir, "server.log") }

  before_each do
    Dir.mkdir_p(tmp_dir)
    File.write(config_path, <<-YAML)
    paths:
      - #{tmp_dir}
    db:
      path: #{File.join(tmp_dir, "index.db")}
    server:
      log_file: #{log_path}
    YAML
  end

  after_each do
    # Put the global logger back on stderr for whatever example runs next.
    File.write(config_path, "paths:\n  - #{tmp_dir}\nserver:\n  log_file: stderr\n")
    MnemodocServer.init_app!(config_path)
    FileUtils.rm_rf(tmp_dir)
  end

  private def open_descriptors : Int32
    Dir.children("/dev/fd").size
  end

  it "closes the previous handle instead of leaking one per rotation" do
    MnemodocServer.init_app!(config_path)
    MnemodocServer::Log.info { "first line" }

    baseline = open_descriptors
    5.times do |i|
      MnemodocServer.reopen_log_file!
      MnemodocServer::Log.info { "line #{i}" }
    end

    # One handle is legitimately open at any time; twenty rotations must not
    # leave twenty behind.
    expect(open_descriptors - baseline).to be < 5
  end
end
