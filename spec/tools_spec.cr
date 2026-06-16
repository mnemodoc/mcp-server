require "./spec_helper"
require "file_utils"

# Drives the migrated tools directly: each #call returns an MCP::ToolResult and raises
# MCP::ToolError on failure (instead of the old Hash-with-"error"-key contract).
Spectator.describe "MnemodocServer tools" do
  let(tmp_db) { "/tmp/mnemodoc-tools-#{Random::Secure.hex(4)}.db" }
  let(tmp_dir) { "/tmp/mnemodoc-tools-files-#{Random::Secure.hex(4)}" }
  let(config) { MnemodocServer::Config.from_yaml("db:\n  path: #{tmp_db}\npaths:\n  - #{tmp_dir}") }
  let(store) { MnemodocServer::Store::SQLite.new(tmp_db) }

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each do
    store.close
    File.delete(tmp_db) rescue nil
    FileUtils.rm_rf(tmp_dir)
  end

  describe "status" do
    it "returns server status with chunk count" do
      tool = MnemodocServer::Tools::Status.new(config, store)
      sc = tool.call({} of String => JSON::Any).structured_content
      expect(sc.try(&.["status"].as_s)).to eq("ok")
      expect(sc.try(&.["chunk_count"].as_i)).to eq(0)
      expect(sc.try(&.["version"].as_s)).not_to be_empty
    end
  end

  describe "list_files" do
    it "returns empty list when no files indexed" do
      tool = MnemodocServer::Tools::List.new(store)
      sc = tool.call({} of String => JSON::Any).structured_content
      expect(sc.try(&.["files"].as_a)).to be_empty
    end
  end

  describe "delete_file" do
    it "raises MCP::ToolError for unknown file" do
      tool = MnemodocServer::Tools::Delete.new(store)
      expect { tool.call({"path" => JSON::Any.new("doc/missing.md")}) }.to raise_error(MCP::ToolError)
    end

    it "resolves a suffix path and deletes the file" do
      # Index a file under an absolute path
      abs_path = File.join(tmp_dir, "guide.md")
      File.write(abs_path, "# Guide")
      mtime = File.info(abs_path).modification_time.to_unix
      store.upsert_file(abs_path, mtime: mtime)

      tool = MnemodocServer::Tools::Delete.new(store)
      # Pass only the basename — should resolve via suffix matching
      result = tool.call({"path" => JSON::Any.new("guide.md")})
      expect(result.structured_content.try(&.["deleted"].as_s)).to eq(abs_path)
      expect(store.exists?(abs_path)).to be_false
    end
  end

  describe "delete_file structuredContent" do
    it "returns a ToolResult with the deleted path in structured_content" do
      abs_path = File.join(tmp_dir, "guide.md")
      File.write(abs_path, "# Guide")
      store.upsert_file(abs_path, mtime: File.info(abs_path).modification_time.to_unix)
      built = MnemodocServer::ToolRegistry.build(config, store)
      begin
        result = built[:server].dispatch("delete_file", {"path" => JSON::Any.new("guide.md")})
        expect(result.structured_content.try(&.["deleted"]).try(&.as_s)).to eq(abs_path)
      ensure
        built[:embedder].close
      end
    end
  end

  describe "unknown tool" do
    # The unknown-tool routing previously lived in ToolDispatcher; it now lives in
    # MCP::Server#dispatch and is covered by spec/mcp/server_spec.cr and
    # spec/mcp/handler_spec.cr. We assert the registry-built server raises here.
    it "raises MCP::ToolError when dispatching an unregistered tool" do
      built = MnemodocServer::ToolRegistry.build(config, store)
      embedder = built[:embedder]
      begin
        expect { built[:server].dispatch("unknown_tool", {} of String => JSON::Any) }.to raise_error(MCP::ToolError, /unknown tool/)
      ensure
        embedder.close
      end
    end
  end

  describe "tool annotations" do
    it "annotates read-only and destructive tools" do
      built = MnemodocServer::ToolRegistry.build(config, store)
      begin
        definitions = built[:server].tool_definitions.to_h { |tool| {tool.name, tool.to_definition} }
        expect(definitions["query_documents"]["annotations"]["readOnlyHint"].as_bool).to be_true
        expect(definitions["list_files"]["annotations"]["readOnlyHint"].as_bool).to be_true
        expect(definitions["status"]["annotations"]["readOnlyHint"].as_bool).to be_true
        expect(definitions["delete_file"]["annotations"]["destructiveHint"].as_bool).to be_true
        expect(definitions["ingest_path"]["annotations"]["readOnlyHint"].as_bool).to be_false
      ensure
        built[:embedder].close
      end
    end
  end

  describe "query_documents structuredContent" do
    # query_documents embeds the query through Ollama in the default hybrid mode,
    # so each test points the config at a local mock embeddings server (no real
    # Ollama in CI). Returns a fixed 768-dim vector for any input.
    def with_mock_ollama(&)
      embedding = Array(Float32).new(768, 0.1_f32)
      server = HTTP::Server.new do |ctx|
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        body = ctx.request.body.try(&.gets_to_end) || ""
        count = JSON.parse(body)["input"].as_a.size rescue 1
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      cfg = MnemodocServer::Config.from_yaml(
        "db:\n  path: #{tmp_db}\npaths:\n  - #{tmp_dir}\nollama:\n  host: http://127.0.0.1:#{addr.port}\n  model: test"
      )
      begin
        yield cfg
      ensure
        server.close
      end
    end

    it "returns a ToolResult with structured_content.chunks array" do
      with_mock_ollama do |cfg|
        built = MnemodocServer::ToolRegistry.build(cfg, store)
        begin
          result = built[:server].dispatch("query_documents",
            {"query" => JSON::Any.new("test")})
          # ToolResult carries structured_content
          sc = result.structured_content
          expect(sc).not_to be_nil
          expect(sc.try(&.["chunks"].as_a)).to be_a(Array(JSON::Any))
          expect(sc.try(&.["mode"].as_s)).not_to be_empty
        ensure
          built[:embedder].close
        end
      end
    end

    it "surfaces a model mismatch in structured_content.warnings" do
      store.embedding_model = "some-old-model"
      with_mock_ollama do |cfg|
        built = MnemodocServer::ToolRegistry.build(cfg, store)
        begin
          result = built[:server].dispatch("query_documents", {"query" => JSON::Any.new("x")})
          warnings = result.structured_content.try(&.["warnings"]).try(&.as_a).try(&.map(&.as_s)) || [] of String
          expect(warnings.any?(&.includes?("re-index required"))).to be_true
        ensure
          built[:embedder].close
        end
      end
    end
  end

  describe "list_files structuredContent" do
    it "returns a ToolResult with structured_content.files array" do
      built = MnemodocServer::ToolRegistry.build(config, store)
      begin
        result = built[:server].dispatch("list_files", {} of String => JSON::Any)
        sc = result.structured_content
        expect(sc).not_to be_nil
        expect(sc.try(&.["files"].as_a)).to be_a(Array(JSON::Any))
      ensure
        built[:embedder].close
      end
    end
  end

  describe "status structuredContent" do
    it "returns a ToolResult with structured_content.status" do
      built = MnemodocServer::ToolRegistry.build(config, store)
      begin
        result = built[:server].dispatch("status", {} of String => JSON::Any)
        sc = result.structured_content
        expect(sc).not_to be_nil
        expect(sc.try(&.["status"].as_s)).to eq("ok")
      ensure
        built[:embedder].close
      end
    end
  end

  describe "get_project_context" do
    let(roles_dir) { File.join(tmp_dir, "roles") }
    before_each { Dir.mkdir_p(roles_dir) }

    it "returns the role whose file glob matches, with its content" do
      File.write(File.join(roles_dir, "crystal.md"), "# Crystal role\nBe a Crystal expert.")
      cfg = MnemodocServer::Config.from_yaml(<<-YAML)
      db:
        path: #{tmp_db}
      paths:
        - #{tmp_dir}
      context:
        roles:
          - file: #{roles_dir}/crystal.md
            description: "Crystal expert"
            when_files: ["**/*.cr"]
            when_task: ["debug"]
      YAML
      built = MnemodocServer::ToolRegistry.build(cfg, store)
      begin
        result = built[:server].dispatch("get_project_context",
          {"files" => JSON::Any.new([JSON::Any.new("src/foo.cr")]),
           "task"  => JSON::Any.new("debug")})
        sc = result.structured_content || fail("structured_content was nil")
        expect(sc["role"].as_s).to eq("crystal")
        expect(sc["reason"].as_s).not_to be_empty
        expect(sc["candidates"].as_a.first["name"].as_s).to eq("crystal")
        # Text block carries the role markdown
        expect(result.content.first.to_json_object["text"].as_s).to contain("Crystal expert")
      ensure
        built[:embedder].close
      end
    end

    it "raises MCP::ToolError when no roles are configured" do
      built = MnemodocServer::ToolRegistry.build(config, store)
      begin
        expect { built[:server].dispatch("get_project_context", {"query" => JSON::Any.new("anything")}) }
          .to raise_error(MCP::ToolError, /no roles configured/)
      ensure
        built[:embedder].close
      end
    end

    it "raises MCP::ToolError when the selected role file is missing" do
      cfg = MnemodocServer::Config.from_yaml(<<-YAML)
      db:
        path: #{tmp_db}
      paths:
        - #{tmp_dir}
      context:
        roles:
          - file: #{tmp_dir}/roles/ghost.md
            when_files: ["**/*.cr"]
      YAML
      built = MnemodocServer::ToolRegistry.build(cfg, store)
      begin
        expect { built[:server].dispatch("get_project_context",
          {"files" => JSON::Any.new([JSON::Any.new("src/foo.cr")])}) }
          .to raise_error(MCP::ToolError, /role file not found/)
      ensure
        built[:embedder].close
      end
    end
  end

  describe "ingest_path structuredContent" do
    it "returns a ToolResult with indexed/skipped/pruned in structured_content" do
      built = MnemodocServer::ToolRegistry.build(config, store)
      begin
        result = built[:server].dispatch("ingest_path", {"path" => JSON::Any.new(tmp_dir)})
        sc = result.structured_content || fail("structured_content was nil")
        expect(sc["indexed"].as_i).to be >= 0
        expect(sc["pruned"].as_i).to be >= 0
      ensure
        built[:embedder].close
      end
    end

    it "indexes only the named file, not its whole parent directory" do
      # Two markdown files share a directory; ingesting one must index only it.
      embedding = Array(Float32).new(768, 0.1_f32)

      server = HTTP::Server.new do |ctx|
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        body = ctx.request.body.try(&.gets_to_end) || ""
        count = JSON.parse(body)["input"].as_a.size rescue 1
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      cfg = MnemodocServer::Config.from_yaml(
        "db:\n  path: #{tmp_db}\npaths:\n  - #{tmp_dir}\nollama:\n  host: http://127.0.0.1:#{addr.port}\n  model: test"
      )
      target_path = File.join(tmp_dir, "target.md")
      sibling_path = File.join(tmp_dir, "sibling.md")
      File.write(target_path, "## Target\n\ncontent")
      File.write(sibling_path, "## Sibling\n\ncontent")

      ingest = MnemodocServer::Tools::Ingest.new(cfg, store, MnemodocServer::Indexer::Embedder.new(cfg.ollama))
      ingest.call({"path" => JSON::Any.new(target_path)})
      server.close

      indexed_paths = store.list_files.map { |file_info| File.basename(file_info.path) }
      expect(indexed_paths).to contain("target.md")
      expect(indexed_paths).not_to contain("sibling.md")
    end
  end

  describe "advisory injection" do
    after_each { MnemodocServer::Advisories.clear }

    it "injects active advisories into every tool's structured_content.warnings" do
      MnemodocServer::Advisories.clear
      MnemodocServer::Advisories.add("test advisory")
      built = MnemodocServer::ToolRegistry.build(config, store)
      begin
        ["status", "list_files"].each do |name|
          result = built[:server].dispatch(name, {} of String => JSON::Any)
          warnings = result.structured_content.try(&.["warnings"]).try(&.as_a).try(&.map(&.as_s)) || [] of String
          expect(warnings).to contain("test advisory")
        end
      ensure
        built[:embedder].close
      end
    end

    it "adds no warnings key when there are no advisories and no per-call warning" do
      MnemodocServer::Advisories.clear
      built = MnemodocServer::ToolRegistry.build(config, store)
      begin
        result = built[:server].dispatch("status", {} of String => JSON::Any)
        expect(result.structured_content.try(&.as_h).try(&.has_key?("warnings"))).to be_falsey
      ensure
        built[:embedder].close
      end
    end
  end

  describe "ingest_path streaming" do
    it "sends notifications/progress on the channel for each indexed file" do
      embedding = Array(Float32).new(768, 0.1_f32)

      server = HTTP::Server.new do |ctx|
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        body = ctx.request.body.try(&.gets_to_end) || ""
        count = JSON.parse(body)["input"].as_a.size rescue 1
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      cfg = MnemodocServer::Config.from_yaml(
        "db:\n  path: #{tmp_db}\npaths:\n  - #{tmp_dir}\nollama:\n  host: http://127.0.0.1:#{addr.port}\n  model: test"
      )
      File.write(File.join(tmp_dir, "x.md"), "## Section\ncontent")
      File.write(File.join(tmp_dir, "y.md"), "## Section\ncontent")

      channel = Channel(JSON::Any).new(32)
      progress = MCP::Progress.new(channel, JSON::Any.new("tok"))

      ingest = MnemodocServer::Tools::Ingest.new(cfg, store, MnemodocServer::Indexer::Embedder.new(cfg.ollama))
      ingest.call({"path" => JSON::Any.new(tmp_dir)}, progress)
      channel.close

      server.close

      events = [] of JSON::Any
      loop do
        ev = channel.receive?
        break if ev.nil?
        events << ev
      end

      progress_events = events.select { |e| e["method"]?.try(&.as_s?) == "notifications/progress" }
      expect(progress_events.size).to eq(2)
      expect(progress_events.all? { |e| e["params"]["progressToken"].as_s == "tok" }).to be_true
      expect(progress_events.map(&.["params"]["total"].as_i).uniq!).to eq([2])
    end

    it "works without a progress reporter (no progress channel)" do
      embedding = Array(Float32).new(768, 0.1_f32)

      server = HTTP::Server.new do |ctx|
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        body = ctx.request.body.try(&.gets_to_end) || ""
        count = JSON.parse(body)["input"].as_a.size rescue 1
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      end
      addr = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      Fiber.yield

      cfg = MnemodocServer::Config.from_yaml(
        "db:\n  path: #{tmp_db}\npaths:\n  - #{tmp_dir}\nollama:\n  host: http://127.0.0.1:#{addr.port}\n  model: test"
      )
      File.write(File.join(tmp_dir, "z.md"), "## Section\ncontent")

      ingest = MnemodocServer::Tools::Ingest.new(cfg, store, MnemodocServer::Indexer::Embedder.new(cfg.ollama))
      tool_result = ingest.call({"path" => JSON::Any.new(tmp_dir)}, nil)

      server.close

      expect(tool_result.structured_content.try(&.["indexed"].as_i)).to eq(1)
    end
  end
end
