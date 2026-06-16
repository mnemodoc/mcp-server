require "./spec_helper"
require "file_utils"

# End-to-end integration spec: drives the full pipeline through an MCP::Server
# built by ToolRegistry, a temp SQLite database, a temp docs directory, and a
# fake Ollama HTTP server. No real Ollama required — fully deterministic and
# CI-safe. Tool calls go through server.dispatch which returns a MCP::ToolResult;
# dispatch_json extracts the JSON from the first text content block. Error paths
# raise MCP::ToolError unchanged.
Spectator.describe "end-to-end" do
  # Dispatches a tool and parses the JSON from the result.
  # When a ToolResult carries no content blocks (structured_content auto-fallback),
  # the structured_content is serialised to JSON and parsed directly.
  private def dispatch_json(server, name, args)
    tool_result = server.dispatch(name, args)
    if tool_result.content.empty?
      sc = tool_result.structured_content
      raise "dispatch_json: no content and no structured_content" unless sc
      JSON.parse(sc.to_json)
    else
      JSON.parse(tool_result.content.first.to_json_object["text"].as_s)
    end
  end

  # 768-float unit vector used as a fixed embedding for every /api/embeddings request.
  EMBEDDING_768 = begin
    raw = Array(Float32).new(768, 0.1_f32)
    norm = Math.sqrt(raw.sum { |value| value.to_f64 * value.to_f64 })
    raw.map { |value| (value / norm).to_f32 }
  end

  # Starts a minimal HTTP server on a random loopback port that returns a fixed
  # 768-float embedding per input via POST to /api/embed.
  # Yields the bound port, then closes the server in the ensure block.
  private def with_fake_ollama(&)
    server = HTTP::Server.new do |ctx|
      ctx.response.status_code = 200
      ctx.response.content_type = "application/json"
      body = ctx.request.body.try(&.gets_to_end) || ""
      count = JSON.parse(body)["input"].as_a.size rescue 1
      ctx.response.print({"embeddings" => Array.new(count, EMBEDDING_768)}.to_json)
    end
    addr = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    begin
      yield addr.port
    ensure
      server.close
    end
  end

  # Sets up a fresh tmp directory, tmp db, fake Ollama server, and an MCP::Server
  # built via ToolRegistry. Yields {server, tmp_dir, store} and drains the shared
  # embedder + cleans up in ensure regardless of errors.
  # Accepts an optional exclude list for the config.
  private def with_server(exclude : Array(String) = [] of String, &)
    tag = Random::Secure.hex(6)
    tmp_dir = "/tmp/mcp-e2e-dir-#{tag}"
    tmp_db = "/tmp/mcp-e2e-db-#{tag}.db"

    Dir.mkdir_p(tmp_dir)
    store = MnemodocServer::Store::SQLite.new(tmp_db)

    with_fake_ollama do |port|
      exclude_lines = exclude.map { |pattern| "  - \"#{pattern}\"" }.join("\n")
      exclude_section = exclude.empty? ? "exclude: []" : "exclude:\n#{exclude_lines}"
      config_yaml = <<-YAML
        paths:
          - #{tmp_dir}
        #{exclude_section}
        db:
          path: #{tmp_db}
        ollama:
          host: http://127.0.0.1:#{port}
          model: nomic-embed-text
          batch_size: 10
        YAML
      config = MnemodocServer::Config.from_yaml(config_yaml)
      built = MnemodocServer::ToolRegistry.build(config, store)
      begin
        yield built[:server], tmp_dir, store
      ensure
        built[:embedder].close
      end
    end
  ensure
    store.try(&.close)
    File.delete(tmp_db) rescue nil if tmp_db
    FileUtils.rm_rf(tmp_dir) if tmp_dir
  end

  describe "ingest then query finds content" do
    it "returns the ingested file when querying for a distinctive term" do
      with_server do |server, tmp_dir|
        # Write a file containing a unique term unlikely to appear elsewhere
        File.write(
          File.join(tmp_dir, "guide.md"),
          "## Zorblax\n\nThe zorblax protocol configures everything.\n"
        )

        ingest_result = dispatch_json(server, "ingest_path", {"path" => JSON::Any.new(tmp_dir)})
        expect(ingest_result["indexed"].as_i).to be >= 1

        # Keyword mode avoids an Ollama round-trip for the query embedding
        query_result = dispatch_json(server, "query_documents", {
          "query" => JSON::Any.new("zorblax"),
          "mode"  => JSON::Any.new("keyword"),
        })
        files_found = query_result["chunks"].as_a.map(&.["file"].as_s)
        expect(files_found.any?(&.ends_with?("guide.md"))).to be_true
      end
    end
  end

  describe "exclude is honored on ingest" do
    it "indexes real.md but not templates/dup.md" do
      with_server(exclude: ["**/templates/**"]) do |server, tmp_dir|
        Dir.mkdir_p(File.join(tmp_dir, "templates"))
        File.write(File.join(tmp_dir, "real.md"), "## Real\n\nReal content.\n")
        File.write(File.join(tmp_dir, "templates", "dup.md"), "## Dup\n\nDuplicate content.\n")

        server.dispatch("ingest_path", {"path" => JSON::Any.new(tmp_dir)})

        list_result = dispatch_json(server, "list_files", {} of String => JSON::Any)
        paths = list_result["files"].as_a.map(&.["path"].as_s)

        expect(paths.any?(&.ends_with?("real.md"))).to be_true
        expect(paths.any?(&.ends_with?("templates/dup.md"))).to be_false
      end
    end
  end

  describe "delete by relative path (suffix resolution)" do
    it "removes the file via suffix match and raises for unknown paths" do
      with_server do |server, tmp_dir, store|
        abs_path = File.join(tmp_dir, "guide.md")
        File.write(abs_path, "## Guide\n\nSome guide content.\n")

        server.dispatch("ingest_path", {"path" => JSON::Any.new(tmp_dir)})

        # Confirm the file is present before deletion
        list_before = dispatch_json(server, "list_files", {} of String => JSON::Any)
        paths_before = list_before["files"].as_a.map(&.["path"].as_s)
        expect(paths_before.any?(&.ends_with?("guide.md"))).to be_true

        count_before = store.chunk_count

        # Pass only the basename — suffix resolution must find the absolute path
        delete_result = dispatch_json(server, "delete_file", {"path" => JSON::Any.new("guide.md")})
        expect(delete_result["deleted"].as_s).to eq(abs_path)

        # The file must no longer appear in list_files
        list_after = dispatch_json(server, "list_files", {} of String => JSON::Any)
        paths_after = list_after["files"].as_a.map(&.["path"].as_s)
        expect(paths_after.any?(&.ends_with?("guide.md"))).to be_false

        # Chunk count must have decreased
        expect(store.chunk_count).to be < count_before

        # Deleting a truly unknown path must raise MCP::ToolError
        expect { server.dispatch("delete_file", {"path" => JSON::Any.new("totally_unknown_file.md")}) }
          .to raise_error(MCP::ToolError)
      end
    end
  end

  describe "reindex prunes files removed from disk" do
    it "removes the deleted file from the index on the next ingest" do
      with_server do |server, tmp_dir|
        path_a = File.join(tmp_dir, "a.md")
        path_b = File.join(tmp_dir, "b.md")
        File.write(path_a, "## Alpha\n\nContent A.\n")
        File.write(path_b, "## Beta\n\nContent B.\n")

        first_ingest = dispatch_json(server, "ingest_path", {"path" => JSON::Any.new(tmp_dir)})
        expect(first_ingest["indexed"].as_i).to eq(2)

        # Remove b.md from disk so the crawler no longer sees it
        File.delete(path_b)

        second_ingest = dispatch_json(server, "ingest_path", {"path" => JSON::Any.new(tmp_dir)})
        expect(second_ingest["pruned"].as_i).to be >= 1

        list_result = dispatch_json(server, "list_files", {} of String => JSON::Any)
        remaining = list_result["files"].as_a.map(&.["path"].as_s)
        expect(remaining.any?(&.ends_with?("a.md"))).to be_true
        expect(remaining.any?(&.ends_with?("b.md"))).to be_false
      end
    end
  end

  describe "reindex prunes newly-excluded files" do
    it "removes templates/dup.md when exclude is added on the second ingest" do
      tag = Random::Secure.hex(6)
      tmp_dir : String = "/tmp/mcp-e2e-dir-#{tag}"
      tmp_db : String = "/tmp/mcp-e2e-db-#{tag}.db"
      store : MnemodocServer::Store::SQLite? = nil

      begin
        Dir.mkdir_p(File.join(tmp_dir, "templates"))
        store = MnemodocServer::Store::SQLite.new(tmp_db)

        with_fake_ollama do |port|
          # First pass: no exclude — both files get indexed
          config_without_exclude = MnemodocServer::Config.from_yaml(<<-YAML)
            paths:
              - #{tmp_dir}
            exclude: []
            db:
              path: #{tmp_db}
            ollama:
              host: http://127.0.0.1:#{port}
            YAML
          built1 = MnemodocServer::ToolRegistry.build(config_without_exclude, store)
          server1 = built1[:server]

          File.write(File.join(tmp_dir, "real.md"), "## Real\n\nReal content.\n")
          File.write(File.join(tmp_dir, "templates", "dup.md"), "## Dup\n\nDuplicate content.\n")

          first_ingest = dispatch_json(server1, "ingest_path", {"path" => JSON::Any.new(tmp_dir)})
          expect(first_ingest["indexed"].as_i).to eq(2)
          built1[:embedder].close

          # Second pass: add exclude — templates/dup.md must be pruned
          config_with_exclude = MnemodocServer::Config.from_yaml(<<-YAML)
            paths:
              - #{tmp_dir}
            exclude:
              - "**/templates/**"
            db:
              path: #{tmp_db}
            ollama:
              host: http://127.0.0.1:#{port}
            YAML
          built2 = MnemodocServer::ToolRegistry.build(config_with_exclude, store)
          server2 = built2[:server]

          second_ingest = dispatch_json(server2, "ingest_path", {"path" => JSON::Any.new(tmp_dir)})
          expect(second_ingest["pruned"].as_i).to be >= 1

          list_result = dispatch_json(server2, "list_files", {} of String => JSON::Any)
          remaining = list_result["files"].as_a.map(&.["path"].as_s)
          expect(remaining.any?(&.ends_with?("real.md"))).to be_true
          expect(remaining.any?(&.ends_with?("templates/dup.md"))).to be_false
          built2[:embedder].close
        end
      ensure
        store.try(&.close)
        File.delete(tmp_db) rescue nil
        FileUtils.rm_rf(tmp_dir)
      end
    end
  end

  describe "oversized document is fully indexed" do
    it "splits a giant single-section file into multiple chunks without data loss" do
      with_server do |server, tmp_dir, store|
        # Build a table body larger than ChunkAssembler::MAX_TOKENS (1200 tokens).
        # 800 rows × ~8 chars each ≈ 6400 chars / 3 ≈ 2133 char-based tokens.
        rows = Array(String).new(800) { |index| "| row #{index} | value #{index} |" }
        oversized_content = "## BigTable\n\n" + rows.join("\n") + "\n"
        File.write(File.join(tmp_dir, "big.md"), oversized_content)

        ingest_result = dispatch_json(server, "ingest_path", {"path" => JSON::Any.new(tmp_dir)})
        expect(ingest_result["indexed"].as_i).to be >= 1

        # The file must appear in list_files with more than one chunk
        list_result = dispatch_json(server, "list_files", {} of String => JSON::Any)
        big_file_chunks = list_result["files"].as_a
          .select(&.["path"].as_s.ends_with?("big.md"))
          .map(&.["chunk_count"].as_i)
        expect(big_file_chunks).not_to be_empty
        expect(big_file_chunks.first).to be > 1

        # Total chunk count must also reflect the split
        expect(store.chunk_count).to be > 1
      end
    end
  end
end
