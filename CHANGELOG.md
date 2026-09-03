# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-09-03

### Added
- **The vector width is now a property of the index, measured and reported.**
  It is taken from an embedding the configured model really produced, recorded
  as `meta.embedding_dim` beside `embedding_model`, and used to create the
  sqlite-vec table. There is deliberately no `ollama.dimensions:` setting: the
  width belongs to the model, and a second knob beside `ollama.model` would be
  one more source of truth to desynchronise — a model → dimension table was
  rejected for the same reason, since it would lie the day a model is
  re-released at another size. `status` reports it, as `embedding_dim` in the
  MCP tool and in `--json`, and as a `Vectors:` line in the text output; it is
  null while nothing has been embedded, and the key is always present so a
  reader can tell "no vectors yet" from an older payload that never carried it

### Changed
- **A model change is now refused rather than answered.** `query_documents` and
  `mnemodoc-server search` fail with an explicit message in `hybrid` and
  `semantic` modes instead of returning results with a warning beside them:
  those results were ranked by the keyword signal alone while still calling
  themselves hybrid, which is indistinguishable, to whatever asked, from a
  working search. `keyword` mode still answers — it touches no vector — and
  says what its answer is missing, on both surfaces. `index` and `ingest_path`
  refuse for the same reason, rather than half-refilling an index whose stored
  vectors are stale

### Fixed
- **A model whose vectors are a different width produced an index with no
  vectors at all.** The sqlite-vec virtual table was declared `float[768]` in
  the schema constant, so switching to a 1024-dimension model skipped every
  vector insert, logged one WARN per chunk, exited 0, and left an index that
  listed its files and answered `query_documents` with its keyword index alone.
  Measured on a real corpus: 1 221 skipped inserts and a healthy-looking index.
  sqlite-vec freezes the width in the table definition and offers no `ALTER`,
  so a change of model is a destroy-recreate-re-embed cycle and the code now
  treats it as one — `clear_index!` drops the table rather than emptying it,
  since emptying would keep the width of the model being replaced and the
  rebuild would meet a table frozen at the old size
- **The daemon crashed on shutdown whenever a fiber still held the index.**
  `run_internal` spawns four fibers that query the store — the boot crawl, the
  watcher, the usage listener and its periodic sweep — and the teardown closed
  the database without waiting for any of them. Closing a `DB::Database` under
  a live fiber is a use-after-free in libsqlite3: it kills the process instead
  of raising, so no `rescue` sees it and no assertion fails. Three separate CI
  crashes, one in each of three of those fibers, were all this defect. The
  watcher was also spawned without the stop channel it has always accepted, so
  it could not end at all. All four now report as they unwind, the teardown
  waits for them, and it declines to close the index when the wait times out —
  leaking a handle in an exiting process costs nothing, while closing it under
  a live fiber is the crash itself
- **The daemon reported itself ready before its usage socket was bound.**
  Readiness fired off the MCP socket alone, which promises nothing about the
  journal's own, so a producer sending an event immediately after startup could
  find nothing listening and spool instead. Both sockets are now bound before
  the daemon announces itself, bounded — an unavailable journal must degrade
  the journal, not the daemon
- **`search --mode keyword` said nothing about an index built by another
  model.** The warning existed only inside `Tools::Query`: the CLI reimplements
  the search path rather than delegating to the tool, so the sentence was never
  written there and the table came back as though the index were current, on
  stdout, on stderr and in `--json` alike. It now lives in one place both
  surfaces call, carried in a `warnings` array that is present and empty when
  there is nothing to say, and printed to stderr in the human output so stdout
  stays the results
- **`search --mode keyword` required Ollama to be reachable.** The command
  embedded its query before looking at the mode, so it failed outright whenever
  the service was down — in the one mode that reads no vector, and the very
  fallback the mismatch message recommends. Keyword search now makes no network
  call at all and answers from the FTS5 index alone

## [1.3.1] - 2026-08-07

### Fixed
- **Keyword-only search buried the corpus's best match under smaller, weaker
  files.** A file's BM25 keyword mass was split evenly across all its chunks,
  so a rare term concentrated in one chunk of a many-chunk file scored, per
  chunk, below a small file that mentioned a query term once — the best keyword
  match in the corpus never surfaced. The file's best-matching chunk (the one
  BM25 ranked highest) now receives the full mass, so files rank by keyword
  relevance, one representative chunk each. The fix is confined to keyword-only
  mode: hybrid mode keeps the even split, because it reinforces whichever chunk
  the semantic signal surfaced and `keyword_weight` caps the mass well below any
  semantic contribution — a boost there could not lift a lexical-only chunk into
  the results and only perturbed the prompt hook's top passage

## [1.3.0] - 2026-08-02

### Fixed
- **A truncated pipe answered with a stack trace.** `mnemodoc-server info |
  head -1`, or quitting `| less` halfway, printed a full `IO::Error (Broken
  pipe)` backtrace on stderr and exited non-zero. Crystal's runtime ignores
  SIGPIPE, so the write comes back `EPIPE` and raises rather than killing the
  process, and the entry point's catch-all treated that like any other crash.
  A reader walking away is not a failure of this program: the process now exits
  0 in silence, matched on the errno rather than on a message. Every other
  exception keeps its backtrace
