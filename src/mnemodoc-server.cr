require "log"
require "json"
require "yaml"
require "http/server"
require "http/client"
require "uri"
require "db"
require "sqlite3"

require "crystal-env/core"
require "admiral"
require "markd"
require "tallboy"

Crystal::Env.default("development")

require "mcp"

require "./mnemodoc_server/helpers"
require "./mnemodoc_server/advisories"
require "./mnemodoc_server/licenses"
require "./mnemodoc_server/chunk"
require "./mnemodoc_server/indexer/section"
require "./mnemodoc_server/indexer/sectionizer"
require "./mnemodoc_server/indexer/chunk_assembler"
require "./mnemodoc_server/indexer/format/handler"
require "./mnemodoc_server/indexer/format/markdown"
require "./mnemodoc_server/indexer/format/plain"
require "./mnemodoc_server/indexer/format/org"
require "./mnemodoc_server/indexer/format/asciidoc"
require "./mnemodoc_server/indexer/format/rst"
require "./mnemodoc_server/indexer/format/html"
require "./mnemodoc_server/indexer/format/zipped"
require "./mnemodoc_server/indexer/format/docx"
require "./mnemodoc_server/indexer/format/odt"
require "./mnemodoc_server/indexer/format/pptx"
require "./mnemodoc_server/indexer/format/epub"
require "./mnemodoc_server/indexer/format/odp"
require "./mnemodoc_server/indexer/format/fodt"
require "./mnemodoc_server/indexer/format/fodp"
require "./mnemodoc_server/indexer/format/nested_xml"
require "./mnemodoc_server/indexer/format/docbook"
require "./mnemodoc_server/indexer/format/dita"
require "./mnemodoc_server/indexer/format/fictionbook"
require "./mnemodoc_server/indexer/format/notebook"
require "./mnemodoc_server/indexer/format/pdf"
require "./mnemodoc_server/indexer/format/registry"
require "./mnemodoc_server/indexer/embedder"
require "./mnemodoc_server/indexer/crawler"
require "./mnemodoc_server/store/sqlite_vec"
require "./mnemodoc_server/store/sqlite"
require "./mnemodoc_server/store/qdrant_index"
require "./mnemodoc_server/search/semantic"
require "./mnemodoc_server/search/keyword"
require "./mnemodoc_server/search/hybrid"
require "./mnemodoc_server/tools/query"
require "./mnemodoc_server/tools/ingest"
require "./mnemodoc_server/tools/list"
require "./mnemodoc_server/tools/delete"
require "./mnemodoc_server/tools/status"
require "./mnemodoc_server/roles/role"
require "./mnemodoc_server/roles/selector"
require "./mnemodoc_server/tools/context"
require "./mnemodoc_server/tool_registry"
require "./mnemodoc_server/*"

