require "log"
require "json"
require "yaml"
require "http/server"
require "http/client"
require "uri"
require "db"
require "sqlite3"

require "admiral"
require "markd"
require "tallboy"

require "mcp"
require "file_watcher"

require "file_utils"

require "./mnemodoc_server/helpers"
require "./mnemodoc_server/advisories"
require "./mnemodoc_server/progress"
require "./mnemodoc_server/project"
require "./mnemodoc_server/install/claude_code"
require "./mnemodoc_server/licenses"
require "./mnemodoc_server/chunk"
require "./mnemodoc_server/indexer/document"
require "./mnemodoc_server/usage/event"
require "./mnemodoc_server/usage/transport"
require "./mnemodoc_server/usage/recorder"
require "./mnemodoc_server/usage/collector"
require "./mnemodoc_server/indexer/section"
require "./mnemodoc_server/indexer/sectionizer"
require "./mnemodoc_server/indexer/chunk_assembler"
require "./mnemodoc_server/indexer/format/handler"
require "./mnemodoc_server/indexer/format/fence_tracker"
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
require "./mnemodoc_server/store/usage"
require "./mnemodoc_server/store/qdrant_index"
require "./mnemodoc_server/search/semantic"
require "./mnemodoc_server/search/keyword"
require "./mnemodoc_server/search/hybrid"
require "./mnemodoc_server/search/hook_selection"
require "./mnemodoc_server/tools/document_access"
require "./mnemodoc_server/tools/read"
require "./mnemodoc_server/tools/outline"
require "./mnemodoc_server/tools/query"
require "./mnemodoc_server/tools/ingest"
require "./mnemodoc_server/tools/list"
require "./mnemodoc_server/tools/delete"
require "./mnemodoc_server/tools/status"
require "./mnemodoc_server/hooks/input"
require "./mnemodoc_server/hooks/adapter"
require "./mnemodoc_server/hooks/claude_code"
require "./mnemodoc_server/hooks/registry"
require "./mnemodoc_server/roles/role"
require "./mnemodoc_server/roles/selector"
require "./mnemodoc_server/tools/context"
require "./mnemodoc_server/tool_registry"
require "./mnemodoc_server/*"

