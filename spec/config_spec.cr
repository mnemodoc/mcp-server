require "./spec_helper"

Spectator.describe MnemodocServer::Config do
  describe ".from_yaml" do
    it "applies defaults when YAML is empty" do
      config = MnemodocServer::Config.from_yaml("")
      expect(config.paths).to eq(["doc/claude/", "app/"])
      expect(config.ollama.host).to eq("http://localhost:11434")
      expect(config.ollama.model).to eq("nomic-embed-text")
      expect(config.ollama.batch_size).to eq(10)
      expect(config.search.top_k).to eq(5)
      expect(config.search.mode).to eq("hybrid")
      expect(config.search.recency_days).to eq(7)
      expect(config.search.recency_boost).to eq(0.1)
      expect(config.server.sse_port).to eq(8765)
      expect(config.server.log_file).to eq("stderr")
      expect(config.server.log_level).to eq("info")
      expect(config.server.daemon?).to be_true
      expect(config.server.daemon_idle_timeout).to eq(600)
      expect(config.db.path).to eq("")
      expect(config.db_path).to contain(Path.home.to_s)
      expect(config.db_path).to contain("mnemodoc-server")
      expect(config.db_path).to end_with("index.db")
    end

    it "overrides specified fields" do
      config = MnemodocServer::Config.from_yaml("search:\n  top_k: 10\n  mode: semantic")
      expect(config.search.top_k).to eq(10)
      expect(config.search.mode).to eq("semantic")
      expect(config.search.recency_days).to eq(7)
    end

    it "parses daemon toggle and idle timeout from YAML" do
      config = MnemodocServer::Config.from_yaml("server:\n  daemon: false\n  daemon_idle_timeout: 120")
      expect(config.server.daemon?).to be_false
      expect(config.server.daemon_idle_timeout).to eq(120)
    end
  end

  describe "#apply_env!" do
    it "overrides ollama host via env" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_OLLAMA_HOST" => "http://localhost:12345"})
      expect(config.ollama.host).to eq("http://localhost:12345")
    end

    it "overrides db path via env" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_DB_PATH" => "/tmp/test.db"})
      expect(config.db.path).to eq("/tmp/test.db")
    end

    it "overrides ollama timeout via env" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_OLLAMA_TIMEOUT" => "60"})
      expect(config.ollama.timeout).to eq(60)
    end

    it "overrides search recency_days via env" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_SEARCH_RECENCY_DAYS" => "14"})
      expect(config.search.recency_days).to eq(14)
    end

    it "overrides search recency_boost via env" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_SEARCH_RECENCY_BOOST" => "0.2"})
      expect(config.search.recency_boost).to eq(0.2)
    end

    it "overrides search keyword_weight via env" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_SEARCH_KEYWORD_WEIGHT" => "0.5"})
      expect(config.search.keyword_weight).to eq(0.5)
    end

    it "overrides daemon and idle timeout via env" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_SERVER_DAEMON" => "false", "MNEMODOC_SERVER_IDLE_TIMEOUT" => "30"})
      expect(config.server.daemon?).to be_false
      expect(config.server.daemon_idle_timeout).to eq(30)
    end
  end

  describe "index config" do
    it "has a default keyword_weight below 1.0" do
      config = MnemodocServer::Config.from_yaml("")
      expect(config.search.keyword_weight).to eq(0.3)
    end

    it "defaults recency_boost to a 0.1 fraction" do
      config = MnemodocServer::Config.from_yaml("")
      expect(config.search.recency_boost).to eq(0.1)
    end

    it "has default concurrency of 4" do
      config = MnemodocServer::Config.from_yaml("")
      expect(config.index.concurrency).to eq(4)
    end

    it "overrides concurrency via YAML" do
      config = MnemodocServer::Config.from_yaml("index:\n  concurrency: 8")
      expect(config.index.concurrency).to eq(8)
    end

    it "applies MNEMODOC_INDEX_CONCURRENCY env var" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_INDEX_CONCURRENCY" => "6"})
      expect(config.index.concurrency).to eq(6)
    end

    it "defaults index.pdf to false and parses it from YAML" do
      config = MnemodocServer::Config.from_yaml("index:\n  pdf: true")
      expect(config.index.pdf?).to be_true
      default = MnemodocServer::Config.from_yaml("paths:\n  - x/")
      expect(default.index.pdf?).to be_false
    end

    it "overrides index.pdf from MNEMODOC_INDEX_PDF" do
      config = MnemodocServer::Config.from_yaml("paths:\n  - x/")
      config.apply_env!({"MNEMODOC_INDEX_PDF" => "true"})
      expect(config.index.pdf?).to be_true
    end
  end

  describe "chunking config" do
    it "defaults both chunking options to false" do
      config = MnemodocServer::Config.from_yaml("")
      expect(config.chunking.strip_link_only_lines?).to be_false
      expect(config.chunking.merge_preamble_into_first_section?).to be_false
    end

    it "parses the chunking options from YAML" do
      config = MnemodocServer::Config.from_yaml("chunking:\n  strip_link_only_lines: true\n  merge_preamble_into_first_section: true")
      expect(config.chunking.strip_link_only_lines?).to be_true
      expect(config.chunking.merge_preamble_into_first_section?).to be_true
    end

    it "overrides the chunking options via env vars" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({
        "MNEMODOC_CHUNKING_STRIP_LINK_ONLY_LINES" => "true",
        "MNEMODOC_CHUNKING_MERGE_PREAMBLE"        => "true",
      })
      expect(config.chunking.strip_link_only_lines?).to be_true
      expect(config.chunking.merge_preamble_into_first_section?).to be_true
    end
  end

  describe "exclude config" do
    it "defaults to an empty exclude list" do
      config = MnemodocServer::Config.from_yaml("")
      expect(config.exclude).to eq([] of String)
    end

    it "parses exclude patterns from YAML" do
      config = MnemodocServer::Config.from_yaml("exclude:\n  - \"**/templates/**\"")
      expect(config.exclude).to eq(["**/templates/**"])
    end

    it "applies MNEMODOC_EXCLUDE env var as comma-separated patterns" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_EXCLUDE" => "a/**,b/**"})
      expect(config.exclude).to eq(["a/**", "b/**"])
    end
  end

  describe "#resolved_paths" do
    it "expands relative paths against source_dir when set" do
      config = MnemodocServer::Config.from_yaml("paths:\n  - doc\n  - notes")
      config.source_dir = "/tmp/projX"
      expect(config.resolved_paths).to eq(["/tmp/projX/doc", "/tmp/projX/notes"])
    end

    it "keeps absolute paths unchanged" do
      config = MnemodocServer::Config.from_yaml("paths:\n  - /abs/path\n  - rel")
      config.source_dir = "/tmp/projX"
      expect(config.resolved_paths).to eq(["/abs/path", "/tmp/projX/rel"])
    end

    it "falls back to Dir.current when source_dir is nil" do
      config = MnemodocServer::Config.from_yaml("paths:\n  - doc/")
      config.source_dir = nil
      expect(config.resolved_paths.first).to eq(File.expand_path("doc/", Dir.current))
    end
  end

  describe "#db_path with source_dir" do
    it "includes a hash of source_dir to avoid basename collisions" do
      config_a = MnemodocServer::Config.from_yaml("")
      config_a.source_dir = "/home/user/work/myproject"

      config_b = MnemodocServer::Config.from_yaml("")
      config_b.source_dir = "/home/other/team/myproject"

      # Same basename "myproject" but different absolute paths must produce different db paths
      expect(config_a.db_path).not_to eq(config_b.db_path)
    end

    it "still ends with index.db and contains mnemodoc-server" do
      config = MnemodocServer::Config.from_yaml("")
      config.source_dir = "/tmp/some-project"
      expect(config.db_path).to contain("mnemodoc-server")
      expect(config.db_path).to end_with("index.db")
    end
  end

  describe "#daemon_socket_path and #daemon_lock_path" do
    it "places daemon.sock beside the index DB" do
      config = MnemodocServer::Config.from_yaml("db:\n  path: /tmp/x/index.db")
      expect(config.daemon_socket_path).to eq("/tmp/x/daemon.sock")
    end

    it "places daemon.lock beside the index DB" do
      config = MnemodocServer::Config.from_yaml("db:\n  path: /tmp/x/index.db")
      expect(config.daemon_lock_path).to eq("/tmp/x/daemon.lock")
    end
  end

  describe "#log_file_path" do
    it "keeps stream keywords as-is" do
      config = MnemodocServer::Config.from_yaml("server:\n  log_file: stderr")
      expect(config.log_file_path).to eq("stderr")
    end

    it "keeps stdout keyword as-is" do
      config = MnemodocServer::Config.from_yaml("server:\n  log_file: stdout")
      expect(config.log_file_path).to eq("stdout")
    end

    it "keeps empty string as-is" do
      config = MnemodocServer::Config.from_yaml("")
      expect(config.log_file_path).to eq("stderr")
    end

    it "resolves a relative log_file against source_dir" do
      config = MnemodocServer::Config.from_yaml("server:\n  log_file: log/app.log")
      config.source_dir = "/tmp/projX"
      expect(config.log_file_path).to eq("/tmp/projX/log/app.log")
    end

    it "keeps an absolute log_file unchanged" do
      config = MnemodocServer::Config.from_yaml("server:\n  log_file: /var/log/app.log")
      config.source_dir = "/tmp/projX"
      expect(config.log_file_path).to eq("/var/log/app.log")
    end
  end

  describe "context config" do
    it "defaults to no roles and no default" do
      config = MnemodocServer::Config.from_yaml("")
      expect(config.context.roles).to be_empty
      expect(config.context.default).to be_nil
    end

    it "parses roles with triggers from YAML" do
      yaml = <<-YAML
      context:
        default: .claude/roles/generalist.md
        roles:
          - file: .claude/roles/crystal.md
            description: "Crystal expert"
            when_files: ["**/*.cr"]
            when_task: ["debug", "spec"]
            when_query: ["crystal", "shard"]
      YAML
      config = MnemodocServer::Config.from_yaml(yaml)
      expect(config.context.default).to eq(".claude/roles/generalist.md")
      expect(config.context.roles.size).to eq(1)
      role = config.context.roles.first
      expect(role.file).to eq(".claude/roles/crystal.md")
      expect(role.description).to eq("Crystal expert")
      expect(role.when_files).to eq(["**/*.cr"])
      expect(role.when_task).to eq(["debug", "spec"])
      expect(role.when_query).to eq(["crystal", "shard"])
    end

    it "resolves a relative context path against source_dir" do
      config = MnemodocServer::Config.from_yaml("")
      config.source_dir = "/tmp/projX"
      expect(config.resolve_context_path(".claude/roles/x.md")).to eq("/tmp/projX/.claude/roles/x.md")
    end

    it "keeps an absolute context path unchanged" do
      config = MnemodocServer::Config.from_yaml("")
      config.source_dir = "/tmp/projX"
      expect(config.resolve_context_path("/abs/x.md")).to eq("/abs/x.md")
    end
  end

  describe "#validate!" do
    it "passes on a default config" do
      expect { MnemodocServer::Config.from_yaml("").validate! }.not_to raise_error
    end

    it "raises when paths is empty" do
      config = MnemodocServer::Config.from_yaml("paths: []")
      expect { config.validate! }.to raise_error(ArgumentError, /paths/)
    end

    it "raises on invalid search mode" do
      config = MnemodocServer::Config.from_yaml("search:\n  mode: invalid")
      expect { config.validate! }.to raise_error(ArgumentError, /mode/)
    end

    it "raises on invalid sse_port" do
      config = MnemodocServer::Config.from_yaml("server:\n  sse_port: 0")
      expect { config.validate! }.to raise_error(ArgumentError, /sse_port/)
    end

    it "collects multiple errors" do
      config = MnemodocServer::Config.from_yaml("paths: []\nserver:\n  sse_port: 0")
      expect { config.validate! }.to raise_error(ArgumentError, /paths.*sse_port|sse_port.*paths/)
    end

    it "raises when index.concurrency is less than 1" do
      config = MnemodocServer::Config.from_yaml("index:\n  concurrency: 0")
      expect { config.validate! }.to raise_error(ArgumentError, /concurrency/)
    end

    it "raises when daemon_idle_timeout is less than 1" do
      config = MnemodocServer::Config.from_yaml("server:\n  daemon_idle_timeout: 0")
      expect { config.validate! }.to raise_error(ArgumentError, /daemon_idle_timeout/)
    end

    it "raises on an unknown search.backend" do
      config = MnemodocServer::Config.from_yaml("search:\n  backend: pinecone")
      expect { config.validate! }.to raise_error(ArgumentError, /backend/)
    end

    it "raises when backend is qdrant but qdrant.url is empty" do
      config = MnemodocServer::Config.from_yaml("search:\n  backend: qdrant")
      expect { config.validate! }.to raise_error(ArgumentError, /qdrant.url/)
    end
  end

  describe "qdrant backend config" do
    it "defaults the backend to vec0" do
      expect(MnemodocServer::Config.from_yaml("").search.backend).to eq("vec0")
    end

    it "parses the backend selector and qdrant block" do
      config = MnemodocServer::Config.from_yaml(
        "search:\n  backend: qdrant\nqdrant:\n  url: http://q:6333\n  collection: docs")
      expect(config.search.backend).to eq("qdrant")
      expect(config.qdrant.url).to eq("http://q:6333")
      expect(config.qdrant_collection).to eq("docs")
    end

    it "overrides backend and qdrant url from the environment" do
      config = MnemodocServer::Config.from_yaml("")
      config.apply_env!({"MNEMODOC_SEARCH_BACKEND" => "qdrant", "MNEMODOC_QDRANT_URL" => "http://env:6333"})
      expect(config.search.backend).to eq("qdrant")
      expect(config.qdrant.url).to eq("http://env:6333")
    end

    it "derives a non-empty default collection from the project when unset" do
      expect(MnemodocServer::Config.from_yaml("").qdrant_collection).not_to be_empty
    end
  end
end
