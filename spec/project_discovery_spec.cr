require "./spec_helper"
require "file_utils"

# The `.mnemodoc/` directory — not the YAML file — is what marks a directory as
# a MnemoDoc project. A single globally-registered server lands in an arbitrary
# working directory, so it must walk up to find the project it belongs to, and
# must stay inert in a directory that was never initialised: no index directory
# created, nothing indexed.
Spectator.describe "project discovery" do
  # `init_app!` writes process-wide state, so an example that deliberately
  # resolves to "no project" would otherwise hand the uninitialised
  # short-circuit to every spec running after it. A throwaway project restores
  # the flag through the normal path rather than by reaching into the module.
  after_each { restore_project_state }

  # Builds `<tmp>/<marker dirs each get a .mnemodoc/>` and returns the root.
  private def project(nested : String, *, marker_at : Array(String) = ["."], config : String? = nil)
    root = File.join(Dir.tempdir, "mnemodoc-discover-#{Random::Secure.hex(6)}")
    Dir.mkdir_p(File.join(root, nested))
    marker_at.each { |rel| Dir.mkdir_p(File.join(root, rel, ".mnemodoc")) }
    config.try { |body| File.write(File.join(root, ".mnemodoc.yml"), body) }
    root
  end

  describe ".discover_project" do
    it "walks up to the nearest ancestor holding a .mnemodoc directory" do
      root = project("app/models")
      begin
        found = MnemodocServer.discover_project(File.join(root, "app/models"))
        expect(found).to eq(File.realpath(root))
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "returns nil when no ancestor holds one" do
      root = File.join(Dir.tempdir, "mnemodoc-bare-#{Random::Secure.hex(6)}")
      begin
        Dir.mkdir_p(File.join(root, "deep/nested"))
        expect(MnemodocServer.discover_project(File.join(root, "deep/nested"))).to be_nil
      ensure
        FileUtils.rm_rf(root)
      end
    end

    # A nested project inside an outer one belongs to itself.
    it "prefers the nearest marker over a further ancestor" do
      root = project("packages/inner/src", marker_at: [".", "packages/inner"])
      begin
        found = MnemodocServer.discover_project(File.join(root, "packages/inner/src"))
        expect(found).to eq(File.realpath(File.join(root, "packages/inner")))
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "finds a marker sitting in the starting directory itself" do
      root = project(".")
      begin
        expect(MnemodocServer.discover_project(root)).to eq(File.realpath(root))
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  describe "bootstrap" do
    it "anchors the config on the discovered project, not the working directory" do
      root = project("app/models", config: "paths:\n  - docs/\n")
      begin
        MnemodocServer.init_app!("", from: File.join(root, "app/models"))
        expect(MnemodocServer.project_initialized?).to be_true
        expect(MnemodocServer.config.source_dir).to eq(File.realpath(root))
        expect(MnemodocServer.config.paths).to eq(["docs/"])
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "reports an uninitialised project instead of failing validation" do
      root = File.join(Dir.tempdir, "mnemodoc-uninit-#{Random::Secure.hex(6)}")
      begin
        Dir.mkdir_p(root)
        MnemodocServer.init_app!("", from: root)
        expect(MnemodocServer.project_initialized?).to be_false
      ensure
        FileUtils.rm_rf(root)
      end
    end

    # An explicit --config is an unambiguous statement of which project is meant;
    # it wins over whatever the working directory would have discovered.
    it "lets an explicit config path short-circuit discovery" do
      root = project("app", config: "paths:\n  - docs/\n")
      other = project(".", config: "paths:\n  - elsewhere/\n")
      begin
        MnemodocServer.init_app!(File.join(other, ".mnemodoc.yml"), from: File.join(root, "app"))
        expect(MnemodocServer.config.paths).to eq(["elsewhere/"])
        expect(MnemodocServer.project_initialized?).to be_true
      ensure
        FileUtils.rm_rf(root)
        FileUtils.rm_rf(other)
      end
    end

    # The whole point of the marker: a global server must not sprout an index
    # directory in every project a session happens to open.
    it "creates no index directory when the project is uninitialised" do
      root = File.join(Dir.tempdir, "mnemodoc-nostore-#{Random::Secure.hex(6)}")
      begin
        Dir.mkdir_p(root)
        MnemodocServer.init_app!("", from: root)
        store = MnemodocServer.open_store(MnemodocServer.config)
        store.close
        expect(Dir.exists?(File.join(root, ".mnemodoc"))).to be_false
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