module MnemodocServer
  Log = ::Log.for("mnemodoc-server")

  @@log_file : IO? = nil
  @@logger : ::Log::IOBackend? = nil

  # Bootstraps the application before any command runs: resets advisories,
  # loads the YAML config from the given path, applies MNEMODOC_* overrides,
  # validates the result, and initializes logging. Called once by every CLI
  # entry point (serve, index, search, …) before it touches the store.
  def self.init_app!(config_file : String) : Nil
    Advisories.clear
    load_config(config_file)
    config.apply_env!
    config.validate!
    setup_log!
    # Surface any startup advisories to the logs now that logging is ready.
    Advisories.all.each { |advisory| Log.warn { advisory } }
  end

  # The active configuration, memoized. Falls back to defaults when init_app!
  # has not loaded one yet (e.g. in unit tests that exercise a single object).
  def self.config : Config
    @@config ||= default_config
  end

  # Closes the log file on shutdown, but only when logging to a real file —
  # stderr/stdout streams are left untouched. Safe to call unconditionally.
  def self.close_log_file! : Nil
    @@log_file.try(&.close) if log_to_real_file?
  end

  # Reopens the log destination from scratch: drops the current file handle and
  # backend, then re-runs setup. Wired to SIGUSR1 so `logrotate` can rotate the
  # log file and have the server resume writing to the fresh one.
  def self.reopen_log_file! : Nil
    @@log_file = nil
    @@logger = nil
    setup_log!
  end

  # Builds the Qdrant index when the qdrant backend is selected, else nil.
  def self.qdrant_index(config : Config) : Store::QdrantIndex?
    return nil unless config.search.backend == "qdrant"
    Store::QdrantIndex.new(config.qdrant, config.qdrant_collection)
  end

  # Ensures the Qdrant collection exists and backfills it from the durable
  # embedding BLOBs when its point count is behind the SQLite chunk count
  # (best-effort; mirrors the vec0 startup backfill). Dim 768 = nomic-embed-text.
  def self.ensure_qdrant!(index : Store::QdrantIndex, store : Store::SQLite) : Nil
    index.ensure(768)
    chunk_count = store.chunk_count
    return unless (index.count || 0_i64) < chunk_count
    # Mirrors the vec0 backfill's INFO bracketing so a bulk Qdrant rebuild is
    # visible in the log rather than happening silently.
    Log.info { "backfilling qdrant from #{chunk_count} stored embeddings" }
    store.stored_embeddings.each_slice(256) { |batch| index.upsert(batch) }
    Log.info { "qdrant backfill complete" }
  end

  # Indexes the configured paths synchronously: builds its own embedder,
  # format registry and crawler, clears the index on an embedding-model change,
  # ensures/backfills Qdrant when enabled, runs the crawl, records the model and
  # logs a one-line summary. Does NOT spawn — the caller decides whether to run
  # this in the background. A failing index is logged and swallowed so it never
  # takes the server down.
  def self.background_index(config : Config, store : Store::SQLite, qi : Store::QdrantIndex?) : Nil
    idx_embedder = Indexer::Embedder.new(config.ollama)
    registry = Indexer::Format::Registry.new(config)
    crawler = Indexer::Crawler.new(config.resolved_paths, registry, config.exclude, qdrant_index: qi)
    if store.model_mismatch?(config.ollama.model)
      Log.warn { "embedding model changed; clearing index for a full re-index" }
      store.clear_index!
      qi.try(&.clear)
    end
    qi.try { |index| ensure_qdrant!(index, store) }
    index_result = crawler.run(store, idx_embedder, SingleFlight.new, concurrency: config.index.concurrency)
    store.embedding_model = config.ollama.model
    Log.info { "startup indexing: #{index_result[:indexed]} indexed, #{index_result[:skipped]} skipped, #{index_result[:pruned]} pruned" }
  rescue ex
    Log.error { "startup indexing failed: #{ex.message}" }
  end

  # Runs the standalone stdio MCP server: opens the store, spawns background
  # indexing, and serves over stdio until shutdown. Does not close the log file
  # (the CLI entry point owns the log-file lifecycle).
  def self.serve_stdio(config : Config) : Nil
    run_transport(config) { |server| MCP::Stdio.new(server) }
  end

  # Runs the standalone HTTP/SSE MCP server, binding to the configured host/port.
  # Any --host/--port overrides are applied to the config by the caller before
  # this is invoked. Does not close the log file (the CLI entry point owns it).
  def self.serve_sse(config : Config) : Nil
    run_transport(config) { |server| MCP::Http.new(server, host: config.server.sse_host, port: config.server.sse_port) }
  end

  # Shared body for serve_stdio/serve_sse: opens the store, builds the tool
  # registry, spawns background indexing, then builds the transport from the
  # given block, wires SystemD readiness/stopping callbacks and the TERM/USR1
  # signal traps, and runs it. Closes the embedder and store on exit; the log
  # file is left open for the CLI entry point's ensure block.
  private def self.run_transport(config : Config, &) : Nil
    store : Store::SQLite? = nil        # ameba:disable Lint/UselessAssign
    embedder : Indexer::Embedder? = nil # ameba:disable Lint/UselessAssign

    Dir.mkdir_p(File.dirname(config.db_path))
    store = Store::SQLite.new(config.db_path, vec0: config.search.backend != "qdrant")
    # Non-nil binding so the background fiber captures a typed store.
    active_store = store
    qi = qdrant_index(config)

    built = ToolRegistry.build(config, store, qi)
    server = built[:server]
    embedder = built[:embedder]

    # Index configured paths in the background so the server is immediately
    # responsive; unchanged files are skipped via mtime so restarts are cheap.
    spawn { background_index(config, active_store, qi) }

    transport = yield server
    transport.on_ready { SystemD.ready }
    transport.on_stopping { SystemD.stopping }
    Signal::TERM.trap { transport.stop }
    Signal::USR1.trap { reopen_log_file! }
    transport.start
  ensure
    embedder.try(&.close)
    store.try(&.close)
  end

  private def self.default_config : Config
    Config.from_yaml("")
  end

  private def self.load_config(config_path : String) : Nil
    file = File.expand_path(config_path)
    unless File.exists?(file)
      Advisories.add("no config file found at #{file}; running on default settings — indexed paths may be empty or wrong")
    end
    content = File.exists?(file) ? File.read(file) : ""
    cfg = Config.from_yaml(content)
    # Anchor path resolution to the config file's directory so relative paths
    # in `paths` and the auto DB location are correct regardless of CWD.
    cfg.source_dir = File.dirname(file)
    self.config = cfg
  end

  private def self.config=(config : Config) : Nil
    @@config = config
  end

  private def self.setup_log! : Nil
    severity = ::Log::Severity.parse(config.server.log_level)
    ::Log.setup do |builder|
      builder.bind "mnemodoc-server.*", severity, logger
    end
  rescue ArgumentError
    ::Log.setup do |builder|
      builder.bind "*", :info, logger
    end
    Advisories.add("unknown log_level '#{config.server.log_level}'; defaulting to info")
    Log.warn { "unknown log_level '#{config.server.log_level}', defaulting to info" }
  end

  private def self.logger : ::Log::IOBackend
    @@logger ||= ::Log::IOBackend.new(log_file)
  end

  private def self.log_file : IO
    @@log_file ||= open_log_destination
  end

  # Opens the configured log destination: STDERR/STDOUT for the stream keywords,
  # otherwise the resolved file path (creating its parent directory).
  private def self.open_log_destination : IO
    keyword = config.server.log_file.downcase
    return STDERR if keyword.in?("stderr", "")
    return STDOUT if keyword == "stdout"
    path = config.log_file_path
    Dir.mkdir_p(File.dirname(path))
    File.open(path, "a")
  end

  # True when the log destination is a real file (not STDERR/STDOUT).
  private def self.log_to_real_file? : Bool
    !config.server.log_file.downcase.in?("stderr", "stdout", "")
  end
end

unless Crystal.env.test?
  begin
    MnemodocServer::CLI.run
  rescue e : Exception
    STDERR.puts e.message
    exit 1
  end
end
