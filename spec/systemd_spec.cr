require "./spec_helper"
require "file_utils"

# SystemD notifications run on the daemon's critical path: readiness, and then
# a watchdog ping the supervisor kills the unit for missing. Neither may throw,
# and neither may leak a descriptor per attempt.
Spectator.describe MnemodocServer::SystemD do
  let(tmp_dir) { "/tmp/mnemodoc-sd-#{Random::Secure.hex(4)}" }
  before_each { Dir.mkdir_p(tmp_dir) }
  after_each do
    MnemodocServer::SystemD.reset_socket
    FileUtils.rm_rf(tmp_dir)
  end

  private def open_descriptors : Int32
    Dir.children("/dev/fd").size
  end

  it "does nothing when NOTIFY_SOCKET is unset" do
    with_env({} of String => String) do
      ENV.delete("NOTIFY_SOCKET")
      expect { MnemodocServer::SystemD.ready }.not_to raise_error
    end
  end

  # A socket path that does not exist is the ordinary case when a unit is
  # reloaded, or when NOTIFY_SOCKET is inherited by something systemd is no
  # longer listening for. Opening it raises, and that exception used to travel
  # out of notify — through transport.on_ready at startup, and inside the
  # watchdog fiber, where it killed the fiber silently and left the supervisor
  # waiting for pings that never came again.
  it "stays quiet when the notify socket cannot be opened" do
    with_env({"NOTIFY_SOCKET" => File.join(tmp_dir, "absent.sock")}) do
      expect { MnemodocServer::SystemD.ready }.not_to raise_error
      expect { MnemodocServer::SystemD.stopping }.not_to raise_error
    end
  end

  it "does not leak a descriptor per failed notification" do
    with_env({"NOTIFY_SOCKET" => File.join(tmp_dir, "absent.sock")}) do
      MnemodocServer::SystemD.ready
      baseline = open_descriptors
      30.times { MnemodocServer::SystemD.ready }
      expect(open_descriptors - baseline).to be < 5
    end
  end

  # The receiving end going away mid-session is the case the cached socket has
  # to survive: the send fails, the cached handle is dropped, and the next call
  # opens a fresh one. Dropping it without closing leaked one each time.
  it "does not leak a descriptor when the receiver disappears" do
    socket_path = File.join(tmp_dir, "notify.sock")
    server = UNIXServer.new(socket_path, type: Socket::Type::DGRAM)
    with_env({"NOTIFY_SOCKET" => socket_path}) do
      MnemodocServer::SystemD.ready
      baseline = open_descriptors
      server.close
      File.delete(socket_path) rescue nil
      30.times { MnemodocServer::SystemD.ready }
      expect(open_descriptors - baseline).to be < 5
    end
  end
end
