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

  it "deduplicates concurrent calls for the same key" do
    call_count = 0
    mutex = Mutex.new
    done = Channel(Nil).new

    3.times do
      spawn do
        sf.run("key") do
          mutex.synchronize { call_count += 1 }
          sleep 20.milliseconds
        end
        done.send(nil)
      end
    end

    3.times { done.receive }
    expect(call_count).to eq(1)
  end
end