module MnemodocServer
  # The root source every binding is expressed against, so that raising and
  # restoring the severity targets exactly what `setup_log!` bound.
  LOG_SOURCE = "mnemodoc-server"

  Log = ::Log.for(LOG_SOURCE)

  @@log_file : IO? = nil
  @@logger : ::Log::IOBackend? = nil
  # Set only while a progress bar owns stderr; holds the severity to put back.
  @@hushed_level : ::Log::Severity? = nil
  # Defaults to true so that anything constructing a store or a tool registry
  # without going through `init_app!` behaves exactly as before. Only discovery
  # can flip it to false, and only when it actually failed to find a project.
  @@project_initialized = true
  @@config_file = ""

  # The name of the directory that marks a project as initialised. It holds the
  # index, the daemon socket and lock, and is git-ignored — so its presence is a
  # local, deliberate statement that this project has been indexed.
  PROJECT_MARKER = ".mnemodoc"

  # Bootstraps the application before any command runs: resets advisories,
  # resolves which project this invocation belongs to, loads its YAML config,
  # applies MNEMODOC_* overrides, validates the result, and initializes logging.
  # Called once by every CLI entry point (serve, index, search, …) before it
  # touches the store.
  #
  # `from` is the directory discovery starts at. It is a parameter rather than
  # a plain `Dir.current` read so the behaviour can be exercised without
  # changing the process's working directory.
  def self.init_app!(config_file : String, from : String = Dir.current) : Nil
    Advisories.clear
    load_config(config_file, from)
    config.apply_env!
    # An uninitialised project has no configuration to validate: every value is
    # a default, and `paths` is deliberately empty. Validating here would abort
    # the process on a condition the tools are meant to report calmly.
    config.validate! if project_initialized?
    setup_log!
    # Surface any startup advisories to the logs now that logging is ready.
    Advisories.all.each { |advisory| Log.warn { advisory } }
  end

  # Whether this invocation resolved to an initialised project. When false the
  # server still runs, but it owns no index: it creates nothing on disk and its
  # tools answer with an invitation to run `init` rather than an empty result.
  def self.project_initialized? : Bool
    @@project_initialized
  end

  # The config file this invocation resolved to, whether it was given explicitly
  # or discovered. Empty when no project was found. The daemon is spawned with
  # this rather than with the raw flag, so it loads the very same configuration
  # as the proxy instead of re-running discovery from its own inherited CWD.
  def self.config_file : String
    @@config_file
  end

  # Walks up from `from` and returns the first ancestor holding a `PROJECT_MARKER`
  # directory, or nil. The nearest marker wins, so a package nested inside a
  # larger initialised repository belongs to itself.
  #
  # Bounded by construction: `Path#parents` yields a finite ancestor list, so no
  # symlink arrangement can make this loop.
  def self.discover_project(from : String) : String?
    start = Path[File.expand_path(from)]
    candidates = start.parents << start
    candidates.reverse_each do |dir|
      return File.realpath(dir.to_s) if Dir.exists?(dir / PROJECT_MARKER)
    end
    nil
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

  # Holds back info-level logging while a progress bar owns stderr.
  #
  # The bar rewrites its own line, so an info entry landing in the middle of it
  # produces "20%2026-08-01T01:00:16 INFO - indexed ..." and leaves neither
  # readable. Only one writer may own the stream at a time, and the caller has
  # already established that the log is going to stderr before asking for this.
  #
  # Warnings and above are deliberately left alone: they are rare, and dropping
  # one to keep a bar tidy would be a poor trade.
  #
  # Rebinding the SAME backend only replaces the severity of the existing
  # bindings (Log::Builder#append_backend), so nothing is duplicated and no
  # dispatcher fiber is created.
  def self.hush_log! : Nil
    return if @@hushed_level
    log = ::Log.for(LOG_SOURCE)
    backend = log.backend
    return unless backend

    @@hushed_level = log.level
    ::Log.builder.bind("#{LOG_SOURCE}.*", :warn, backend)
  end

  # Restores the severity `hush_log!` raised. A no-op when nothing was hushed,
  # since callers release from an ensure block on paths that may have failed
  # before the bar was ever put up.
  def self.release_log! : Nil
    level = @@hushed_level
    return unless level
    @@hushed_level = nil

    log = ::Log.for(LOG_SOURCE)
    backend = log.backend
    return unless backend

    ::Log.builder.bind("#{LOG_SOURCE}.*", level, backend)
  end

  # Reopens the log destination from scratch: drops the current file handle and
  # backend, then re-runs setup. Wired to SIGUSR1 so `logrotate` can rotate the
  # log file and have the server resume writing to the fresh one.
  def self.reopen_log_file! : Nil
    # The old handle is closed, not merely dropped: without that, each rotation
    # leaked a descriptor and kept the rotated file alive on disk, so logrotate
    # freed nothing and a long-lived daemon climbed towards its limit.
    #
    # It is closed LAST, though. This runs from a signal handler while request
    # fibers are logging, so between closing and rebinding there must be no
    # moment where the live backend points at a closed descriptor — a write
    # there raises inside whatever fiber happened to log, killing it.
    previous_file = @@log_file
    previous_backend = @@logger
    @@log_file = nil
    @@logger = nil
    setup_log!
    # The backend goes too: it owns an async dispatcher fiber, so dropping it
    # without closing leaked one of those per rotation on top of the descriptor.
    previous_backend.try(&.close)
    previous_file.try(&.close) unless previous_file.nil? || previous_file.same?(STDERR) || previous_file.same?(STDOUT)
  end

  # Builds the Qdrant index when the qdrant backend is selected, else nil.
  def self.qdrant_index(config : Config) : Store::QdrantIndex?
    return nil unless config.search.backend == "qdrant"
    Store::QdrantIndex.new(config.qdrant, config.qdrant_collection)
  rescue ex : Store::QdrantUnavailable
    # Degrading is the documented behaviour of this backend; refusing to start
    # is not. The advisory reaches the agent in every tool response, which a
    # log line would not.
    Advisories.add("qdrant backend is configured but unusable: #{ex.message}; searching without it")
    Log.error { "qdrant unavailable: #{ex.message}" }
    nil
  end

  # The width the Qdrant collection has already been ensured for, so the retry
  # described on ensure_qdrant! costs a comparison rather than a round trip.
  # Process-wide because the daemon is one process per project.
  @@qdrant_ensured_dim : Int32? = nil

  # Text embedded for the sole purpose of learning the model's vector width.
  # Its content is irrelevant: only the size of what comes back is read.
  DIM_PROBE_TEXT = "embedding dimension probe"

  # Learns the configured model's vector width and hands it to the store, which
  # adopts it or refuses the run.
  #
  # Called at the START of an indexing run, before the crawl. That placement is
  # the point: the crawler rescues per file, so a mismatch discovered while
  # writing a chunk comes back as a `failed` counter rather than as a failure —
  # the same silent degradation this whole path exists to remove. One extra
  # embedding call per run buys a refusal before anything is written.
  #
  # An unreachable model is NOT a probe failure, and returns nil rather than
  # raising. The probe is here to catch a dimension mismatch, not to become a
  # new liveness check on Ollama: that is already reported, by the crawler's
  # `failed` counter and by `index`'s exit code, and turning it into a hard stop
  # here would break two documented behaviours — a run with nothing to do still
  # succeeds, and a run that could embed nothing still reports how many chunks
  # failed. Nothing is lost by continuing: with no vectors produced, no vector
  # of the wrong width can be written either.
  #
  # Only Store::EmbeddingDimMismatch escapes, which is the one condition the
  # caller must stop on.
  def self.probe_embedding_dim!(config : Config, store : Store::SQLite,
                                embedder : Indexer::Embedder) : Int32?
    # Nothing to learn, so nothing is asked. An index that already records a
    # width, under the very model named in the configuration, cannot be about
    # to meet a different one through any supported path — a model change goes
    # through clear_index!, which releases the width along with the table.
    #
    # This is not an optimisation. Probing unconditionally made every daemon
    # start contact Ollama even with nothing to index — a network call on a
    # path that had none, and a startup left waiting on the model's
    # responsiveness for an answer it did not need. spec/daemon_spec.cr states
    # that invariant in its own header.
    #
    # The residual case — a model re-released at another width under the same
    # name — is not lost: the width is checked again against every vector
    # written, and Indexer::Crawler now lets that refusal abort the run rather
    # than counting it as one failed file.
    recorded = store.embedding_dim
    return recorded if recorded && !store.model_mismatch?(config.ollama.model)

    # first?, not first: a 200 carrying `{"embeddings": []}` is a case
    # Embedder#embed_many tolerates on purpose, and `first` would answer it with
    # an Enumerable::EmptyError that walks past every caller's rescue.
    vector = embedder.embed_batch([DIM_PROBE_TEXT]).first?
    if vector.nil? || vector.empty?
      Log.warn { "the embedding model returned an empty vector; the dimension will be adopted at the first indexed chunk" }
      return nil
    end
    store.prepare_embedding_dim!(vector.size)
    vector.size
  rescue ex : Indexer::EmbedderError
    Log.warn { "could not probe the embedding dimension (#{ex.message}); it will be adopted at the first indexed chunk" }
    nil
  end

  # Ensures the Qdrant collection exists and backfills it from the durable
  # embedding BLOBs when its point count is behind the SQLite chunk count
  # (best-effort; mirrors the vec0 startup backfill).
  #
  # The width comes from the store, which took it from a vector the configured
  # model really produced. It used to be the literal 768, so a collection was
  # created for nomic-embed-text whatever the configured model was.
  #
  # Re-entrant, and it has to be: when the width is not known yet — Ollama down
  # at startup, so the probe learned nothing — there is nothing to size a
  # collection with, and the very next thing that produces a vector (the
  # daemon's watcher, an ingest) would otherwise upsert into a collection that
  # was never created. QdrantIndex swallows that failure and returns false, so
  # the vectors would vanish without a word. Calling this again once a width
  # exists is what closes that window; the ensure itself is idempotent, and the
  # guard below keeps the repeat calls free.
  def self.ensure_qdrant!(index : Store::QdrantIndex, store : Store::SQLite) : Nil
    dim = store.embedding_dim
    if dim.nil?
      Log.warn { "qdrant: no embedding dimension known yet; the collection is created as soon as one is" }
      return
    end
    # The guard covers the backfill below as well as the ensure, on purpose:
    # `index.count` is an HTTP round trip, and this now runs on the watch path,
    # once per changed file. Repeating it there would cost a request per save to
    # re-answer a question settled at startup.
    return if @@qdrant_ensured_dim == dim
    index.ensure(dim)
    @@qdrant_ensured_dim = dim
    chunk_count = store.chunk_count
    return unless (index.count || 0_i64) < chunk_count
    # Mirrors the vec0 backfill's INFO bracketing so a bulk Qdrant rebuild is
    # visible in the log rather than happening silently.
    Log.info { "backfilling qdrant from #{chunk_count} stored embeddings" }
    store.each_stored_embedding_batch(256) { |batch| index.upsert(batch) }
    Log.info { "qdrant backfill complete" }
  end

  # Indexes the configured paths synchronously: builds its own embedder,
  # format registry and crawler, clears the index on an embedding-model change,
  # ensures/backfills Qdrant when enabled, runs the crawl, records the model and
  # logs a one-line summary. Does NOT spawn — the caller decides whether to run
  # this in the background. A failing index is logged and swallowed so it never
  # takes the server down.
  # Rebuilds the stored text and outline for files indexed before documents
  # were stored. Returns how many files were rebuilt.
  #
  # Deliberately embedding-free: the chunks and their vectors are already in the
  # index and still correct, so this is a read and a parse per file and must
  # never reach the embedder. A backfill that needed Ollama would make every
  # document unreadable whenever Ollama is down, for a rebuild that has nothing
  # to do with embeddings.
  #
  # It writes through index_file with the file's recorded mtime, so the file's
  # freshness bookkeeping is unchanged and a later crawl still skips it.
  def self.backfill_documents!(config : Config, store : Store::SQLite,
                               registry : Indexer::Format::Registry) : Int32
    missing = store.files_missing_documents
    return 0 if missing.empty?

    rebuilt = 0
    missing.each do |file|
      begin
        next unless File.file?(file[:path])
        handler = registry.for(file[:path], explicit: true)
        next if handler.nil?
        document = handler.extract(file[:path], file[:mtime])
        next if document.text.empty?
        store.index_file(
          file[:path], file[:mtime], rehydrated_chunks(store, file[:path]),
          text: document.text, verbatim: document.verbatim?, outline: document.outline,
        )
        rebuilt += 1
      rescue ex
        Log.warn { "document backfill failed for #{file[:path]}: #{ex.message}" }
      end
    end
    Log.info { "document backfill: #{rebuilt} of #{missing.size} files rebuilt" } if rebuilt > 0
    rebuilt
  end

  # A file's stored chunks with their vectors put back.
  #
  # chunks_for_files deliberately leaves the embedding empty — the vectors live
  # in vec0 and no read path needs them. Rewriting those chunks through
  # index_file as they come would therefore erase every vector of the file, and
  # search would go on answering with nothing but its keyword signal behind it.
  private def self.rehydrated_chunks(store : Store::SQLite, path : String) : Array(Chunk)
    vectors = store.embeddings_for_file(path).to_h { |row| {row[:id], row[:vector]} }
    store.chunks_for_files([path]).map do |chunk|
      Chunk.new(
        file_path: chunk.file_path, heading: chunk.heading,
        parent_heading: chunk.parent_heading, content: chunk.content,
        embedding: chunk.id.try { |id| vectors[id]? } || [] of Float32,
        token_count: chunk.token_count, mtime: chunk.mtime,
      )
    end
  end

  def self.background_index(config : Config, store : Store::SQLite, qi : Store::QdrantIndex?,
                            sf : SingleFlight = SingleFlight.new) : Nil
    idx_embedder = Indexer::Embedder.new(config.ollama, idle_connections: config.index.concurrency)
    registry = Indexer::Format::Registry.new(config)
    # Before the crawl: an index predating stored documents would otherwise
    # never be revisited, since indexing is driven by mtime and those files have
    # not changed.
    backfill_documents!(config, store, registry)
    crawler = Indexer::Crawler.new(config.resolved_paths, registry, config.exclude, qdrant_index: qi)
    if store.model_mismatch?(config.ollama.model)
      Log.warn { "embedding model changed; clearing index for a full re-index" }
      store.clear_index!
      qi.try(&.clear)
    end
    probe_embedding_dim!(config, store, idx_embedder)
    qi.try { |index| ensure_qdrant!(index, store) }
    index_result = crawler.run(store, idx_embedder, sf, concurrency: config.index.concurrency)
    store.embedding_model = config.ollama.model
    Log.info { "startup indexing: #{index_result[:indexed]} indexed, #{index_result[:skipped]} skipped, #{index_result[:pruned]} pruned" }
  rescue ex : Store::EmbeddingDimMismatch
    # Surfaced as an advisory and not merely logged: this is precisely the state
    # in which the index answers searches with its keyword signal alone, and
    # Log.warn is invisible in several MCP clients — the agent would go on
    # trusting a half-working index.
    Advisories.add("indexing stopped: #{ex.message}")
    Log.error { "startup indexing failed: #{ex.message}" }
  rescue ex
    Log.error { "startup indexing failed: #{ex.message}" }
  end

  # Handles one file-watch event: re-indexes a single supported file (added or
  # changed) through the crawler, or removes a deleted file from the store and
  # Qdrant. Unsupported extensions are skipped here because a single-file crawler
  # root is treated as explicit and would otherwise fall back to plain text.
  # Wrapped by the caller so one bad event never breaks the watch loop.
  # True when a daemon is listening on the project's socket and answering the
  # transport's liveness probe. The single source of truth for "is it running":
  # the pid file alone cannot say, since a hard kill leaves it behind.
  # Seconds the liveness probe waits for an answer. A socket that accepts and
  # then says nothing is not theoretical: the daemon's SQLite writes are
  # blocking C calls that never yield, so during a large backfill it holds the
  # listening socket while answering nothing. Without this bound the probe waits
  # forever, and the MCP client that spawned the proxy hangs with it.
  HEALTH_PROBE_TIMEOUT = 5.seconds

  def self.daemon_healthy?(config : Config) : Bool
    socket = UNIXSocket.new(config.daemon_socket_path)
    socket.read_timeout = HEALTH_PROBE_TIMEOUT
    socket.write_timeout = HEALTH_PROBE_TIMEOUT
    client = HTTP::Client.new(socket)
    begin
      client.get("/health").status_code == 200
    ensure
      client.close
    end
  rescue
    false
  end

  # The pid recorded by the running daemon, or nil when the file is absent or
  # does not hold a plain integer. Says nothing about whether that pid is alive:
  # pair it with daemon_healthy? before acting on it.
  def self.daemon_pid(config : Config) : Int64?
    File.read(config.daemon_pid_path).strip.to_i64?
  rescue File::Error
    nil
  end

  # Waits for the daemon's socket to stop answering, which is what tells us the
  # process is actually gone rather than merely signalled. Returns false when
  # *timeout* elapses first.
  def self.await_daemon_exit(config : Config, timeout : Time::Span) : Bool
    deadline = Time.instant + timeout
    until Time.instant > deadline
      return true unless daemon_healthy?(config)
      sleep 100.milliseconds
    end
    !daemon_healthy?(config)
  end

  # True when the path is one of the index's own files rather than a document.
  # Since the index defaults to `.mnemodoc/` inside the project, it sits under
  # the watched paths: the database, its SQLite sidecars and the daemon's socket
  # and lock all raise watch events, and a delete event would otherwise issue a
  # pointless store write on every WAL checkpoint. Matches the artifacts by name
  # rather than the whole directory, so an explicit `db.path` pointing at a
  # directory that also holds documents keeps indexing those documents.
  def self.index_artifact?(path : String, config : Config) : Bool
    db = config.db_path
    return true if path == db || path.starts_with?("#{db}-")

    path == config.daemon_socket_path ||
      path == config.daemon_lock_path ||
      path == config.daemon_pid_path
  end

  def self.handle_watch_event(event : FileWatcher::Event, config : Config, store : Store::SQLite,
                              qi : Store::QdrantIndex?, registry : Indexer::Format::Registry,
                              embedder : Indexer::Embedder, sf : SingleFlight) : Nil
    path = event.path
    return if index_artifact?(path, config)

    if event.type.deleted?
      ids = store.chunk_ids_for_file(path)
      store.delete_file(path)
      qi.try(&.delete(ids)) unless ids.empty?
      Log.info { "watch: removed #{path}" }
      return
    end
    return unless registry.supported?(File.extname(path))
    # Cheap after the first success, and the only chance a daemon that started
    # without a reachable model gets to create its collection before writing to
    # it. See ensure_qdrant!.
    qi.try { |index| ensure_qdrant!(index, store) }
    Indexer::Crawler.new([path], registry, config.exclude, qdrant_index: qi)
      .run(store, embedder, sf, concurrency: 1)
    Log.info { "watch: re-indexed #{path}" }
  end

  # Live-watches the configured paths and re-indexes on change while the daemon
  # runs. Builds its own embedder/registry/single-flight (long-lived fiber), then
  # runs FileWatcher in a supervised loop: the shard's poll loop can raise on a
  # stat race during atomic editor saves, so a crash is logged and the watch is
  # restarted after a short backoff. Each event is isolated so a bad one never
  # breaks the loop.
  #
  # *stop* is a shutdown signal: closing it makes the loop return at its next
  # poll. The daemon passes nothing — its watcher is meant to die with the
  # process — but a caller that outlives the store it handed over needs a way to
  # wind the loop down first, or it keeps polling against a closed store and a
  # directory that no longer exists.
  def self.watch_and_index(config : Config, store : Store::SQLite, qi : Store::QdrantIndex?,
                           stop : Channel(Nil)? = nil, sf : SingleFlight = SingleFlight.new) : Nil
    # Typed as the union the file_watcher shard expects (Enumerable(String | Path)).
    patterns = [] of String | Path
    config.resolved_paths.each do |entry|
      patterns << (File.directory?(entry) ? File.join(entry, "**", "*") : entry)
    end
    return if patterns.empty?
    registry = Indexer::Format::Registry.new(config)
    embedder = Indexer::Embedder.new(config.ollama)
    interval = config.server.daemon_watch_interval.seconds
    Log.info { "watch: live re-index over #{patterns.size} path(s), every #{config.server.daemon_watch_interval}s" }
    loop do
      break if stop_requested?(stop)
      begin
        FileWatcher.watch(patterns, interval: interval) do |event|
          # The shard's poll loop has no exit of its own; breaking out of the
          # block is what returns from it, and the check above then ends the
          # supervision loop rather than restarting the watch.
          break if stop_requested?(stop)
          begin
            handle_watch_event(event, config, store, qi, registry, embedder, sf)
          rescue ex
            # The class is part of the message because the exception may carry
            # none: DB::PoolRetryAttemptsExceeded, raised when the index file is
            # gone, logs as a bare colon and says nothing about what happened.
            Log.error { "watch: failed handling #{event.path}: [#{ex.class}] #{ex.message}" }
          end
        end
      rescue ex
        Log.error { "watch loop crashed, restarting: [#{ex.class}] #{ex.message}" }
        sleep 1.second
      end
    end
  end

  # True once the caller has closed the shutdown signal. A nil signal means
  # "run until the process does", which is the daemon's case.
  private def self.stop_requested?(stop : Channel(Nil)?) : Bool
    return false unless stop
    stop.closed?
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

    store = open_store(config)
    # Non-nil binding so the background fiber captures a typed store.
    active_store = store
    qi = qdrant_index(config)

    built = ToolRegistry.build(config, store, qi)
    server = built[:server]
    embedder = built[:embedder]

    # Index configured paths in the background so the server is immediately
    # responsive; unchanged files are skipped via mtime so restarts are cheap.
    # Skipped entirely with no project: there is nothing configured to index,
    # and a globally registered server must not start crawling the directory a
    # session happened to open in.
    spawn { background_index(config, active_store, qi) } if project_initialized?

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

  # Opens the project's index, creating its directory (and, for the derived
  # `.mnemodoc/` location, its .gitignore) beforehand. Single entry point so
  # every caller gets the same preparation and the same vec0 decision: the
  # embedded KNN tables are only needed when Qdrant is not the backend.
  def self.open_store(config : Config) : Store::SQLite
    # An uninitialised project owns no index, and both `prepare_index_dir!` and
    # the store itself create the directory they are given. A globally
    # registered server opens a store in whatever directory a session starts
    # in, so it must serve from memory here: the tools short-circuit before
    # this store is ever read, and nothing lands on disk.
    unless project_initialized?
      return Store::SQLite.new(Store::SQLite::MEMORY, vec0: config.search.backend != "qdrant")
    end
    config.prepare_index_dir!
    Store::SQLite.new(config.db_path, vec0: config.search.backend != "qdrant")
  end

  private def self.default_config : Config
    Config.from_yaml("")
  end

  # Resolves the project and loads its configuration.
  #
  # An explicit `--config` is an unambiguous statement of which project is
  # meant, so it short-circuits discovery and its own directory becomes the
  # project root. Otherwise the project is discovered by walking up from `from`
  # looking for the marker directory.
  private def self.load_config(config_path : String, from : String) : Nil
    if config_path.empty?
      root = discover_project(from)
      @@project_initialized = !root.nil?
      unless root
        Advisories.add("no MnemoDoc project found at or above #{File.expand_path(from)}; run `mnemodoc-server init` to index this project")
        @@config_file = ""
        self.config = default_config
        return
      end
      file = File.join(root, ".mnemodoc.yml")
    else
      @@project_initialized = true
      file = File.expand_path(config_path)
    end

    unless File.exists?(file)
      Advisories.add("no config file found at #{file}; running on default settings — indexed paths may be empty or wrong")
    end
    @@config_file = file
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
