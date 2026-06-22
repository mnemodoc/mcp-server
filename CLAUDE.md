# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Instructions

- Répondre en français.
- Commentaires au-dessus du code (jamais en inline).
- Code, commentaires et descriptions de tests en anglais.
- Named arguments sur les appels complexes.
- Les specs et plans superpowers vont dans `.claude/plans/` (jamais `docs/`, qui est gitignoré et effacé par `mise dev:doc`). Nommage type *serial DNS* : `YYYY-MM-DD-NN-<nom>-<design|plan>.md`, où `NN` est un compteur du jour sur deux chiffres (`01`, `02`, …) incrémenté à chaque nouveau plan. Le design et le plan d'un même sujet partagent date+`NN`.
- Toujours privilégier les tâches `mise` plutôt que les commandes brutes : `mise dev:format` (pas `crystal tool format`), `mise dev:build` (pas `crystal build`), `mise dev:spec` (pas `crystal spec`), etc. Voir les tâches dans `mise.toml`.
- **RÈGLE CRITIQUE** : après *tout* changement de code (même une seule ligne), toujours lancer le `mise dev:check` **complet** (= `mise dev:build && mise dev:ameba && mise dev:spec`). Ne jamais se contenter d'une sous-tâche isolée comme `mise dev:spec` seul.

## Analysis

**Memory is forbidden as a source:** acting or producing anything from memory is **prohibited** — whether training memory or session context. Commands, paths, names, patterns, conventions, behaviors: anything not read from a file or source in the **current turn** is forbidden as the basis for an action or assertion. If the information is not in the current turn: read before acting — never assume. Without a source, say "I don't know" or "I need to read X before responding".

## What this is

