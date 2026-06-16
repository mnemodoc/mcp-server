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
end
