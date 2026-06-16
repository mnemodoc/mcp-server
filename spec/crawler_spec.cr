require "./spec_helper"
require "compress/zip"
require "file_utils"

# A QdrantIndex that records calls instead of hitting Qdrant (built at a dead
# port; the overridden methods never touch the wrapped Collection).
private class RecordingQdrant < MnemodocServer::Store::QdrantIndex
  getter upserts = [] of Int64
  getter deletes = [] of Int64

  def upsert(entries : Array({id: Int64, vector: Array(Float32)})) : Bool
    entries.each { |entry| @upserts << entry[:id] }
    true
  end

  def delete(ids : Array(Int64)) : Bool
    @deletes.concat(ids)
    true
  end
end

Spectator.describe MnemodocServer::Indexer::Crawler do
  let(tmp_dir) { "/tmp/mnemodoc-crawler-#{Random::Secure.hex(4)}" }

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  private def fake_ollama(embedding : Array(Float32), &)
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
    begin
      yield addr.port
    ensure
      server.close
    end
  end

  private def write_file(name : String, content : String) : Int64
    path = File.join(tmp_dir, name)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.info(path).modification_time.to_unix
  end

  private def default_registry : MnemodocServer::Indexer::Format::Registry
    MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
  end

  describe "#collect_files" do
    it "finds all .md files recursively and skips unsupported extensions" do
      write_file("a.md", "# A")
      write_file("sub/b.md", "# B")
      write_file("sub/c.png", "binary")

      crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], default_registry)
      files = crawler.collect_files
      expect(files.map { |file_entry| File.basename(file_entry[:path]) }.sort!).to eq(["a.md", "b.md"])
    end

    it "returns path and mtime for each file" do
      mtime = write_file("x.md", "content")
      crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], default_registry)
      files = crawler.collect_files
      expect(files.first[:mtime]).to eq(mtime)
    end
  end

  describe "qdrant sync" do
    it "upserts indexed files and deletes pruned files' points" do
      embedding = Array(Float32).new(768, 0.1_f32)
      fake_ollama(embedding) do |port|
        write_file("keep.md", "# K\n\n## S\n\ncontent")
        db_path = "/tmp/mnemodoc-crawler-qdrant-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path, vec0: false)
        cfg = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}")
        embedder = MnemodocServer::Indexer::Embedder.new(cfg)
        sf = MnemodocServer::SingleFlight.new
        qdrant = RecordingQdrant.new(MnemodocServer::QdrantConfig.from_yaml("url: http://127.0.0.1:1"), "t")
        crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], default_registry, qdrant_index: qdrant)

        crawler.run(store, embedder, sf, concurrency: 1)
        expect(qdrant.upserts).not_to be_empty

        kept = File.join(tmp_dir, "keep.md")
        ids_before = store.chunk_ids_for_file(kept)
        File.delete(kept)
        crawler.run(store, embedder, sf, concurrency: 1)
        expect(qdrant.deletes.sort!).to eq(ids_before.sort!)

        store.close
        File.delete(db_path) rescue nil
        embedder.close
      end
    end
  end

  describe "#run with concurrency" do
    it "indexes all files without loss when run concurrently" do
      embedding = Array(Float32).new(768, 0.1_f32)

      fake_ollama(embedding) do |port|
        # Write 6 markdown files each with a couple of sections
        6.times do |index|
          write_file("doc#{index}.md", "# File #{index}\n\n## Section A\n\ncontent A for file #{index}\n\n## Section B\n\ncontent B for file #{index}")
        end

        db_path = "/tmp/mnemodoc-crawler-concurrent-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
        sf = MnemodocServer::SingleFlight.new
        crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)

        result = crawler.run(store, embedder, sf, concurrency: 4)

        expect(result[:indexed]).to eq(6)
        expect(store.list_files.size).to eq(6)
        expect(store.chunk_count).to be > 0

        store.close
        File.delete(db_path) rescue nil
        embedder.close
      end
    end

    it "skips already-indexed files and counts them" do
      embedding = Array(Float32).new(768, 0.1_f32)

      fake_ollama(embedding) do |port|
        mtime = write_file("existing.md", "# Existing\n\n## Section\n\ncontent")
        write_file("new_file.md", "# New\n\n## Section\n\ncontent")

        db_path = "/tmp/mnemodoc-crawler-skip-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)
        store.upsert_file(File.join(tmp_dir, "existing.md"), mtime: mtime)

        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
        sf = MnemodocServer::SingleFlight.new
        crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)

        result = crawler.run(store, embedder, sf, concurrency: 2)

        expect(result[:indexed]).to eq(1)
        expect(result[:skipped]).to eq(1)

        store.close
        File.delete(db_path) rescue nil
        embedder.close
      end
    end
  end

  # Variant of fake_ollama that returns 500 when the request body contains
  # the given marker, and 200 with a valid embedding array otherwise.
  private def fake_ollama_selective(marker : String, &)
    embedding = Array(Float32).new(768, 0.1_f32)
    server = HTTP::Server.new do |ctx|
      body = ctx.request.body.try(&.gets_to_end) || ""
      if body.includes?(marker)
        ctx.response.status_code = 500
        ctx.response.content_type = "application/json"
        ctx.response.print(%({"error": "the input length exceeds the context length"}))
      else
        ctx.response.status_code = 200
        ctx.response.content_type = "application/json"
        count = JSON.parse(body)["input"].as_a.size rescue 1
        ctx.response.print({"embeddings" => Array.new(count, embedding)}.to_json)
      end
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

  describe "#run resilient embedding" do
    it "indexes a file even when one of its chunks fails to embed" do
      # Write a file whose content produces multiple sections: one section
      # contains "BOOM" (triggers 500 from fake Ollama), others are fine.
      # The whole file must still appear in the index after run.
      write_file("mixed.md", "## Good Section\n\ngood content here\n\n## Bad Section\n\nThis chunk has BOOM in it\n\n## Another Good\n\nmore good content")

      fake_ollama_selective(marker: "BOOM") do |port|
        db_path = "/tmp/mnemodoc-crawler-resilient-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
        sf = MnemodocServer::SingleFlight.new
        crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)

        result = crawler.run(store, embedder, sf, concurrency: 1)

        # File is indexed despite one bad chunk
        expect(result[:indexed]).to eq(1)
        listed = store.list_files
        expect(listed.map { |file_info| File.basename(file_info.path) }).to contain("mixed.md")
        # At least the two good chunks are stored
        expect(store.chunk_count).to be >= 2
        # The failed chunk count must be non-zero (at least one chunk failed to embed)
        expect(result[:failed]).to be > 0

        store.close
        File.delete(db_path) rescue nil
        embedder.close
      end
    end

    it "reports zero failed chunks on a clean run" do
      embedding = Array(Float32).new(768, 0.1_f32)

      fake_ollama(embedding) do |port|
        write_file("clean.md", "## Section\n\ncontent")

        db_path = "/tmp/mnemodoc-crawler-nofail-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
        sf = MnemodocServer::SingleFlight.new
        crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)

        result = crawler.run(store, embedder, sf, concurrency: 1)

        expect(result[:indexed]).to eq(1)
        expect(result[:failed]).to eq(0)

        store.close
        File.delete(db_path) rescue nil
        embedder.close
      end
    end
  end

  describe "#collect_files with exclude" do
    it "skips files matching an exclude glob" do
      write_file("doc/real.md", "# real")
      write_file("app/templates/doc/dup.md", "# dup")
      crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], default_registry, ["**/templates/**"])
      files = crawler.collect_files
      basenames = files.map { |file_entry| File.basename(file_entry[:path]) }
      expect(basenames).to contain("real.md")
      expect(basenames).not_to contain("dup.md")
    end
  end

  describe "#files_to_index" do
    it "returns files not yet indexed" do
      write_file("a.md", "content")
      store = MnemodocServer::Store::SQLite.new("/tmp/mnemodoc-crawler-idx-#{Random::Secure.hex(4)}.db")
      crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], default_registry)
      to_index = crawler.files_to_index(store)
      expect(to_index.map { |file_entry| File.basename(file_entry[:path]) }).to eq(["a.md"])
      store.close
    end

    it "excludes already-indexed files with same mtime" do
      mtime = write_file("a.md", "content")
      db_path = "/tmp/mnemodoc-crawler-idx2-#{Random::Secure.hex(4)}.db"
      store = MnemodocServer::Store::SQLite.new(db_path)
      store.upsert_file(File.join(tmp_dir, "a.md"), mtime: mtime)
      crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], default_registry)
      to_index = crawler.files_to_index(store)
      expect(to_index).to be_empty
      store.close
    end
  end

  describe "#run with progress callback" do
    it "calls the progress proc once per indexed file with correct args" do
      embedding = Array(Float32).new(768, 0.1_f32)

      fake_ollama(embedding) do |port|
        write_file("a.md", "## Section\ncontent a")
        write_file("b.md", "## Section\ncontent b")

        config = MnemodocServer::Config.from_yaml(
          "ollama:\n  host: http://127.0.0.1:#{port}\n  model: test"
        )
        db_path = "/tmp/mcp-crawler-progress-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)

        calls = [] of {indexed: Int32, total: Int32, file: String}
        progress = Proc(Int32, Int32, String, Nil).new do |indexed, total, file|
          calls << {indexed: indexed, total: total, file: file}
        end

        registry = MnemodocServer::Indexer::Format::Registry.new(config)
        crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)
        embedder = MnemodocServer::Indexer::Embedder.new(config.ollama)
        sf = MnemodocServer::SingleFlight.new

        crawler.run(store, embedder, sf, concurrency: 1, progress: progress)

        store.close
        File.delete(db_path) rescue nil

        expect(calls.size).to eq(2)
        expect(calls.map(&.[:total]).uniq!).to eq([2])
        expect(calls.map(&.[:indexed]).sort!).to eq([1, 2])
        expect(calls.all?(&.[:file].ends_with?(".md"))).to be_true
      end
    end

    it "does not raise when progress is nil" do
      embedding = Array(Float32).new(768, 0.1_f32)

      fake_ollama(embedding) do |port|
        write_file("c.md", "## Section\ncontent c")

        config = MnemodocServer::Config.from_yaml(
          "ollama:\n  host: http://127.0.0.1:#{port}\n  model: test"
        )
        db_path = "/tmp/mcp-crawler-noprogress-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)

        registry = MnemodocServer::Indexer::Format::Registry.new(config)
        crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)
        embedder = MnemodocServer::Indexer::Embedder.new(config.ollama)
        sf = MnemodocServer::SingleFlight.new

        result = crawler.run(store, embedder, sf, concurrency: 1, progress: nil)

        store.close
        File.delete(db_path) rescue nil

        expect(result[:indexed]).to eq(1)
      end
    end
  end

  describe "#run pruning" do
    it "prunes files removed from disk on reindex" do
      embedding = Array(Float32).new(768, 0.1_f32)

      fake_ollama(embedding) do |port|
        write_file("a.md", "# A\n\n## Section\n\ncontent A")
        write_file("b.md", "# B\n\n## Section\n\ncontent B")

        db_path = "/tmp/mnemodoc-crawler-prune1-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
        sf = MnemodocServer::SingleFlight.new
        crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)

        result1 = crawler.run(store, embedder, sf, concurrency: 2)
        expect(result1[:indexed]).to eq(2)

        # Remove b.md from disk
        File.delete(File.join(tmp_dir, "b.md")) rescue nil

        result2 = crawler.run(store, embedder, sf, concurrency: 2)
        expect(result2[:pruned]).to eq(1)
        remaining = store.list_files.map { |file_info| File.basename(file_info.path) }
        expect(remaining).to eq(["a.md"])

        store.close
        File.delete(db_path) rescue nil
        embedder.close
      end
    end

    it "prunes files newly matched by exclude on reindex" do
      embedding = Array(Float32).new(768, 0.1_f32)

      fake_ollama(embedding) do |port|
        write_file("doc/real.md", "# Real\n\n## Section\n\ncontent")
        write_file("templates/dup.md", "# Dup\n\n## Section\n\ncontent")

        db_path = "/tmp/mnemodoc-crawler-prune2-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
        sf = MnemodocServer::SingleFlight.new

        # First run: no exclude, both files indexed
        crawler_no_exclude = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)
        result1 = crawler_no_exclude.run(store, embedder, sf, concurrency: 2)
        expect(result1[:indexed]).to eq(2)

        # Second run: exclude templates, dup.md should be pruned
        crawler_with_exclude = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry, ["**/templates/**"])
        result2 = crawler_with_exclude.run(store, embedder, sf, concurrency: 2)
        expect(result2[:pruned]).to eq(1)
        remaining = store.list_files.map { |file_info| File.basename(file_info.path) }
        expect(remaining).to eq(["real.md"])

        store.close
        File.delete(db_path) rescue nil
        embedder.close
      end
    end

    it "does not prune from roots that do not exist on disk" do
      embedding = Array(Float32).new(768, 0.1_f32)

      fake_ollama(embedding) do |port|
        write_file("keep.md", "# Keep\n\n## Section\n\ncontent")

        db_path = "/tmp/mnemodoc-crawler-prune3-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
        sf = MnemodocServer::SingleFlight.new

        crawler1 = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)
        crawler1.run(store, embedder, sf, concurrency: 1)

        # Run with a mix: existing root + non-existent ghost root
        ghost_root = "/tmp/mnemodoc-nonexistent-#{Random::Secure.hex(4)}"
        crawler2 = MnemodocServer::Indexer::Crawler.new([tmp_dir, ghost_root], registry)
        result = crawler2.run(store, embedder, sf, concurrency: 1)

        # keep.md must not be pruned because ghost_root does not exist
        expect(result[:pruned]).to eq(0)
        expect(store.list_files.size).to eq(1)

        store.close
        File.delete(db_path) rescue nil
        embedder.close
      end
    end
  end

  describe "#collect_files file vs directory" do
    it "indexes a file named directly in paths (the file-entry bug)" do
      embedding = Array(Float32).new(768, 0.1_f32)
      fake_ollama(embedding) do |port|
        write_file("notes.md", "## Note\n\nbody")
        file_path = File.join(tmp_dir, "notes.md")

        registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
        db_path = "/tmp/mnemodoc-crawler-fileentry-#{Random::Secure.hex(4)}.db"
        store = MnemodocServer::Store::SQLite.new(db_path)
        config = MnemodocServer::OllamaConfig.from_yaml("host: http://127.0.0.1:#{port}\nbatch_size: 4")
        embedder = MnemodocServer::Indexer::Embedder.new(config)
        sf = MnemodocServer::SingleFlight.new

        # paths entry is the FILE itself, not its directory
        crawler = MnemodocServer::Indexer::Crawler.new([file_path], registry)
        result = crawler.run(store, embedder, sf, concurrency: 1)

        expect(result[:indexed]).to eq(1)
        expect(store.list_files.map { |file_info| File.basename(file_info.path) }).to eq(["notes.md"])

        store.close
        File.delete(db_path) rescue nil
        embedder.close
      end
    end

    it "discovers multiple supported extensions in a directory" do
      registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
      write_file("a.md", "# A")
      write_file("b.rst", "Title\n=====\n")
      write_file("c.png", "binary")
      crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)
      names = crawler.collect_files.map { |file_entry| File.basename(file_entry[:path]) }.sort!
      expect(names).to eq(["a.md", "b.rst"])
    end

    it "discovers zipped document formats in a directory" do
      registry = MnemodocServer::Indexer::Format::Registry.new(MnemodocServer::Config.from_yaml("paths:\n  - x/"))
      File.open(File.join(tmp_dir, "a.docx"), "w") do |file|
        Compress::Zip::Writer.open(file) { |zip| zip.add("word/document.xml", "<w:document xmlns:w=\"urn:w\"/>") }
      end
      File.open(File.join(tmp_dir, "b.epub"), "w") do |file|
        Compress::Zip::Writer.open(file, &.add("ch.xhtml", "<html/>"))
      end
      File.write(File.join(tmp_dir, "c.png"), "binary")
      crawler = MnemodocServer::Indexer::Crawler.new([tmp_dir], registry)
      names = crawler.collect_files.map { |entry| File.basename(entry[:path]) }.sort!
      expect(names).to eq(["a.docx", "b.epub"])
    end
  end
end
