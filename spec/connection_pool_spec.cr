require "./spec_helper"

# The pool sits on the path of every embedding request and holds state shared
# between indexing fibers. A client handed to two callers at once, or one
# returned to the pool while still mid-response, corrupts an embedding that is
# then written to the index without any error — the search degrades and
# nothing says why.
Spectator.describe MnemodocServer::ConnectionPool do
  let(uri) { URI.parse("http://127.0.0.1:11434") }

  it "hands the same client to only one caller at a time" do
    pool = MnemodocServer::ConnectionPool.new
    begin
      first = pool.checkout(uri)
      pool.checkin(uri, first)
      second = pool.checkout(uri)
      third = pool.checkout(uri)
      # The idle one is reused; the second caller must get a different object,
      # not the one already in use.
      expect(second).to be(first)
      expect(third).not_to be(second)
    ensure
      pool.close_all
    end
  end

  # Every fiber holds its client until the test releases them all, so the
  # sixteen checkouts genuinely overlap. Yielding instead only guarantees that
  # while scheduling is cooperative: under -Dpreview_mt a fiber can check its
  # client back in before another checks one out, and reusing it then is
  # correct behaviour, not a violation.
  it "never gives one client to two concurrent fibers" do
    pool = MnemodocServer::ConnectionPool.new
    taken = [] of HTTP::Client
    mutex = Mutex.new
    held = Channel(Nil).new
    release = Channel(Nil).new
    done = Channel(Nil).new
    begin
      16.times do
        spawn do
          client = pool.checkout(uri)
          mutex.synchronize { taken << client }
          held.send(nil)
          release.receive
          pool.checkin(uri, client)
          done.send(nil)
        end
      end

      16.times { held.receive } # all sixteen are now holding one
      expect(taken.map(&.object_id).uniq!.size).to eq(16)

      16.times { release.send(nil) }
      16.times { done.receive }
    ensure
      pool.close_all
    end
  end

  it "keeps at most the configured number of idle clients" do
    pool = MnemodocServer::ConnectionPool.new(30, 2)
    begin
      clients = Array.new(5) { pool.checkout(uri) }
      clients.each { |client| pool.checkin(uri, client) }
      # Two are retained; the rest were closed rather than accumulated.
      kept = Array.new(2) { pool.checkout(uri) }
      expect(kept.map(&.object_id).uniq!.size).to eq(2)
      expect(pool.checkout(uri)).not_to be(kept.first)
    ensure
      pool.close_all
    end
  end

  it "separates hosts" do
    pool = MnemodocServer::ConnectionPool.new
    begin
      other = URI.parse("http://127.0.0.1:9999")
      first = pool.checkout(uri)
      pool.checkin(uri, first)
      expect(pool.checkout(other)).not_to be(first)
    ensure
      pool.close_all
    end
  end
end

# `localhost` resolves to ::1 before 127.0.0.1 on macOS, and Ollama listens on
# 127.0.0.1 only. Under Crystal 1.20.3's polling event loop a refused
# non-blocking connect is reported as a success on darwin — connect(2) is
# retried after the socket turns writable and SO_ERROR is never read — so
# TCPSocket.new settled on the dead ::1 socket, never tried 127.0.0.1, and the
# first write failed with "Broken pipe". The default ollama.host could not
# reach a default Ollama. On Linux the stdlib reports the refusal and these
# examples pass either way.
Spectator.describe "ConnectionPool reaching a host by name" do
  private def ipv4_only_server(&)
    server = HTTP::Server.new do |context|
      context.response.print(context.request.headers["Host"]? || "")
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield address.port
    ensure
      server.close
    end
  end

  it "reaches a server that listens on 127.0.0.1 only, through localhost" do
    ipv4_only_server do |port|
      pool = MnemodocServer::ConnectionPool.new(timeout: 2)
      uri = URI.parse("http://localhost:#{port}")
      client = pool.checkout(uri)
      begin
        response = client.get("/")
        expect(response.status_code).to eq(200)
        # The request still names the host it was addressed to.
        expect(response.body).to eq("localhost:#{port}")
      ensure
        pool.discard(client)
      end
    end
  end

  it "still fails when no address of the host answers" do
    pool = MnemodocServer::ConnectionPool.new(timeout: 2)
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.local_address.port
    closed.close
    client = pool.checkout(URI.parse("http://localhost:#{port}"))
    begin
      expect { client.get("/") }.to raise_error(Socket::Error)
    ensure
      pool.discard(client)
    end
  end
end
