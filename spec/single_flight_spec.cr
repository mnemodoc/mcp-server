require "./spec_helper"

Spectator.describe MnemodocServer::SingleFlight do
  subject(sf) { MnemodocServer::SingleFlight.new }

  it "executes the block" do
    executed = false
    sf.run("key") { executed = true }
    expect(executed).to be_true
  end

  it "can be reused after completion" do
    count = 0
    sf.run("key") { count += 1 }
    sf.run("key") { count += 1 }
    expect(count).to eq(2)
  end

  # Deduplication applies to calls that genuinely overlap. Holding the leader
  # inside its block until the test releases it is what makes that overlap
  # certain: a fixed sleep only works while the scheduler is cooperative, and
  # under -Dpreview_mt a later fiber can arrive after the leader has finished
  # and legitimately become a leader itself.
  it "deduplicates concurrent calls for the same key" do
    call_count = 0
    mutex = Mutex.new
    done = Channel(Nil).new
    release = Channel(Nil).new

    3.times do
      spawn do
        sf.run("key") do
          mutex.synchronize { call_count += 1 }
          release.receive
        end
        done.send(nil)
      end
    end

    # Long enough for all three to have reached #run, and safe regardless: the
    # leader cannot get past its block before the release below.
    sleep 200.milliseconds
    release.send(nil)

    3.times { done.receive }
    expect(call_count).to eq(1)
  end
end