- **The `PreToolUse` role injection never reached the model.** `context
  --hook-stdin` printed the role markdown on raw stdout for every event, but a
  `PreToolUse` hook's stdout is sent to the client's debug journal and dropped —
  only `hookSpecificOutput.additionalContext` is read as context. The role was
  computed, printed and thrown away, with exit 0 and nothing in any log to show
  for it, so the files channel of the context layer had been inoperative since
  it shipped. The output shape now follows the event: `PreToolUse` gets the JSON
  envelope, `UserPromptSubmit`, an unknown event and the flags-only invocation
  keep the raw markdown that already worked

### Changed
- **`--version` now names itself and says which platform it is.**
  `1.2.0 (d86b19d8)` becomes `mnemodoc-server 1.2.0 (d86b19d8-dirty,
  linux/amd64)`: a bare version number is unattributable once pasted out of the
  inventory table that named it, the platform settles a wrongly pulled image
  between the `amd64` and `arm64` static binaries, and `-dirty` closes the one
  hole that made the string *false* rather than incomplete — a binary built
  from a patched working tree used to report exactly what a pristine release
  reports. The MCP `serverInfo` and the `status` tool keep the nameless
  provenance string, `name` being a field of their own there
- **`info` decomposes the provenance instead of folding it into one string**,
  and gains `commit`, `tag` (`git describe --tags`, which catches a `shard.yml`
  version drifting from the tag actually built), `built` and `target` — in the
  text block and in `--json` alike. Its `version` field is now the bare shard
  version, the rest having its own key; the `version` field of `status` is
  unchanged
- **A hook payload with no signal no longer yields a role.** Empty stdin,
  malformed JSON, or a well-formed payload for an unhandled event all reached
  the selector with every channel empty and came back with the configured
  `context.default` role — a plausible, unfounded context delivered with exit 0.
  Under `--hook-stdin`, an input carrying no file, task or query now prints
  nothing, exits 0, and logs one `info` line saying so (the only trace the case
  leaves, since the exit code stays 0). Manual invocation without
  `--hook-stdin` is untouched: a human asking for the default role still gets
  it, and `--json` still emits its diagnostic payload, with `suppressed: true`

## [1.2.0] - 2026-08-02

### Added
- `outline_document` and `read_document`, with the `outline` and `read`
  subcommands behind them: a document's heading plan, then a numbered window of
  it. The middle ground between the scattered passages `query_documents` returns
  and re-reading a whole file
- Each document's text and heading plan are stored at index time, so a read
  serves the very copy the returned passages were built from and can never land
  on a different revision. `verbatim` says whether the line numbers are the
  file's own or MnemoDoc's extraction, which for Office, PDF, EPUB, notebooks
  and HTML they are
- A usage journal: every call that serves a document is recorded — MCP tools,
  the equivalent subcommands, and the prompt hook including the times it chose
  to stay silent — with `mnemodoc-server usage` reporting a summary, the served
  documents, the indexed ones never served, and the searches that came back
  empty. **It stores the full text of queries and prompts**, in `.mnemodoc/`,
  which ignores itself; entries older than `usage.retention_days` (default 90)
  are purged. `usage.enabled: false` stops recording without erasing what was
  collected
- `MNEMODOC_USAGE_ENABLED`, `MNEMODOC_USAGE_RETENTION_DAYS` and
  `MNEMODOC_USAGE_IMPORT_INTERVAL`

### Changed
- **Every tool call now logs one `info` line.** The split used to be read
  versus write rather than anything decided: tools that changed the index logged
  at `info`, tools that read it logged at `debug` or not at all. Since `debug` is
  off by default, the retrieval half of the server — the half worth auditing —
  was the invisible half, and checking how the documentation was used meant
  reading the MCP client's own transcript

## [1.1.0] - 2026-08-01

### Added
- Per-project daemon with a stdio proxy: one process owns the index, every
  `serve --stdio` is a thin client to it, with self-healing respawn and an
  in-process fallback
- Live re-indexing while the daemon runs, and a `daemon status` / `daemon stop`
  pair to drive it
- Contextual roles: the `get_project_context` tool and the `context` command,
  both selecting through one engine, with `--hook-stdin` reading a client hook
  payload directly
- `prompt-hook`: injects the best matching passage on `UserPromptSubmit`, gated
  on cosine similarity with thresholds measured on the benchmark corpus
- Fourteen further document formats — HTML, Office and OpenDocument, EPUB,
  DocBook, DITA, FictionBook, Jupyter notebooks — plus opt-in PDF
- Qdrant as an alternative semantic backend to the embedded vec0 index
- `--json` and `--quiet` on the subcommands, for scripting
- `index.max_file_size`, bounding what one document may cost to read
- `context.min_query_score`, the rule score the query channel requires before
  injecting a role; below it the channel stays silent instead of falling back to
  the default role. The files channel is not gated
