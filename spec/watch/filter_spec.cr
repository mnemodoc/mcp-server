require "../spec_helper"
require "file_utils"

# Watch::Filter is the only gate between a watch backend and indexing: the
# crawler treats every path it is handed as named explicitly, so a file the
# filter lets through gets indexed — as plain text if nothing else claims it.
Spectator.describe MnemodocServer::Watch::Filter do
  let(tmp_dir) { "/tmp/mnemodoc-filter-#{Random::Secure.hex(4)}" }
  let(docs) { File.join(tmp_dir, "docs") }
  let(named) { File.join(tmp_dir, "notes.custom") }

  let(config) do
    MnemodocServer::Config.from_yaml(<<-YAML)
    paths:
      - #{docs}
      - #{named}
    exclude:
      - "**/drafts/**"
      - "**/templates/*"
    db:
      path: #{File.join(docs, ".mnemodoc", "index.db")}
    YAML
  end

  let(filter) do
    MnemodocServer::Watch::Filter.new(config, MnemodocServer::Indexer::Format::Registry.new(config))
  end

  before_each do
    Dir.mkdir_p(docs)
    File.write(named, "named")
  end
  after_each { FileUtils.rm_rf(tmp_dir) }

  private def event(path : String, kind = MnemodocServer::Watch::Event::Kind::Changed)
    MnemodocServer::Watch::Event.new(path, kind)
  end

  private def deleted(path : String)
    event(path, MnemodocServer::Watch::Event::Kind::Deleted)
  end

  it "accepts a discovered document with an indexable extension" do
    expect(filter.accept?(event(File.join(docs, "guide.md")))).to be_true
  end

  it "rejects a discovered file whose extension no handler claims" do
    expect(filter.accept?(event(File.join(docs, "diagram.png")))).to be_false
  end

  it "accepts a file named explicitly in paths whatever its extension" do
    expect(filter.accept?(event(named))).to be_true
  end

  it "rejects a path under an excluded directory" do
    expect(filter.accept?(event(File.join(docs, "drafts", "wip.md")))).to be_false
  end

  it "rejects the index's own files" do
    expect(filter.accept?(event(File.join(docs, ".mnemodoc", "index.db-wal")))).to be_false
    expect(filter.accept?(event(File.join(docs, ".mnemodoc", "daemon.instance.lock")))).to be_false
  end

  it "rejects a path outside every configured root, including a sibling sharing its prefix" do
    expect(filter.accept?(event(File.join(tmp_dir, "elsewhere.md")))).to be_false
    expect(filter.accept?(event(File.join(tmp_dir, "docs-old", "guide.md")))).to be_false
  end

  it "accepts a deleted directory, which has no extension and can no longer be stat-ed" do
    expect(filter.accept?(deleted(File.join(docs, "chapter")))).to be_true
  end

  it "still rejects a deletion that is excluded, an index artifact or outside the roots" do
    expect(filter.accept?(deleted(File.join(docs, "drafts", "old")))).to be_false
    expect(filter.accept?(deleted(File.join(docs, ".mnemodoc", "index.db-shm")))).to be_false
    expect(filter.accept?(deleted(File.join(tmp_dir, "elsewhere")))).to be_false
  end

  # The crawler globs without DotFiles, so a hidden entry below a root is
  # never indexed at boot; a watcher that let it through made the index flap.
  it "rejects a hidden file or a file under a hidden directory below its root" do
    expect(filter.accept?(event(File.join(docs, ".draft.md")))).to be_false
    expect(filter.accept?(event(File.join(docs, ".hidden", "note.md")))).to be_false
    expect(filter.descend?(File.join(docs, ".git"))).to be_false
  end

  it "accepts documents under a configured root that is itself hidden" do
    hidden_root = File.join(tmp_dir, ".meta")
    Dir.mkdir_p(hidden_root)
    cfg = MnemodocServer::Config.from_yaml("paths:\n  - #{hidden_root}\ndb:\n  path: #{File.join(tmp_dir, "index.db")}")
    hidden_filter = MnemodocServer::Watch::Filter.new(cfg, MnemodocServer::Indexer::Format::Registry.new(cfg))
    expect(hidden_filter.accept?(event(File.join(hidden_root, "guide.md")))).to be_true
  end

  # `paths:` entries are routinely written `doc/`, and File.expand_path keeps
  # the slash: a root spelled that way produced event paths with `//` that
  # matched nothing in the index.
  it "holds its roots without a trailing slash" do
    cfg = MnemodocServer::Config.from_yaml("paths:\n  - #{docs}/\ndb:\n  path: #{File.join(tmp_dir, "index.db")}")
    slashed = MnemodocServer::Watch::Filter.new(cfg, MnemodocServer::Indexer::Format::Registry.new(cfg))
    expect(slashed.roots).to eq([docs])
  end

  it "does not descend into a directory whose whole subtree is excluded" do
    expect(filter.descend?(File.join(docs, "drafts"))).to be_false
    expect(filter.descend?(File.join(docs, "chapter"))).to be_true
  end

  it "descends into a directory whose exclusion covers only its direct children" do
    expect(filter.descend?(File.join(docs, "templates"))).to be_true
  end
end
