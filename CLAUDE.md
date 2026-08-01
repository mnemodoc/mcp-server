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

**Beyond search — contextual roles:** a role-selection engine (`Roles::Selector`) picks the conventions Claude should adopt for the files/task/query at hand, exposed both as the `get_project_context` MCP tool and the `context` CLI command (the latter drives a `PreToolUse` hook so guidance lands even when the agent doesn't ask). The `context` command also accepts `--hook-stdin` (with `--client`, default `claude-code`): it reads the client's raw hook JSON on stdin, derives files/query from it, and attributes the selection to its session/agent in the audit log; explicit `--files/--task/--query` flags remain as a fallback. Operational warnings raised at startup are surfaced in every tool response via the `Advisories` module, since `Log.warn` is invisible in some MCP clients.

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
mise bench:tokens  # measure retrieval cost vs loading the whole corpus (needs Ollama)
```

`bench:tokens` lives in `bench/`, outside `src/` so it is never linked into the
shipped binary. It reports a token saving **and** the recall it was achieved at,
and refuses to present the two apart: returning nothing is a 100 % saving and a
total failure, so a zero-recall run prints "not meaningful" and exits non-zero.
Exact counts come from Anthropic's free `count_tokens` endpoint when
`ANTHROPIC_API_KEY` is set (mise loads it from a git-ignored `.env`); without a
key it counts characters and says so. Note `dev:format` covers `src/ bench/` —
ameba already inspects `bench/`, so formatting only `src/` would let it drift.

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
bench/                              Token-cost benchmark (bench.cr entry, runner, report, TokenCounter, fixture corpus + annotated questions)
src/mnemodoc-server.cr              Entry point — nothing but `CLI.run`. Compiled to the binary (`SOURCE_FILE` in mise.toml)
src/mnemodoc_server.cr              Library root: every require, plus init_app!, discover_project, project_initialized?, config_file, open_store, run_transport, serve_stdio/sse, watch_and_index, daemon helpers. Requiring it has **no side effect** — specs and bench/ require this, never the entry point
src/mnemodoc_server/
  cli.cr                           Admiral CLI — subcommands: install, uninstall, init, uninit, serve, index, search, status, delete, context, info, prompt-hook, daemon (status/stop); CLIOutput routes each result to --json / text / --quiet
  project.cr                       Project marker (.mnemodoc/): doc-directory detection, generated .mnemodoc.yml, marker creation/removal, shared index .gitignore
  install/
    claude_code.cr                 Registers/unregisters mnemodoc in ~/.claude.json + ~/.claude/settings.json (JSON::Any merge, atomic write)
  config.cr                        YAML config + apply_env! + validate! (Ollama/Search/Server/Db/Index/Qdrant/Role/Context configs); daemon_socket_path / daemon_lock_path. `paths` has **no default** — an empty list is a validation error
  daemon.cr                        Per-project daemon: owns the SQLite index, spawns background indexing + a live file-watch (watch_and_index), serves MCP over a UNIX socket, self-exits when idle
  daemon_proxy.cr                  Default `serve --stdio` path when server.daemon is true: auto-spawns the daemon (flock-serialised), forwards JSON-RPC over the UNIX socket, self-heals on daemon death (≤3 attempts), falls back to in-process standalone on exhaustion
  helpers.cr                       version (shard version + git ref, compile-time), format_bytes, format_duration
  progress.cr                      Terminal progress rendering (IO + tty injected) + Progress::Indexing, the crawler's two phases
  systemd.cr                       systemd sd_notify (READY=1, STOPPING=1, watchdog)
  single_flight.cr                 Concurrent deduplication via Channel + Mutex
  connection_pool.cr               Per-host HTTP connection pool (for Ollama calls)
  chunk.cr                         Chunk struct + FileInfo struct
  indexer/document.cr              Document struct (text + verbatim flag + outline + chunks) and OutlineEntry
  advisories.cr                    Persistent startup advisories, surfaced in every tool response
  licenses.cr                      Third-party license texts baked into the binary, so a redistributed artifact carries the notices its statically-linked deps require
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
      fence_tracker.cr             Tracks fenced code blocks so their contents are never read as headings
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
    sqlite.cr                      SQLite store (WAL) — files/chunks/meta/documents/outline, embeddings as blobs, vec0 KNN, write mutex
    sqlite_vec.cr                  LibVec binding to the ext/sqlite-vec submodule (vec0), registered per connection
    qdrant_index.cr                Best-effort QdrantIndex over qdrant-client (opt-in semantic backend; replaces vec0 when search.backend=qdrant)
  search/
    semantic.cr                    Dot-product / cosine scoring — in-memory linear, vec0 KNN, and Qdrant KNN overloads
    keyword.cr                     FTS5/BM25 keyword search (query tokenized in Crystal, ranked per file by the store)
    hybrid.cr                      RRF fusion + recency bias (SearchResult)
    hook_selection.cr              The prompt hook's whole injection rule (cosine gate + margin), kept here so the benchmark replays the shipped logic
  roles/
    role.cr                        Role at runtime (config + resolved path; markdown read lazily and cached)
    selector.cr                    Contextual-role selection (B3 cascade: weighted rules + semantic tie-break, shortlist restricted to roles that matched, word-boundary keyword matchers compiled once)
  hooks/
    input.cr                       HookInput struct: normalised client-agnostic hook payload
    adapter.cr                     Adapter interface (parse JSON::Any → HookInput; never raises on keys)
    registry.cr                    client name → adapter; default claude-code; unknown client raises
    claude_code.cr                 Claude Code adapter (PreToolUse → files, UserPromptSubmit → query, + attribution)
  tools/
    query.cr                       query_documents MCP tool
    ingest.cr                      ingest_path MCP tool
    list.cr                        list_files MCP tool
    delete.cr                      delete_file MCP tool
    status.cr                      status MCP tool
    context.cr                     get_project_context MCP tool (delegates to Roles::Selector)
    document_access.cr             Shared path resolution + document loading + staleness for the two reading tools
    outline.cr                     outline_document MCP tool
    read.cr                        read_document MCP tool
```

### Project resolution and the `.mnemodoc/` marker

**The marker is the directory, not the YAML.** `MnemodocServer.discover_project`
walks up from the working directory to the nearest `.mnemodoc/` and anchors
`source_dir` there — which is enough to scope the whole stack, since `db_path`,
`daemon_socket_path`, `daemon_lock_path` and `project_key` all derive from it.
An explicit `--config` short-circuits discovery and its own directory becomes
the project root; that is why every `--config` flag now defaults to `""` rather
than `.mnemodoc.yml`.

**Why it exists.** `install` registers *one* global MCP entry with no project
path, so the server is launched in whatever directory a client session opens.
Three things had to change for that to be safe: `paths` lost its hardcoded
`["doc/claude/", "app/"]` default (one project's layout, applied to every
repository), `open_store` no longer creates an index directory when no project
was found (it serves from `Store::SQLite::MEMORY` instead), and background
indexing is skipped in that state.

**Uninitialised is a state, not an error.** `project_initialized?` is false only
when discovery ran and found nothing. `ToolRegistry.guarded` then answers every
tool with `UNINITIALIZED_MESSAGE` — `is_error: false`, plus
`project_initialized: false` in the structured content. An empty result would
read to the agent as "the documentation says nothing on this", which is a
different and wrong statement. `init_app!` also skips `validate!` in that state,
since `paths` is legitimately empty.

**`init` is the only thing that creates the marker.** It detects documentation
directories that actually exist (`doc`, `docs`, `documentation`, `.claude`,
falling back to the project root), writes a minimal generated `.mnemodoc.yml`
unless one is already there, and runs the first index. `uninit` removes the
marker and keeps the configuration. Note the process-wide nature of
`project_initialized?`: specs that resolve to "no project" must call
`restore_project_state` (spec_helper) or they hand the short-circuit to whatever
runs next under a different seed.

### Registering with a client

`Install::ClaudeCode` writes the MCP entry to `~/.claude.json` and the two hooks
plus the permission entries to `~/.claude/settings.json`. Both are user-owned
files carrying other tools' settings, so everything goes through `JSON::Any`
read → modify → write (a typed struct would silently drop unknown keys) with an
atomic temp-file rename. A target that exists but does not parse raises
`Install::UnreadableTarget` and nothing is written.

Two deliberate departures from `codegraph install`, which was the reference:
`--print-config` shows **every** file it would touch, hooks and permissions
included (codegraph's shows only the MCP entry while its install also writes a
hook and a permission), and the permissions are the three read-only tools named
one by one — never `mcp__mnemodoc__*`, which would grant any tool added later
the same standing approval without anyone deciding to.

### Daemon / proxy

**Problem solved:** when multiple MCP clients (Zed, parallel `claude-agent` sessions) each launch `serve --stdio`, each one used to open the same `index.db` and trigger a background re-index at boot — N processes competing on the same SQLite index. Now ONE daemon per project owns the index; every `serve --stdio` invocation is a thin proxy to it. Clients are unchanged.

**Daemon** (`daemon.cr`): launched internally by `serve --daemon`. It opens `Store::SQLite`, starts background indexing in a fiber, then binds `MCP::Http` on a UNIX domain socket at `<index dir>/daemon.sock` (beside the index DB, i.e. `.mnemodoc/` by default). It wires SIGTERM → graceful stop and SIGUSR1 → log rotation. It writes its pid to `<index dir>/daemon.pid` once the socket is bound and removes it on graceful shutdown. After `server.daemon_idle_timeout` seconds of inactivity the transport self-exits; the next `serve --stdio` auto-respawns it. `daemon status` and `daemon stop` drive this from the CLI: both trust `GET /health` over the socket rather than the pid file alone, since a hard kill leaves the file behind and that pid may have been reused. Crash-safety rests on SQLite WAL and the per-file atomic indexing convention. **Live re-indexing:** when `server.daemon_watch` is set (default), the daemon also spawns `MnemodocServer.watch_and_index` — a supervised fiber that polls the configured paths (via the `file_watcher` shard, `server.daemon_watch_interval` seconds) and re-indexes a single file on add/change (through the crawler) or removes it on delete. Only the daemon watches; the standalone stdio path does not.

**Proxy** (`daemon_proxy.cr`): the default `serve --stdio` path when `server.daemon` is true. On startup it checks `GET /health` over the socket; if the daemon is not running it acquires an exclusive advisory lock on `<index dir>/daemon.lock`, removes any stale socket, spawns the daemon process fully detached (no shared stdio), and polls `/health` until it answers (up to 30 s). The flock prevents double-spawn when multiple clients start simultaneously. For each stdin line the proxy opens a fresh UNIX connection, POSTs to `/mcp`, and writes the reply to stdout, with up to 32 concurrent requests in flight. On a connection failure it self-heals under the flock (up to 3 attempts total). A replayed `delete_file` whose response is "not found in index" is rewritten to a success — the file was likely already deleted before the daemon died. If healing is exhausted the whole remaining session falls back to a lazily-built in-process standalone handler (which does **not** re-index, to avoid a multi-process indexing storm). A startup failure (daemon never becomes healthy) also falls back to the in-process standalone.

### Machine-readable CLI output

Every subcommand that returns a result accepts `--json` (one JSON object on stdout) — `index`, `search`, `outline`, `read`, `status`, `delete`, `context`, `info`, `daemon status`, `daemon stop`. `serve` and `prompt-hook` do not. Errors under `--json` go to **stderr** as `{"error": "..."}` with stdout left empty and exit code 1, so parsing stdout can never swallow a failure. `search --json` uses the same key names as the `query_documents` tool (`file`, `heading`, `parent_heading`, `content`, `score`).

**Payloads evolve additively** — fields may be added, never removed or renamed. There is deliberately no schema version field.

`--quiet` (on `index`, `delete`, `daemon status`, `daemon stop`) prints nothing and reports through the exit code. Two commands exit non-zero on an outcome rather than a crash: `daemon status` when no daemon is running (`systemctl is-active` semantics), and `index` when chunks failed to embed and nothing at all was indexed (an unreachable Ollama, typically) — a run with nothing to do still exits 0, and the payload carries a `failed` counter regardless. `ingest_path` refuses a path outside `paths:` and refuses a partial ingest when the embedding model has changed; both keep the index from being half-built or quietly poisoned.

### Reading a document, and why it is served from the index

`outline_document` and `read_document` fill the gap between the scattered
passages `query_documents` returns and a re-read of the whole file. Both take a
path resolved the way `delete_file` resolves one, and both go through
`Tools::DocumentAccess`, so neither can drift from the other on what it reports
about the document it served.

**The text is stored at index time, in the same transaction as the chunks.**
Reading the file instead would have been simpler and wrong in three ways: the
chunks are a *filtered* view (the `ChunkAssembler` drops TOC sections and splits
oversized ones, the `Sectionizer` discards a section whose body is blank), so
serving them as "the document" would silently redact it; a file edited since
indexing would answer with content the returned passages were never built from;
and `pdftotext` would be back in a read path. The stored copy costs one extra
copy of the corpus text — small against the vectors, which are 768 float32
stored both in `chunks.embedding` and in `vec_chunks`.

**The invariant that makes line addressing unambiguous: `OutlineEntry#start_line`
indexes the stored text, never the file.** `verbatim` only tells the consumer
whether that text happens to equal the file — true for Markdown, Org, AsciiDoc,
RST and plain text, false for every extracted format. A handler therefore cannot
mix the two, and the reading tools have no per-format special case: they slice
`text`. Two cases are worth remembering: `.ipynb` is JSON but the document is
the pseudo-Markdown the handler synthesises, and `.html` is text on disk yet the
DOM walk never learns which source line an `<h2>` sat on, so it numbers its own
extraction.

The capture point is the `Sectionizer`, which already tracked heading levels and
used to throw them away. Handlers reading a text file pass the true source line;
the rest let it number what they emit. Markdown parses content already stripped
of its frontmatter, so it adds the dropped line count back — without that, every
heading in a file with frontmatter is off by exactly that many lines, an error
that passes every functional test.

**Staleness is reported, never repaired.** A changed or deleted file yields
`stale: true` plus a `warnings` entry, and the indexed revision is still served.
Repairing would put an embedding call and a write in a read path, duplicating
what the daemon's watcher already does.

**Existing indexes catch up without Ollama.** `MnemodocServer.backfill_documents!`
runs before the startup crawl and rebuilds the missing text and outline by
re-reading and re-parsing — the vectors are already stored and still valid. It
lives in the bootstrap rather than in `Store::SQLite#migrate!` because it needs
the `Format::Registry`, and the store must not depend on the indexer. Note it
re-attaches the embeddings before rewriting the chunks: `chunks_for_files`
deliberately returns them empty, so writing those straight back through
`index_file` would erase every vector of the file.

### Role selection on a weak signal

Two rules keep the query channel (`UserPromptSubmit`) from injecting a role
nobody asked for.

**The semantic tie-break only ranks roles that matched a rule.** It compares the
query against role *descriptions*, which says nothing about whether a role
applies — so arbitrating among roles whose score is 0 returns an arbitrary one.
The margin filter alone did not guarantee this: with a top score of 1 the
threshold `top - MARGIN` is **-1**, so every role scoring 0 entered the
shortlist, the unique-candidate guard never fired, and any conversational prompt
carrying one incidental technical word got a role. The shortlist now requires
`score > 0`, which is the invariant the code's own comment already claimed.

**Keywords match whole words.** `when_task`/`when_query` used plain substring
matching, so `test` fired inside `tester` and `attestation`, and the shorter the
keyword the worse it got — with nothing the configuration could do about it.
The patterns are compiled once per selector (the keywords are fixed by the
config, the selector lives as long as the daemon) and spell their boundaries as
`\p{L}\p{N}_` lookarounds rather than `\b`, whose word characters are ASCII-only
without UCP: keywords and prompts alike are routinely accented. `word_boundaries:
false` restores the old behaviour deliberately.

`context.min_query_score` is the score the query channel requires before
injecting; below it stdout stays **empty**, rather than falling back to the
default role, because this runs before every user message. The files channel is
never gated — an edited file is a strong, unambiguous signal — and neither is
the `get_project_context` tool, which the agent calls deliberately.

### Indexing progress

`init` and `index` report two phases while they crawl — `Scanning files`, which
reports a running count because the total is what it is busy discovering, then
`Indexing files`, with a bar and a percentage. Both go to **stderr**, never to
stdout, which carries results alone. Off a terminal the rendering degrades to
one plain line per phase: no bar, no percentage, no control character, so a CI
log shows the run is alive without filling with carriage returns.

`Progress` takes its IO **and** its tty flag as arguments and never consults the
process's streams — that decision belongs to `CLIProgress`, once, and injecting
it is what makes the rendering testable without a terminal. Colours are written
by hand for the same reason: `Colorize.enabled?` is a process-wide flag derived
from STDOUT/STDERR.

The crawler knows nothing of phases: it reports a count while scanning and a
fraction while indexing, and never says the scan ended. The first indexing
callback **is** that signal, and `Progress::Indexing` is where it turns into a
phase switch — keeping any notion of display out of the crawler.

Progress and the log may both be headed for stderr, and only one can own it.
Three cases: the log goes elsewhere (a file, stdout) and nothing collides, so
both run untouched; the log is at debug or trace, so the detail that was
explicitly asked for keeps the stream and there is no bar at all; otherwise the
bar owns it and info-level entries are held back by `hush_log!` until
`release_log!`, warnings and errors still passing through. The debug rule is
deliberately **not** conditioned on a terminal — a TTY-only branch would be
unreachable from a spec.

### The prompt hook

`prompt-hook` reads a client hook payload on stdin (`Hooks::Registry`, same
adapters as `context`) and injects the best matching passage on
`UserPromptSubmit` — documentation arrives whether or not the agent calls
`query_documents`.

It gates on **cosine similarity**, not on the fused search score: the latter is
an RRF rank artifact with no absolute meaning, identical for the top hit of an
off-topic query and of a targeted one. `SearchResult#similarity` carries the
cosine through fusion for exactly this purpose, and is `nil` for a chunk
surfaced by the lexical signal alone — which therefore can never clear the gate.

`Search::HookSelection` holds the whole rule — deliberately on its own, so the
benchmark replays the shipped logic instead of a copy that could drift from it.
Two gates: `hook.similarity_threshold` (0.515, env `MNEMODOC_HOOK_THRESHOLD`)
decides *whether* to inject; `hook.margin_threshold` (0.02, env
`MNEMODOC_HOOK_MARGIN`) decides *how many* — a runner-up within that cosine
distance means the ranking is not decisive, so contenders go over together, up
to `hook.max_passages` (3, env `MNEMODOC_HOOK_MAX_PASSAGES`).

Every default is measured on the benchmark corpus, not chosen. `mise
bench:tokens` reports firing rate, false-fire rate on off-topic prompts, and how
often the injected set actually contains the answer — re-calibrate per corpus.

**The score `knn_chunks` returns is a true cosine, and that is load-bearing.**
It used to be `1/(1 + L2 distance)`: monotonic in cosine, so ranking was
correct, but not a similarity — it compresses the scale toward 0.5, which
shrank the on-topic/off-topic separation on the benchmark corpus from 0.054 to
0.014 and silently applied thresholds to the wrong axis. Chunk embeddings are
normalised at index time and Ollama returns unit vectors, so `cos = 1 - L2²/2`
inverts exactly. Note the Qdrant backend returns its own metric: a threshold
calibrated on vec0 does not transfer to it unmatched.

Every failure path is silent-and-exit-0 by design: this runs synchronously in
the user's critical path.

## MCP tools exposed

| Tool | Description |
|---|---|
| `query_documents` | Hybrid search — returns top-K relevant chunks |
| `ingest_path` | Index a file or directory |
| `list_files` | List indexed files with metadata |
| `delete_file` | Remove a file from the index |
| `status` | Server status: chunk count, Ollama config, version |
| `outline_document` | A document's heading plan: level, title, start/end line, length |
| `read_document` | A numbered window of a stored document, served from the index |
| `get_project_context` | Select the role to adopt for the current files/task/query; returns the role's markdown + structured `role`/`reason`/`score`/`candidates` |

Outside an initialised project every one of them returns the same non-error
result inviting `mnemodoc-server init`, rather than an empty one.

## Config file format

Default: `.mnemodoc.yml` (override with `--config`/`-c`).

Relative `paths` and the auto DB location are resolved against the **config file's directory**, not the process CWD.

```yaml
# Required — there is no default. `mnemodoc-server init` generates this section
# from the documentation directories it finds.
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
  max_file_size: 10485760  # bytes; a larger document is skipped rather than read whole (0 disables the bound)

chunking:             # optional noise reduction; both default false (index unchanged). Re-index after changing.
  strip_link_only_lines: false             # drop pure breadcrumb lines (links + separators only); line-based markup only (Markdown/Org/AsciiDoc/RST), no-op on DOM/Office
  merge_preamble_into_first_section: false # fold the pre-heading preamble into the first section chunk

context:              # optional — contextual-role selection (get_project_context tool + `context` CLI)
  default: doc/claude/roles/generalist.md  # fallback role when no rule fires and there is no signal
  min_query_score: 1    # rule score the query channel requires before injecting; below it, silence (>= 1)
  word_boundaries: true # match when_task/when_query as whole words, not inside longer ones
  roles:
    - file: doc/claude/roles/backend.md    # markdown instructions; path resolved like `paths`
      description: Backend conventions      # used only for the semantic tie-break
      when_files: ["app/models/**", "app/policies/**"]  # glob triggers (File.match? on the path)
      when_task:  ["implement", "refactor"]             # keyword triggers on the task kind
      when_query: ["operation", "policy"]               # keyword triggers on the user query

hook:                 # optional — the UserPromptSubmit passage injector (`prompt-hook`)
  similarity_threshold: 0.515  # cosine the best passage must reach to be injected at all
  margin_threshold: 0.02       # a runner-up within this cosine distance goes over too
  max_passages: 3              # ceiling on the set injected when the margin is thin

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
  # default: .mnemodoc/index.db, beside the config file. That directory is also
  # the project marker (see "Project resolution"): WAL files + daemon
  # socket/lock live there, and a self-ignoring .gitignore is written with it.
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
| `MNEMODOC_INDEX_MAX_FILE_SIZE` | `index.max_file_size` |
| `MNEMODOC_CHUNKING_MERGE_PREAMBLE` | `chunking.merge_preamble_into_first_section` |
| `MNEMODOC_HOOK_THRESHOLD` | `hook.similarity_threshold` |
| `MNEMODOC_HOOK_MARGIN` | `hook.margin_threshold` |
| `MNEMODOC_HOOK_MAX_PASSAGES` | `hook.max_passages` |
| `MNEMODOC_EXCLUDE` | `exclude` (comma-separated patterns) |

## Claude Code integration

`mnemodoc-server install` writes this; the block below is what it produces.
stdio is the default transport (`--sse` switches to HTTP), so `--stdio` is
optional. Note the absence of `--config`: the server discovers its project by
walking up from the directory the client launches it in, which is what lets a
single global entry serve every project.

```json
{
  "mcpServers": {
    "mnemodoc": {
      "type": "stdio",
      "command": "/usr/local/bin/mnemodoc-server",
      "args": ["serve"]
    }
  }
}
```

## Testing

Uses [Spectator](https://gitlab.com/arctic-fox/spectator). Specs require `src/mnemodoc_server.cr` (the library), never `src/mnemodoc-server.cr` (the entry point) — requiring the latter would run the CLI against the spec runner's own ARGV.

There is no environment-detection shard: `crystal-env` was carried solely so `Crystal.env.test?` could stop the entry point from running its CLI during specs, and the library/entry split removed the need for it.

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
- `spec/document_capture_spec.cr` — Sectionizer outline/text capture, Document
- `spec/tools_read_spec.cr` / `spec/tools_outline_spec.cr` — the two reading tools
- `spec/backfill_documents_spec.cr` — rebuild without Ollama, embeddings preserved
- `spec/cli_document_spec.cr` — `outline` / `read` subcommands end to end
- `spec/project_discovery_spec.cr` — marker walk-up, anchoring, no index dir without a project
- `spec/uninitialized_project_spec.cr` — every tool short-circuits with the `init` invitation
- `spec/cli_init_spec.cr` — `init` / `uninit` end to end (marker, path detection, --force)
- `spec/cli_install_spec.cr` — `install` / `uninstall` end to end, with HOME redirected at a temp dir
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