- `get_project_context` and `context --json` both report the selected role's
  rule `score`, telling a decisive match from a single weak keyword
- `init` and `index` report their progress on stderr — a scan count, then a bar
  and a percentage — degrading to one plain line per phase off a terminal, and
  switched off under `--json` and `--quiet`
- Both commands report the elapsed time, and carry `elapsed_ms` in their JSON

### Changed
- **`paths` no longer defaults to `["doc/claude/", "app/"]`** and an empty list
  is a validation error. That default was one project's layout applied to every
  repository, which a single global registration would have followed blindly. A
  configuration relying on it must now name its paths, or be regenerated by
  `mnemodoc-server init`
- **A project is active only when `.mnemodoc/` is present.** A directory holding
  a `.mnemodoc.yml` but no marker stays inert instead of indexing itself: the
  server creates nothing and its tools answer with what to run. That is the
  price of one global registration serving every project, and `init` is the
  deliberate act that opts a project in
- `index` exits non-zero when chunks failed to embed and nothing was indexed;
  the payload carries a `failed` counter
- `ingest_path` refuses a path outside the configured roots, and refuses a
  partial ingest after an embedding model change
- `get_project_context` is only advertised when the project declares roles
- Environment overrides that cannot be read are reported by the startup
  validation instead of raising; booleans accept `true/1/yes/on` in any case

### Fixed
- The semantic tie-break could return a role whose rules had matched nothing:
  with a top score of 1 the margin filter admitted every role scoring 0 into the
  shortlist, so a conversational prompt carrying one incidental technical word
  got an arbitrary role
- `when_task` and `when_query` keywords matched anywhere inside a word, so
  `test` fired on `tester` and `attestation`; they now match on Unicode word
  boundaries, with `context.word_boundaries: false` to restore the old behaviour
- Documents with YAML frontmatter were indexed as a single headingless chunk
- Search fusion collapsed two chunks of one file that shared a heading
- Files that are not valid UTF-8 broke seventeen extensions' handlers
- Sections whose heading merely mentioned a table of contents were discarded
- Code samples were read as headings in Markdown, Org and AsciiDoc
- Deleting a file was not atomic across the index and its search tables
- `ingest_path` reported `notifications/progress` as a count of files indexed
  against a total of files to process, so progress stopped short of its total
  whenever a file yielded no chunks; it now counts files processed

## [1.0.0] - 2026-06-17

### Added

#### MCP server
- JSON-RPC 2.0 over stdio (Claude Code) and HTTP/SSE (Cursor) transports
- MCP tools: `query_documents`, `ingest_path`, `list_files`, `delete_file`, `status`
- Background startup indexing so the server is immediately responsive

#### Indexing pipeline
- Section-aware Markdown chunker splitting on `##`/`###` boundaries with frontmatter stripping
- Ollama embeddings client (`nomic-embed-text`) with batched requests and configurable timeout
- File crawler with mtime-based change detection (unchanged files skipped on reindex)
- Glob exclusion patterns (`exclude` config key or `MNEMODOC_EXCLUDE` env var)
- Configurable indexing concurrency (`index.concurrency`)
- `SingleFlight` deduplication — concurrent requests for the same embedding are coalesced

#### Search
- Semantic search via cosine similarity
- In-memory keyword search
- Hybrid search with Reciprocal Rank Fusion (RRF) and configurable keyword weight
- Recency bias: configurable boost for files modified within a rolling window

#### Storage
- SQLite store for chunks and embeddings (WAL mode, DELETE CASCADE)
- Automatic database path derived from config file location — same-named projects in different directories don't collide
- Per-store embedding model tracking

#### CLI
- `serve` — start the MCP server (`--stdio` or `--sse`, with `--host`/`--port` overrides)
- `index` — crawl and embed a file or directory from the terminal
- `search` — run a hybrid search query and display results as a table
- `status` — show database path, file count, chunk count, Ollama endpoint
- `delete` — remove a single file from the index
- `info` — print version and Crystal build description

#### Configuration
- YAML config file (`.mnemodoc.yml`) with full environment variable override support
- Relative `paths` resolved against the config file's directory, not the process CWD
- SSE bind address, port, log file, and log level configurable

#### Operations
- systemd `sd_notify` integration (`READY=1`, `STOPPING=1`, watchdog)
- `SIGUSR1` handler for log file rotation
- `SIGTERM` handler for graceful shutdown
- Per-host HTTP connection pool for Ollama calls
- Static Linux binaries built via `docker buildx bake` (distroless runtime image)

[1.3.1]: https://github.com/mnemodoc/mcp-server/releases/tag/v1.3.1
[1.3.0]: https://github.com/mnemodoc/mcp-server/releases/tag/v1.3.0
[1.2.0]: https://github.com/mnemodoc/mcp-server/releases/tag/v1.2.0
[1.1.0]: https://github.com/mnemodoc/mcp-server/releases/tag/v1.1.0
[1.0.0]: https://github.com/mnemodoc/mcp-server/releases/tag/v1.0.0
