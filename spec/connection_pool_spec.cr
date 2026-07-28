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
