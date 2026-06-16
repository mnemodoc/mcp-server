require "./spec_helper"
require "file_utils"

Spectator.describe MnemodocServer::Roles::Role do
  let(tmp_dir) { "/tmp/mnemodoc-role-#{Random::Secure.hex(4)}" }
  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  private def role_for(file : String, resolved : String) : MnemodocServer::Roles::Role
    MnemodocServer::Roles::Role.new(MnemodocServer::RoleConfig.new(file: file), resolved)
  end

  it "derives the name from the file basename without extension" do
    role = role_for(".claude/roles/crystal.md", "/abs/.claude/roles/crystal.md")
    expect(role.name).to eq("crystal")
  end

  it "reads and caches the markdown content" do
    path = File.join(tmp_dir, "r.md")
    File.write(path, "# Role\nBe an expert.")
    role = role_for("roles/r.md", path)
    expect(role.content).to contain("Be an expert.")
  end

  it "reports file_exists? false for a missing file" do
    role = role_for("roles/missing.md", File.join(tmp_dir, "missing.md"))
    expect(role.file_exists?).to be_false
  end

  it "raises when reading a missing file" do
    role = role_for("roles/missing.md", File.join(tmp_dir, "missing.md"))
    expect { role.content }.to raise_error(File::Error)
  end
end
