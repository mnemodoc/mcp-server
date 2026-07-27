require "./spec_helper"
require "file_utils"

Spectator.describe MnemodocServer::Advisories do
  before_each { MnemodocServer::Advisories.clear }
  after_each do
    MnemodocServer::Advisories.clear
    restore_project_state
  end

  it "collects and exposes deduplicated advisories" do
    MnemodocServer::Advisories.add("a")
    MnemodocServer::Advisories.add("a")
    MnemodocServer::Advisories.add("b")
    expect(MnemodocServer::Advisories.all).to eq(["a", "b"])
    expect(MnemodocServer.advisories).to eq(["a", "b"])
  end

  # An explicit --config naming a file that is not there: the project is taken
  # at its word, so validation still runs and fails on the absent paths — but
  # the advisory must have been recorded first, since it is what explains why.
  it "records a config-missing advisory when init_app! finds no config" do
    MnemodocServer::Advisories.clear
    expect { MnemodocServer.init_app!("/nonexistent/path/.mnemodoc.yml") }.to raise_error(ArgumentError)
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

  # Discovery finding no project at all is a different situation from a missing
  # file at a path the user named, and says so.
  it "records a no-project advisory when discovery finds nothing" do
    root = File.join(Dir.tempdir, "mnemodoc-adv-#{Random::Secure.hex(6)}")
    begin
      Dir.mkdir_p(root)
      MnemodocServer::Advisories.clear
      MnemodocServer.init_app!("", from: root)
      expect(MnemodocServer.advisories.any?(&.includes?("no MnemoDoc project found"))).to be_true
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
