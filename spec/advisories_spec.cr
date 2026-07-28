require "./spec_helper"

Spectator.describe MnemodocServer::Advisories do
  before_each { MnemodocServer::Advisories.clear }
  after_each { MnemodocServer::Advisories.clear }

  it "collects and exposes deduplicated advisories" do
    MnemodocServer::Advisories.add("a")
    MnemodocServer::Advisories.add("a")
    MnemodocServer::Advisories.add("b")
    expect(MnemodocServer::Advisories.all).to eq(["a", "b"])
    expect(MnemodocServer.advisories).to eq(["a", "b"])
  end

  it "records a config-missing advisory when init_app! finds no config" do
    MnemodocServer::Advisories.clear
    MnemodocServer.init_app!("/nonexistent/path/.mnemodoc.yml")
    expect(MnemodocServer.advisories.any?(&.includes?("no config file found"))).to be_true
  end

  # Advisories are written at startup but READ on every tool response, from
  # whichever fiber is serving it — up to 32 at once in the daemon. The array
  # was mutated and copied without a lock.
  it "survives concurrent reads and writes" do
    MnemodocServer::Advisories.clear
    done = Channel(Nil).new
    8.times do |i|
      spawn do
        20.times { |j| MnemodocServer::Advisories.add("advisory #{i}-#{j}") }
        done.send(nil)
      end
    end
    8.times do
      spawn do
        50.times { MnemodocServer::Advisories.all }
        done.send(nil)
      end
    end
    16.times { done.receive }
    expect(MnemodocServer::Advisories.all.size).to eq(160)
  end
end
