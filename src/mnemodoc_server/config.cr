require "digest/sha1"

module MnemodocServer
  # Ollama connection settings and batching for embedding generation.
  class OllamaConfig
    include YAML::Serializable

    property host : String = "http://localhost:11434"
    property model : String = "nomic-embed-text"
    property timeout : Int32 = 30
    property batch_size : Int32 = 10
  end

  # Search behaviour: result count, fusion mode, keyword weight, recency.
  class SearchConfig
    include YAML::Serializable

    property top_k : Int32 = 5
    property mode : String = "hybrid"
    # Semantic KNN backend: vec0 (embedded sqlite-vec, default) or qdrant
    # (opt-in remote/scalable index). See QdrantConfig.
    property backend : String = "vec0"
    property recency_days : Int32 = 7
    # Recency nudge applied multiplicatively: recent files score ×(1 + boost).
    property recency_boost : Float64 = 0.1
    # Weight of the keyword signal relative to semantic (1.0) in fusion.
    property keyword_weight : Float64 = 0.3
  end

  # Server runtime settings: SSE bind address/port, logging, and daemon mode.
  class ServerConfig
    include YAML::Serializable

    # Bind address for the SSE transport. Defaults to loopback so the
    # unauthenticated HTTP endpoint is not exposed on the network; set to
    # "0.0.0.0" only when you intentionally want remote access.
    property sse_host : String = "127.0.0.1"
    property sse_port : Int32 = 8765
    property log_file : String = "stderr"
    property log_level : String = "info"
    # When true (default), `serve --stdio` starts a per-project background daemon
    # and connects via a stdio proxy; set to false to run standalone (no daemon).
    property? daemon : Bool = true
    # Seconds of client inactivity after which the daemon self-exits to free
    # resources. Must be >= 1.
    property daemon_idle_timeout : Int32 = 600
  end

  # Database location. An empty path means "derive from the project" (see
  # Config#db_path), so each project gets an isolated index by default.
  class DbConfig
    include YAML::Serializable

    property path : String = ""
  end

  # Indexing settings; concurrency caps how many files are embedded in parallel.
  class IndexConfig
    include YAML::Serializable

    property concurrency : Int32 = 4
    # Enables PDF indexing via the external `pdftotext` binary. Off by default:
    # pdftotext is not bundled, so PDF support is opt-in and degrades to a skip
    # when the binary is absent.
    property? pdf : Bool = false
  end

  # Chunking behaviours that reduce navigation/preamble noise in the index.
  # Both default to false, so without a `chunking:` section the produced index
  # is byte-for-byte identical to the previous behaviour (strict back-compat).
  class ChunkingConfig
    include YAML::Serializable

    # Drop lines made up solely of inline links and separators (breadcrumbs)
    # before chunking, so a pure navigation line never forms a parasite chunk.
    # Covers the line-based markup formats (Markdown, Org, AsciiDoc, RST); a
    # no-op for DOM/Office formats, which flatten links to plain text.
    property? strip_link_only_lines : Bool = false
    # Merge the preamble (text before the first heading) into the first section
    # chunk instead of emitting it as a standalone chunk, so a lone description
    # never becomes an orphan chunk.
    property? merge_preamble_into_first_section : Bool = false
  end

  # Qdrant connection settings, used only when search.backend == "qdrant".
  # `collection` defaults (when empty) to the project-derived key, so two
  # same-named projects on a shared Qdrant don't collide.
  class QdrantConfig
    include YAML::Serializable

    property url : String = ""
    property api_key : String? = nil
    property collection : String = ""
  end

  # One role declaration: a markdown file plus trigger lists on three axes
  # (files, task, query). description is used only for the semantic tie-break.
  class RoleConfig
    include YAML::Serializable

    property file : String = ""
    property description : String = ""
    property when_files : Array(String) = [] of String
    property when_task : Array(String) = [] of String
    property when_query : Array(String) = [] of String

    # Programmatic constructor used to build the optional default role, which is
    # declared in YAML as a bare path rather than a full role entry.
    def initialize(@file = "", @description = "", @when_files = [] of String,
                   @when_task = [] of String, @when_query = [] of String)
    end
  end

  # Contextual-role section: an optional fallback role plus the candidate roles.
  class ContextConfig
    include YAML::Serializable

    property default : String? = nil
    property roles : Array(RoleConfig) = [] of RoleConfig
  end

  # Top-level configuration loaded from YAML, with environment overrides and
  # validation. Nested sections each have their own defaults.
  class Config
    include YAML::Serializable

    property paths : Array(String) = ["doc/claude/", "app/"]

    # Directory of the config file; not persisted to YAML. When set, relative
    # paths in `paths` and the auto DB location are resolved against it instead
    # of Dir.current.
    @[YAML::Field(ignore: true)]
    property source_dir : String? = nil
    # Glob patterns matched against absolute file paths; matching files are
    # excluded from indexing. An empty list means no files are excluded.
    property exclude : Array(String) = [] of String
    property ollama : OllamaConfig = OllamaConfig.from_yaml("")
    property search : SearchConfig = SearchConfig.from_yaml("")
    property server : ServerConfig = ServerConfig.from_yaml("")
    property db : DbConfig = DbConfig.from_yaml("")
    property index : IndexConfig = IndexConfig.from_yaml("")
    property chunking : ChunkingConfig = ChunkingConfig.from_yaml("")
    property context : ContextConfig = ContextConfig.from_yaml("")
    property qdrant : QdrantConfig = QdrantConfig.from_yaml("")

    # Overrides selected fields from MNEMODOC_* environment variables, letting
    # deployments tweak settings without editing the YAML file.
    def apply_env!(env : Hash(String, String) = ENV.to_h) : Nil
      env["MNEMODOC_OLLAMA_HOST"]?.try { |v| @ollama.host = v }
      env["MNEMODOC_OLLAMA_MODEL"]?.try { |v| @ollama.model = v }
      env["MNEMODOC_OLLAMA_TIMEOUT"]?.try { |v| @ollama.timeout = v.to_i }
      env["MNEMODOC_OLLAMA_BATCH_SIZE"]?.try { |v| @ollama.batch_size = v.to_i }
      env["MNEMODOC_SEARCH_TOP_K"]?.try { |v| @search.top_k = v.to_i }
      env["MNEMODOC_SEARCH_MODE"]?.try { |v| @search.mode = v }
      env["MNEMODOC_SEARCH_BACKEND"]?.try { |v| @search.backend = v }
      env["MNEMODOC_QDRANT_URL"]?.try { |v| @qdrant.url = v }
      env["MNEMODOC_QDRANT_API_KEY"]?.try { |v| @qdrant.api_key = v }
      env["MNEMODOC_QDRANT_COLLECTION"]?.try { |v| @qdrant.collection = v }
      env["MNEMODOC_SEARCH_RECENCY_DAYS"]?.try { |v| @search.recency_days = v.to_i }
      env["MNEMODOC_SEARCH_RECENCY_BOOST"]?.try { |v| @search.recency_boost = v.to_f }
      env["MNEMODOC_SEARCH_KEYWORD_WEIGHT"]?.try { |v| @search.keyword_weight = v.to_f }
      env["MNEMODOC_SERVER_SSE_HOST"]?.try { |v| @server.sse_host = v }
      env["MNEMODOC_SERVER_SSE_PORT"]?.try { |v| @server.sse_port = v.to_i }
      env["MNEMODOC_SERVER_LOG_FILE"]?.try { |v| @server.log_file = v }
      env["MNEMODOC_SERVER_LOG_LEVEL"]?.try { |v| @server.log_level = v }
      env["MNEMODOC_SERVER_DAEMON"]?.try { |v| @server.daemon = v.downcase == "true" }
      env["MNEMODOC_SERVER_IDLE_TIMEOUT"]?.try { |v| v.to_i?.try { |secs| @server.daemon_idle_timeout = secs } }
      env["MNEMODOC_DB_PATH"]?.try { |v| @db.path = v }
      env["MNEMODOC_INDEX_CONCURRENCY"]?.try { |v| @index.concurrency = v.to_i }
      env["MNEMODOC_INDEX_PDF"]?.try { |v| @index.pdf = v == "true" }
      env["MNEMODOC_CHUNKING_STRIP_LINK_ONLY_LINES"]?.try { |v| @chunking.strip_link_only_lines = v.downcase == "true" }
      env["MNEMODOC_CHUNKING_MERGE_PREAMBLE"]?.try { |v| @chunking.merge_preamble_into_first_section = v.downcase == "true" }
      env["MNEMODOC_EXCLUDE"]?.try { |v| @exclude = v.split(',').map(&.strip).reject(&.empty?) }
    end

    # Raises ArgumentError listing every validation problem at once.
    def validate! : Nil
      errors = collect_errors
      raise ArgumentError.new(errors.join("; ")) unless errors.empty?
    end

    # Resolves a role/context file path: an absolute path is kept unchanged; a
    # relative path is resolved against the config file's directory when set,
    # otherwise against Dir.current.
    def resolve_context_path(raw : String) : String
      return File.expand_path(raw) if Path[raw].absolute?
      File.expand_path(raw, source_dir || Dir.current)
    end

    # Resolves the log destination. "stderr"/"stdout"/"" are returned unchanged
    # (handled as streams by the logger); a relative file path is resolved against
    # the config file's directory, an absolute path is kept as-is.
    def log_file_path : String
      raw = @server.log_file
      return raw if raw.downcase.in?("stderr", "stdout", "")
      return File.expand_path(raw) if Path[raw].absolute?
      File.expand_path(raw, source_dir || Dir.current)
    end

    # Expands each entry in `paths`: absolute paths are kept unchanged; relative
    # paths are resolved against `source_dir` when set, otherwise against
    # Dir.current. This ensures the server indexes the right directories
    # regardless of the process working directory.
    def resolved_paths : Array(String)
      base = source_dir || Dir.current
      @paths.map do |entry|
        Path[entry].absolute? ? File.expand_path(entry) : File.expand_path(entry, base)
      end
    end

    # Resolves the database file: an explicit path (with ~ expansion) or, when
    # unset, an XDG location derived from the config file's directory name plus
    # a short SHA-1 hash to avoid collisions between projects sharing a basename.
    def db_path : String
      return auto_db_path if @db.path.empty?
      File.expand_path(@db.path.gsub("~", Path.home.to_s))
    end

    # Path to the Unix domain socket used by the per-project daemon. Lives beside
    # the index DB so it is scoped to the same project directory.
    def daemon_socket_path : String
      File.join(File.dirname(db_path), "daemon.sock")
    end

    # Path to the lock file that guards singleton daemon startup. Lives beside
    # the index DB so it is scoped to the same project directory.
    def daemon_lock_path : String
      File.join(File.dirname(db_path), "daemon.lock")
    end

    # Default per-project database under ~/.local/share. Keyed by basename AND
    # a short hash of the absolute source directory so two projects named the
    # same on disk get distinct databases.
    private def auto_db_path : String
      (Path.home / ".local" / "share" / "mnemodoc-server" / project_key / "index.db").to_s
    end

    # Per-project key (basename + short hash of the config dir), shared by the
    # auto DB location and the default Qdrant collection name so two same-named
    # projects stay isolated.
    private def project_key : String
      abs = File.expand_path(source_dir || Dir.current)
      "#{Path[abs].basename}-#{Digest::SHA1.hexdigest(abs)[0, 8]}"
    end

    # The Qdrant collection to use: the configured name, or the project key when
    # unset. Only meaningful when search.backend == "qdrant".
    def qdrant_collection : String
      @qdrant.collection.empty? ? project_key : @qdrant.collection
    end

    # Gathers all validation errors so the caller can report them together.
    private def collect_errors : Array(String)
      errors = [] of String
      errors << "paths must not be empty" if @paths.empty?
      errors << "search.mode must be hybrid|semantic|keyword" unless @search.mode.in?("hybrid", "semantic", "keyword")
      errors << "search.backend must be vec0|qdrant" unless @search.backend.in?("vec0", "qdrant")
      errors << "qdrant.url is required when search.backend is qdrant" if @search.backend == "qdrant" && @qdrant.url.empty?
      errors << "server.sse_port must be 1-65535" unless @server.sse_port.in?(1..65535)
      errors << "server.daemon_idle_timeout must be >= 1" unless @server.daemon_idle_timeout >= 1
      errors << "index.concurrency must be >= 1" unless @index.concurrency >= 1
      begin
        ::Log::Severity.parse(@server.log_level)
      rescue ArgumentError
        errors << "server.log_level '#{@server.log_level}' is invalid"
      end
      errors
    end
  end
end