`mnemodoc-server` is a Crystal MCP server that indexes project documentation using Ollama embeddings (`nomic-embed-text`) and exposes hybrid search (semantic + keyword) to MCP clients (Claude Code, Cursor). It indexes a broad set of markup, HTML/XML, Office & OpenDocument, e-book and notebook formats — all pure stdlib (no external tool) — plus opt-in PDF via `pdftotext`, through a `Format::Registry` of per-format handlers (the README's "Supported formats" table is the source of truth for the exact extension list). Semantic search runs over the sqlite-vec (vec0) KNN extension, vendored as the `ext/sqlite-vec` git submodule and linked statically. The JSON-RPC/MCP transport layer lives in an external shard (`mnemodoc/mcp.cr`).

**Problem solved:** Replaces the costly `/context-reload` ritual that loads 5-7 large documentation files at each session start. Claude fetches only relevant passages on demand via MCP tools.

**Beyond search — contextual roles:** a role-selection engine (`Roles::Selector`) picks the conventions Claude should adopt for the files/task/query at hand, exposed both as the `get_project_context` MCP tool and the `context` CLI command (the latter drives a `PreToolUse` hook so guidance lands even when the agent doesn't ask). Operational warnings raised at startup are surfaced in every tool response via the `Advisories` module, since `Log.warn` is invisible in some MCP clients.

## Development commands

All tasks run via `mise`:

```sh
mise dev:ollama    # start Ollama (macOS native, Metal GPU) + pull nomic-embed-text
mise docker:ollama # start Ollama via Docker (CPU-only, fallback)
mise dev:deps      # install deps (shards install)
mise dev:spec      # run tests (Spectator)
mise dev:ameba     # lint (static analysis)
mise dev:format    # format code (crystal tool format src/)
mise dev:vec0-objects # generate sqlite-vec.h + compile the submodule objects (macOS dev)
mise dev:build     # compile dev binary to bin/mnemodoc-server (depends on dev:vec0-objects)
mise dev:check     # build + ameba + spec in one shot
```

`dev:build` depends on `dev:vec0-objects`: the semantic search backend links against the **upstream sqlite-vec submodule** in `ext/sqlite-vec/` (pinned to `v0.1.9`). The task regenerates `sqlite-vec.h` from the template (`envsubst`), then compiles `sqlite-vec.c` (with `-DSQLITE_CORE`) plus our registration shim `vendor/vec0_shim.c` into `.o` objects under `vendor/`, so the vec0 KNN extension is available on every SQLite connection. The `.c` is compiled through a small generated copy (`vendor/sqlite-vec.patched.c`) that strips three non-portable BSD typedefs which break on musl — see the bump note in Deployment. Clone with `git submodule update --init`.

Run a single spec file:
```sh
crystal spec spec/config_spec.cr
```

Release builds (static binaries) use Docker:
```sh
mise release:static   # builds static Linux binaries via docker buildx bake
```

## Architecture

The JSON-RPC 2.0 / MCP transport (stdio + HTTP) is **not in this repo**: it lives in the external `mcp` shard (`mnemodoc/mcp.cr`, see `shard.yml`) and is used here as `MCP::Server`, `MCP::Stdio`, `MCP::Http`, `MCP::ToolResult`, and `MCP::ToolAnnotations`.

```
src/mnemodoc-server.cr              Entry point: init_app!, CLI.run
src/mnemodoc_server/
  cli.cr                           Admiral CLI — subcommands: serve, index, search, status, delete, context, info
  config.cr                        YAML config + apply_env! + validate! (Ollama/Search/Server/Db/Index/Qdrant/Role/Context configs); daemon_socket_path / daemon_lock_path
  daemon.cr                        Per-project daemon: owns the SQLite index, spawns background indexing + a live file-watch (watch_and_index), serves MCP over a UNIX socket, self-exits when idle
  daemon_proxy.cr                  Default `serve --stdio` path when server.daemon is true: auto-spawns the daemon (flock-serialised), forwards JSON-RPC over the UNIX socket, self-heals on daemon death (≤3 attempts), falls back to in-process standalone on exhaustion
  helpers.cr                       version (shard version + git ref, compile-time), format_bytes
  systemd.cr                       systemd sd_notify (READY=1, STOPPING=1, watchdog)
  single_flight.cr                 Concurrent deduplication via Channel + Mutex
  connection_pool.cr               Per-host HTTP connection pool (for Ollama calls)
  chunk.cr                         Chunk struct + FileInfo struct
  advisories.cr                    Persistent startup advisories, surfaced in every tool response
  tool_registry.cr                 Builds the MCP::Server, registers the 6 tools + JSON Schemas, wraps results with advisories
  indexer/
    crawler.cr                     File/dir scanner + mtime change detection + parallel orchestration (registry dispatch)
    embedder.cr                    Ollama HTTP embeddings client (batch, EmbedderError)
    sectionizer.cr                 Heading-stack accumulator → Sections (shared by line/DOM handlers)
    section.cr                     Section struct (heading, parent_heading, body)
    chunk_assembler.cr             Format-agnostic Sections → Chunks: token budget, oversized splitting, TOC filtering, opt-in link-only-line strip (Markdown/Org/AsciiDoc/RST; no-op on DOM/Office) / preamble merge
    format/
      handler.cr                   Handler interface (read + parse → Chunks; never raises on content/IO)
      registry.cr                  Extension → handler dispatch; discovered-vs-named rule; plain-text fallback; opt-in PDF
      markdown.cr                  Markdown / MDX (## / ### headings, YAML frontmatter stripping)
      org.cr                       Org-mode (leading-star headings)
      asciidoc.cr                  AsciiDoc (leading-equals headings)
      rst.cr                       reStructuredText (adornment-line titles)
      html.cr                      HTML (DOM walk over <h1>..<h6>)
      notebook.cr                  Jupyter .ipynb (flatten to pseudo-Markdown, reuse Markdown parsing)
      plain.cr                     Plain text (.txt) + registry fallback for unknown explicit extensions
      pdf.cr                       PDF via external pdftotext (opt-in, degrades to skip)
      zipped.cr                    Base for ZIP-of-XML formats (Compress::Zip + XML, stdlib, never-raise); on by default
      docx.cr                      Word .docx (word/document.xml paragraphs)
      odt.cr                       LibreOffice/ODF text .odt (content.xml)
      pptx.cr                      PowerPoint .pptx (ppt/slides/slideN.xml in order)
      odp.cr                       LibreOffice/ODF presentation .odp (content.xml, one headingless section)
      epub.cr                      EPUB .epub (ZIP of XHTML chapters, reuses the HTML handler)
      fodt.cr                      Flat-XML ODF text .fodt (single XML, no ZIP)
      fodp.cr                      Flat-XML ODF presentation .fodp (single XML, no ZIP)
      nested_xml.cr                Base module for nested-section XML; namespace-agnostic Sections from title/paragraph elements
      docbook.cr                   DocBook .dbk/.docbook (via nested_xml)
      dita.cr                      DITA .dita topics (via nested_xml)
      fictionbook.cr               FictionBook .fb2 (via nested_xml)
  store/
    sqlite.cr                      SQLite store (WAL) — files/chunks/meta, embeddings as blobs, vec0 KNN, write mutex
    sqlite_vec.cr                  LibVec binding to the ext/sqlite-vec submodule (vec0), registered per connection
    qdrant_index.cr                Best-effort QdrantIndex over qdrant-client (opt-in semantic backend; replaces vec0 when search.backend=qdrant)
  search/
    semantic.cr                    Dot-product / cosine scoring — in-memory linear, vec0 KNN, and Qdrant KNN overloads
    keyword.cr                     FTS5/BM25 keyword search (query tokenized in Crystal, ranked per file by the store)
    hybrid.cr                      RRF fusion + recency bias (SearchResult)
  roles/
    role.cr                        Role at runtime (config + resolved path; markdown read lazily and cached)
    selector.cr                    Contextual-role selection (B3 cascade: weighted rules + semantic tie-break)
  tools/
    query.cr                       query_documents MCP tool
    ingest.cr                      ingest_path MCP tool
    list.cr                        list_files MCP tool
    delete.cr                      delete_file MCP tool
    status.cr                      status MCP tool
    context.cr                     get_project_context MCP tool (delegates to Roles::Selector)
```

### Daemon / proxy

**Problem solved:** when multiple MCP clients (Zed, parallel `claude-agent` sessions) each launch `serve --stdio`, each one used to open the same `index.db` and trigger a background re-index at boot — N processes competing on the same SQLite index. Now ONE daemon per project owns the index; every `serve --stdio` invocation is a thin proxy to it. Clients are unchanged.

**Daemon** (`daemon.cr`): launched internally by `serve --daemon`. It opens `Store::SQLite`, starts background indexing in a fiber, then binds `MCP::Http` on a UNIX domain socket at `<project dir>/daemon.sock` (beside the index DB). It wires SIGTERM → graceful stop and SIGUSR1 → log rotation. After `server.daemon_idle_timeout` seconds of inactivity the transport self-exits; the next `serve --stdio` auto-respawns it. Crash-safety rests on SQLite WAL and the per-file atomic indexing convention. **Live re-indexing:** when `server.daemon_watch` is set (default), the daemon also spawns `MnemodocServer.watch_and_index` — a supervised fiber that polls the configured paths (via the `file_watcher` shard, `server.daemon_watch_interval` seconds) and re-indexes a single file on add/change (through the crawler) or removes it on delete. Only the daemon watches; the standalone stdio path does not.

**Proxy** (`daemon_proxy.cr`): the default `serve --stdio` path when `server.daemon` is true. On startup it checks `GET /health` over the socket; if the daemon is not running it acquires an exclusive advisory lock on `<project dir>/daemon.lock`, removes any stale socket, spawns the daemon process fully detached (no shared stdio), and polls `/health` until it answers (up to 30 s). The flock prevents double-spawn when multiple clients start simultaneously. For each stdin line the proxy opens a fresh UNIX connection, POSTs to `/mcp`, and writes the reply to stdout, with up to 32 concurrent requests in flight. On a connection failure it self-heals under the flock (up to 3 attempts total). A replayed `delete_file` whose response is "not found in index" is rewritten to a success — the file was likely already deleted before the daemon died. If healing is exhausted the whole remaining session falls back to a lazily-built in-process standalone handler (which does **not** re-index, to avoid a multi-process indexing storm). A startup failure (daemon never becomes healthy) also falls back to the in-process standalone.

## MCP tools exposed

| Tool | Description |
|---|---|
| `query_documents` | Hybrid search — returns top-K relevant chunks |
| `ingest_path` | Index a file or directory |
| `list_files` | List indexed files with metadata |
| `delete_file` | Remove a file from the index |
| `status` | Server status: chunk count, Ollama config, version |
| `get_project_context` | Select the role to adopt for the current files/task/query; returns the role's markdown + structured `role`/`reason`/`candidates` |

## Config file format

Default: `.mnemodoc.yml` (override with `--config`/`-c`).

Relative `paths` and the auto DB location are resolved against the **config file's directory**, not the process CWD.

```yaml
paths:
  - doc/claude/
  - app/

exclude:                # glob patterns (matched on absolute paths) skipped during indexing
  - "**/templates/**"

ollama:
  host: http://localhost:11434
  model: nomic-embed-text
  timeout: 30
  batch_size: 10

search:
  top_k: 5
  mode: hybrid        # hybrid | semantic | keyword
  backend: vec0       # semantic KNN backend: vec0 (embedded, default) | qdrant (opt-in)
  recency_days: 7
  recency_boost: 0.1  # multiplicative boost for files modified within recency_days
  keyword_weight: 0.3 # weight of keyword signal relative to semantic (1.0) in RRF fusion

qdrant:               # required when search.backend: qdrant; SQLite stays the source of truth
  url: https://my-qdrant:6333  # Qdrant endpoint (api-key header auth, not bearer)
  api_key:                     # optional; or env QDRANT_API_KEY
  collection:                  # optional; default = the project key (basename-hash), like db_path

index:
  concurrency: 4      # parallel files embedded at once (>= 1)
  pdf: false          # opt-in; requires pdftotext in PATH

chunking:             # optional noise reduction; both default false (index unchanged). Re-index after changing.
  strip_link_only_lines: false             # drop pure breadcrumb lines (links + separators only); line-based markup only (Markdown/Org/AsciiDoc/RST), no-op on DOM/Office
  merge_preamble_into_first_section: false # fold the pre-heading preamble into the first section chunk

context:              # optional — contextual-role selection (get_project_context tool + `context` CLI)
  default: doc/claude/roles/generalist.md  # fallback role when no rule fires and there is no signal
  roles:
    - file: doc/claude/roles/backend.md    # markdown instructions; path resolved like `paths`
      description: Backend conventions      # used only for the semantic tie-break
      when_files: ["app/models/**", "app/policies/**"]  # glob triggers (File.match? on the path)
      when_task:  ["implement", "refactor"]             # substring triggers on the task kind
      when_query: ["operation", "policy"]               # substring triggers on the user query

server:
  sse_host: 127.0.0.1 # SSE bind address; UNAUTHENTICATED — use 0.0.0.0 only to expose deliberately
  sse_port: 8765
  log_file: stderr    # stderr | stdout | /path/to/file.log
  log_level: info     # trace | debug | info | warn | error | fatal | off
  daemon: true        # false → serve --stdio runs standalone (no per-project background daemon)
  daemon_idle_timeout: 600  # seconds of inactivity before the daemon self-exits (>= 1)
  daemon_watch: true        # live re-index changed files while the daemon runs (polling)
  daemon_watch_interval: 1  # poll interval in seconds (>= 1)

db:
  # default: ~/.local/share/mnemodoc-server/<project>-<hash>/index.db
  # (project name + hash of the config file's absolute directory, so same-named projects don't collide)
  # path: /custom/path/to/index.db
```

## Environment variable overrides

All settings can be overridden at runtime without editing the YAML file:

| Variable | Config key |
|---|---|
| `MNEMODOC_OLLAMA_HOST` | `ollama.host` |
| `MNEMODOC_OLLAMA_MODEL` | `ollama.model` |
| `MNEMODOC_OLLAMA_TIMEOUT` | `ollama.timeout` |
| `MNEMODOC_OLLAMA_BATCH_SIZE` | `ollama.batch_size` |
| `MNEMODOC_SEARCH_TOP_K` | `search.top_k` |
| `MNEMODOC_SEARCH_MODE` | `search.mode` |
| `MNEMODOC_SEARCH_BACKEND` | `search.backend` |
| `MNEMODOC_QDRANT_URL` | `qdrant.url` |
| `MNEMODOC_QDRANT_API_KEY` | `qdrant.api_key` |
| `MNEMODOC_QDRANT_COLLECTION` | `qdrant.collection` |
| `MNEMODOC_SEARCH_RECENCY_DAYS` | `search.recency_days` |
| `MNEMODOC_SEARCH_RECENCY_BOOST` | `search.recency_boost` |
| `MNEMODOC_SEARCH_KEYWORD_WEIGHT` | `search.keyword_weight` |
| `MNEMODOC_SERVER_SSE_HOST` | `server.sse_host` |
| `MNEMODOC_SERVER_SSE_PORT` | `server.sse_port` |
| `MNEMODOC_SERVER_LOG_FILE` | `server.log_file` |
| `MNEMODOC_SERVER_LOG_LEVEL` | `server.log_level` |
| `MNEMODOC_SERVER_DAEMON` | `server.daemon` |
| `MNEMODOC_SERVER_IDLE_TIMEOUT` | `server.daemon_idle_timeout` |
| `MNEMODOC_SERVER_DAEMON_WATCH` | `server.daemon_watch` |
| `MNEMODOC_SERVER_WATCH_INTERVAL` | `server.daemon_watch_interval` |
| `MNEMODOC_DB_PATH` | `db.path` |
| `MNEMODOC_INDEX_CONCURRENCY` | `index.concurrency` |
| `MNEMODOC_INDEX_PDF` | `index.pdf` |
| `MNEMODOC_CHUNKING_STRIP_LINK_ONLY_LINES` | `chunking.strip_link_only_lines` |
| `MNEMODOC_CHUNKING_MERGE_PREAMBLE` | `chunking.merge_preamble_into_first_section` |
| `MNEMODOC_EXCLUDE` | `exclude` (comma-separated patterns) |

## Claude Code integration

stdio is the default transport (`--sse` switches to HTTP), so `--stdio` is optional:

```json
{
  "mcpServers": {
    "doc": {
      "command": "/usr/local/bin/mnemodoc-server",
      "args": ["serve", "--config", "/path/to/project/.mnemodoc.yml"]
    }
  }
}
```

## Testing

Uses [Spectator](https://gitlab.com/arctic-fox/spectator). Test environment detected via `crystal-env` — `Crystal.env.test?` is true when running specs.

Key spec files:
- `spec/config_spec.cr` — YAML parsing, apply_env!, validate!
- `spec/sectionizer_spec.cr` — heading-stack section building
- `spec/chunk_assembler_spec.cr` — Sections → Chunks, token budget, oversized splitting, TOC filtering
- `spec/format/*_spec.cr` — one per handler: markdown, org, asciidoc, rst, html, notebook, plain, pdf, plus registry dispatch
- `spec/embedder_spec.cr` — Ollama mock server, batch, error handling
- `spec/sqlite_spec.cr` — store/retrieve chunks, DELETE CASCADE, vec0 KNN
- `spec/search_spec.cr` — cosine similarity, RRF, recency boost
- `spec/crawler_spec.cr` — file scanning, mtime-based change detection
- `spec/role_spec.cr` / `spec/selector_spec.cr` — role loading + B3 selection cascade
- `spec/cli_context_spec.cr` — `context` subcommand end to end
- `spec/advisories_spec.cr` — advisory collection + dedup
- `spec/single_flight_spec.cr` — concurrent deduplication
- `spec/tools_spec.cr` — MCP tool behavior
- `spec/integration_spec.cr` — end-to-end indexing + search

## Deployment

Static binaries built via Docker (`docker-bake.hcl`); the build compiles the `ext/sqlite-vec` submodule and links it statically, so no SQLite extension is loaded at runtime. Runtime image: distroless. Requires Ollama running separately (Docker Desktop or native).

**Bumping sqlite-vec:** `git -C ext/sqlite-vec fetch --tags && git -C ext/sqlite-vec checkout <tag>`, then `git add ext/sqlite-vec && mise dev:check`. The header and objects are regenerated/recompiled by `dev:vec0-objects`.

- **musl patch:** the build strips three non-portable BSD typedefs (`typedef u_int8_t uint8_t;` …) from `sqlite-vec.c` into a generated `vendor/sqlite-vec.patched.c`; they are undefined on musl and break the Alpine build. If a future tag removes/changes those lines the `sed` simply becomes a no-op (safe), but check the Alpine build after a bump.
- **multi-file split since v0.1.9:** at `v0.1.9` the whole extension is the single `sqlite-vec.c`. Newer releases split it into extra translation units (`sqlite-vec-ivf.c`, `sqlite-vec-diskann.c`, …). The build compiles **only `sqlite-vec.c`**, so bumping to such a version would silently produce an *incomplete* extension (link succeeds, features missing). Before any bump run `ls ext/sqlite-vec/sqlite-vec*.c`; if extra `.c` files appear, add each to the `cc` step in `dev:vec0-objects` (mise.toml) and the `vec0:` target (Makefile.release).

In SSE mode the HTTP transport exposes `GET /health` (returns `200 OK`) for liveness probes, and `SIGUSR1` reopens the log file for `logrotate`.
