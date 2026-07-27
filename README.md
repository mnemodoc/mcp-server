<p align="center">
  <img src="assets/logo.svg" alt="mnemodoc" width="160" height="160">
</p>

<h1 align="center">mnemodoc-server</h1>

[![CI](https://github.com/mnemodoc/mcp-server/actions/workflows/ci.yml/badge.svg)](https://github.com/mnemodoc/mcp-server/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/mnemodoc/mcp-server)](LICENSE)
[![Release](https://img.shields.io/github/v/release/mnemodoc/mcp-server)](https://github.com/mnemodoc/mcp-server/releases)

A Crystal MCP server that indexes project documentation via Ollama embeddings and exposes hybrid search (semantic + keyword) to MCP clients.

## Why

Loading full documentation context at each Claude Code session is expensive — and unreliable: bulk context gets compacted away, and the agent only retrieves what it already knows to look for. mnemodoc-server lets Claude fetch the relevant passages on demand (cutting token cost) *and* injects the right conventions mechanically before every edit, so guidance lands whether or not the agent thinks to ask.

## A way to think about it — the librarian

**Before MnemoDoc**, every meeting started by dumping seven thick binders on the table "just in case." The table buckled, nobody could find anything, and it cost a fortune just to sit down. *(the `/context-reload`)*

**MnemoDoc is the librarian.** It never hands you the whole library. You ask a question, it comes back with **the three pages that answer it** — and tells you which book they came from. *(`query_documents` + traceable chunks)*

To do that, it did two things up front:

- It **cut each book into coherent pages**, not random photocopies — one page = one complete idea. *(section-aware chunking)*
- It knows its shelves two ways: **by meaning** ("what it's about") *and* **by the exact words** on the page. When you ask, it cross-checks both so it doesn't reach for the wrong shelf. *(semantic + keyword + RRF)*

It also has a reflex: **whatever was revised recently, it's more inclined to lay on top of the pile** — because with docs, fresh often wins. *(recency boost)*

And its honesty rests on a discipline: **it walks its shelves the moment a book changes**, so it never quotes you a stale page with a straight face. *(the `mtime` crawler)*

**And the reader, in all this?** *(the AI)* The librarian may lay the right pages on the table, but someone still has to read them. The reader shows up with **a pair of glasses**: "read this as a lawyer," "read this as a cryptographer." *(the role selector)*

The glasses add **no book** — neither to the librarian's shelves nor to the reader's own memory. They change **the sharpness of the reading**: with the right glasses, the reader connects the pages to what they already know, spots the details a layperson skips, and writes the report in the right register. But put expert glasses on and lay **nothing on the table**, and the reader won't say "I have nothing to read": they'll write a fine expert report… about pages they imagined. *(the role hallucination)*

**Moral.** We didn't make the assistant "an expert on your project" — we gave it **the right librarian**. The glasses *sharpen* the reading; only the librarian *feeds* the table. And it's always the librarian who speaks first: glasses over an empty table conjure only mirages. 🌅😊

<details>
<summary>🇫🇷 Version française</summary>

**Avant MnemoDoc**, à chaque réunion, on vidait sept gros classeurs sur la table « au cas où ». La table croulait, on ne retrouvait plus rien, et ça coûtait cher rien que pour s'asseoir. *(le `/context-reload`)*

**MnemoDoc, c'est le bibliothécaire.** Il ne te tend jamais la bibliothèque entière. Tu lui poses une question, il revient avec **les trois pages qui répondent** — et il te dit de quel livre elles viennent. *(`query_documents` + chunks traçables)*

Pour ça, il a fait deux choses en amont :

- Il a **découpé chaque ouvrage en pages cohérentes**, pas en photocopies au hasard — une page = une idée complète. *(chunking section-aware)*
- Il connaît ses rayons de deux façons : **par le sens** (« ce que ça raconte ») *et* **par les mots exacts** sur la page. Quand tu demandes, il croise les deux pour ne pas se tromper d'étagère. *(sémantique + keyword + RRF)*

Il a aussi un réflexe : **ce qui a été révisé récemment, il le pose plus volontiers sur le dessus de la pile** — parce qu'en doc, le frais prime souvent. *(recency boost)*

Et son honnêteté tient à une discipline : **il passe ses rayons en revue dès qu'un livre change**, pour ne jamais te citer une page périmée avec aplomb. *(crawler `mtime`)*

**Et le lecteur, dans tout ça ?** *(l'IA)* Le bibliothécaire a beau poser les bonnes pages sur la table, encore faut-il quelqu'un pour les lire. Le lecteur arrive avec **sa paire de lunettes** : « lis ça en juriste », « lis ça en cryptographe ». *(le sélecteur de rôle)*

Les lunettes ne rajoutent **aucun livre** — ni sur les rayons du bibliothécaire, ni dans la propre mémoire du lecteur. Elles changent **la finesse de lecture** : avec les bonnes lunettes, il relie les pages à ce qu'il sait déjà, repère les détails que le profane saute, et rédige son compte-rendu dans la bonne langue. Mais si on lui chausse des lunettes d'expert sans **rien poser sur la table**, il ne dira pas « je n'ai rien à lire » : il écrira un beau compte-rendu d'expert… sur des pages qu'il a imaginées. *(l'hallu de rôle)*

**Morale.** On n'a pas rendu l'assistant « expert du projet » — on lui a donné **le bon bibliothécaire**. Les lunettes *affinent* la lecture ; seul le bibliothécaire *nourrit* la table. Et c'est toujours lui qui parle en premier : des lunettes sur une table vide, ça n'invente que des mirages. 🌅😊

</details>

## Features

- **Contextual roles, injected mechanically** — a role-selection engine exposed as both an MCP tool *and* a CLI, so a `PreToolUse` hook can guarantee the right conventions reach the agent before every edit — not just when it remembers to ask ([details](#contextual-roles--the-pretooluse-hook))
- **Multi-format indexing** — lightweight markup, HTML/XML doc vocabularies, Office & OpenDocument files, e-books and notebooks — all pure stdlib, no external tool — plus opt-in PDF, dispatched by a per-format handler registry ([full list](#supported-formats))
- **Section-aware chunking** — splits each document at its heading boundaries (e.g. `##`/`###` in Markdown), not arbitrary token counts
- **Hybrid search** — semantic (Ollama embeddings, vec0 KNN index) + keyword (SQLite FTS5 / BM25) fused with RRF
- **Pluggable vector backend** — semantic KNN runs on the embedded vec0 index by default, or opt into **Qdrant** (`search.backend: qdrant`) for a remote/scalable store; SQLite stays the source of truth and Qdrant is a best-effort, rebuildable index
- **Local & private** — embeddings via Ollama (native or Docker), no data sent externally
- **Two transports** — stdio (Claude Code) and HTTP (Cursor, other MCP clients)
- **Static binary** — single executable, no runtime dependencies

## Supported formats

Files are dispatched to a handler by extension. Everything below is indexed
**out of the box with no external dependency** (pure Crystal stdlib), except PDF.

| Family | Extensions |
|---|---|
| Markdown / MDX | `.md` `.markdown` `.mdx` `.mkd` `.mdown` `.mdwn` `.markdn` `.mdtext` `.mmd` `.qmd` (Quarto) `.rmd` (R Markdown) |
| Org-mode | `.org` |
| AsciiDoc | `.adoc` `.asciidoc` |
| reStructuredText | `.rst` |
| HTML / XHTML | `.html` `.htm` `.xhtml` |
| DocBook | `.dbk` `.docbook` |
| DITA | `.dita` (topics only; `.ditamap` is references, not prose) |
| Jupyter notebook | `.ipynb` |
| Plain text | `.txt` `.text` (+ fallback for unknown files named explicitly in `paths`) |
| Word | `.docx` `.docm` `.dotx` `.dotm` |
| PowerPoint | `.pptx` `.pptm` `.potx` `.potm` `.ppsx` `.ppsm` |
| LibreOffice Writer | `.odt` `.ott` `.fodt` |
| LibreOffice Impress | `.odp` `.otp` `.fodp` |
| EPUB | `.epub` |
| FictionBook | `.fb2` |
| **PDF** (opt-in) | `.pdf` — requires `pdftotext` in `PATH`; enable with `index.pdf: true` |

Each handler reads **and** parses a file into section-aware chunks; handlers never
raise on a corrupt or malformed file (they log a warning and skip it), so one bad
file never aborts an indexing run.

### Not indexed

Deliberately out of scope. These would each need a real parser or an external
tool, or carry little prose value for documentation search:

- **Spreadsheets** — `.xlsx` / `.ods` / `.xls` (tabular data, not prose).
- **Legacy binary office** — `.doc` / `.ppt` / `.xls` (OLE) and `.rtf`; would need
  an external converter (`antiword`, LibreOffice…) the way PDF needs `pdftotext`.
- **LaTeX / TeX / Texinfo** — `.tex` `.latex` `.texi` (heavy markup; needs a real
  stripper).
- **Other lightweight markup** — Textile, MediaWiki/`.wiki`, Creole, Gemtext,
  man/roff (niche; each a small dedicated parser).
- **Proprietary / binary** — Apple iWork (`.pages` `.key` `.numbers`), Kindle
  (`.mobi` `.azw*`), WordPerfect (`.wpd`), Visio (`.vsdx`), OneNote (`.one`),
  DjVu, comics (`.cbz`/`.cbr`).
- **Non-document files** — source code, config/data (`.json` `.yaml` `.toml`
  `.csv`), email, subtitles, calendars, feeds, images. mnemodoc indexes
  *documentation prose*, not code or structured data.

## Quick start

**1. Start Ollama**

```sh
docker run -d --name ollama -p 11434:11434 ollama/ollama
docker exec ollama ollama pull nomic-embed-text
```

**2. Install mnemodoc-server**

```sh
# macOS
brew install mnemodoc/tap/mnemodoc-server

# Linux — download the binary for your architecture from the releases page:
# https://github.com/mnemodoc/mcp-server/releases
```

**3. Register mnemodoc with your client — once**

```sh
mnemodoc-server install            # shows what it will write, then asks
mnemodoc-server install --print-config   # or just look, and write nothing
```

This registers the MCP server in `~/.claude.json` and adds two hooks to
`~/.claude/settings.json`: the role selector on edits, and the passage injector
on prompts. Both files are read, modified and rewritten atomically, so other
tools' settings are preserved. `--no-hooks` and `--no-permissions` narrow what
is written; `mnemodoc-server uninstall` removes exactly what was added.

The registration carries **no** project path. The server finds its project by
walking up from the directory the client launches it in, so one global entry
serves every project.

**4. Initialise each project you want indexed**

```sh
cd ~/code/my-project
mnemodoc-server init
```

`init` is the deliberate act that turns a directory into a MnemoDoc project. It
creates the `.mnemodoc/` index directory (self-ignoring, never committed),
generates a `.mnemodoc.yml` from the documentation directories it actually finds
— `doc/`, `docs/`, `documentation/`, `.claude/`, falling back to the project
root — and builds the first index. An existing `.mnemodoc.yml` is never
overwritten unless you pass `--force`.

Until a project is initialised the server stays inert there: it creates nothing,
indexes nothing, and every tool answers with what to do about it rather than an
empty result that would read as "the documentation says nothing on this".
`mnemodoc-server uninit` removes the marker and keeps the configuration.

**5. Check it**

```sh
mnemodoc-server status
mnemodoc-server search "how to persist a model"
```

Neither needs `--config`: like the server, they discover the nearest project by
walking up. Pass `--config` explicitly to point at a different one.

### Wiring a client by hand

`install` covers Claude Code. For any other client, register the binary
yourself.

*Cursor* (`.cursor/mcp.json`) — HTTP transport, start the server first:

```sh
mnemodoc-server serve --sse --config /path/to/project/.mnemodoc.yml
```

```json
{
  "mcpServers": {
    "doc": {
      "url": "http://localhost:8765/mcp"
    }
  }
}
```

*Any stdio client* — the equivalent of what `install` writes:

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

## CLI

```sh
mnemodoc-server install [--print-config] [--no-hooks] [--no-permissions]    # Register with Claude Code (once, globally)
mnemodoc-server uninstall                                                  # Remove that registration
mnemodoc-server init [--force]                                             # Make this directory a MnemoDoc project
mnemodoc-server uninit                                                     # Remove the project marker, keep the config
mnemodoc-server serve [--config <file>]                                    # Claude Code (stdio, default)
mnemodoc-server serve --sse [--port 8765] [--host 127.0.0.1]             # Cursor / other clients
mnemodoc-server index <path>                                               # Index a file or directory
mnemodoc-server search "<query>" [--mode hybrid|semantic|keyword] [--top 5] # Test search from terminal
mnemodoc-server status                                                     # Index stats
mnemodoc-server delete <path>                                              # Remove from index
mnemodoc-server context [--files <path>]... [--task <kind>] [--query "<text>"] # Resolve & print the role to adopt
mnemodoc-server info                                                       # Version info
mnemodoc-server prompt-hook                                                # Client hook: inject the best passage for a prompt (stdin)
mnemodoc-server daemon status                                              # Is this project's daemon running?
mnemodoc-server daemon stop [--timeout 10]                                 # Stop it gracefully
```

### Injecting documentation before the agent asks

`query_documents` only fires if the agent decides to call it. `prompt-hook`
removes that dependency: wired to `UserPromptSubmit`, it searches the index
against the user's message and injects the single best passage — whether or not
the agent thinks to look.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command",
                    "command": "mnemodoc-server prompt-hook --config /path/to/.mnemodoc.yml" }] }
    ]
  }
}
```

**It stays silent unless the prompt measurably concerns this corpus.** The gate
is the cosine similarity of the best passage against
`hook.similarity_threshold` (default `0.515`) — not the search score, which is a
rank artifact that looks the same for an off-topic query as for a targeted one.
Below the threshold, on unparseable input, with Ollama down, on an empty index
or a missing config: it prints nothing and exits 0. A hook that errors in front
of the user on an unrelated turn is worse than one that says nothing.

**How many passages it injects adapts to how sure the ranking is.** When the
runner-up sits within `hook.margin_threshold` (default `0.02`) of the best
passage, the ordering is not decisive, so the contenders go over together — up
to `hook.max_passages` (default `3`). A decisive lead sends one.

That rule is measured, not guessed. Always injecting one passage is right 83.3 %
of the time on the benchmark corpus; always injecting three is right 94.4 %.
Widening only on a thin margin reaches the same 94.4 % while widening on 6
prompts out of 18 — **1.67 passages and 108 tokens on average**, against a 1411
token corpus. It works even though decisive and undecided cases overlap, because
widening a case that was already right costs tokens and never accuracy.

The default threshold is measured, not chosen: on the benchmark corpus the 18
project questions scored 0.542 and above for their best passage, while 8
off-topic prompts peaked at 0.488. That 0.054 margin is thin, so treat 0.5 as a
defensible starting point and re-calibrate for your own corpus — `mise
bench:tokens` reports the firing rate on real questions **and** the false-fire
rate on off-topic prompts, which is the half of the calibration a threshold
tuned only on real questions never sees.

### Machine-readable output

Every subcommand that returns a result accepts `--json` — `index`, `search`, `status`, `delete`, `context`, `info`, `daemon status`, `daemon stop`. `serve` and `prompt-hook` do not: one streams a protocol, the other writes a passage for a client hook to consume verbatim., emitting its result as a single JSON object on stdout:

```sh
$ mnemodoc-server status --json
{"version":"1.0.0 (c47d61c)","db_path":"/path/.mnemodoc/index.db","files":12,"chunks":86,"ollama":{"host":"http://localhost:11434","model":"nomic-embed-text"}}

$ mnemodoc-server search "retry policy" --json | jq -r '.results[0].content'
```

`search --json` carries the chunk bodies that the table omits, under the same key names as the `query_documents` MCP tool (`file`, `heading`, `parent_heading`, `content`, `score`) so both surfaces speak one vocabulary.

**Errors** under `--json` are emitted as `{"error": "..."}` on **stderr**, with stdout left empty and exit code 1 — stdout only ever carries results, so parsing it cannot swallow a failure.

**Payloads evolve additively**: fields may be added, never removed or renamed. There is no schema version to negotiate.

`--quiet` prints nothing at all and reports through the exit code. It is available where that is meaningful — `index`, `delete`, `init`, `uninit`, `install`, `uninstall`, `daemon status`, `daemon stop`.

Two commands exit non-zero on an outcome rather than on a crash. `daemon status` exits 1 when no daemon is running, in the manner of `systemctl is-active`, which is what makes `mnemodoc-server daemon status --quiet && …` usable. `index` exits 1 when chunks failed to embed and **nothing at all** was indexed — an unreachable Ollama, most often. A run with simply nothing to do still exits 0, and the JSON payload carries a `failed` counter either way. Under `--quiet` the exit code is the whole report, which is exactly why that case must not read as success.

`daemon stop` probes the daemon's socket before signalling anything: if nothing answers, it removes the stale socket and pid file and reports that no daemon is running, rather than risking a `SIGTERM` to an unrelated process that inherited a dead daemon's pid. If the daemon does not exit within `--timeout` seconds the command says so and stops — it never escalates to `SIGKILL` against a process holding an open SQLite database.

## Finding the project

The `.mnemodoc/` directory is what marks a directory as a MnemoDoc project —
not the YAML file. Every command without an explicit `--config` walks up from
the working directory to the nearest one and anchors itself there: the index,
the daemon socket, the configuration and the paths in it all resolve against
that project root, whatever directory you happen to be standing in.

This is what makes a single global registration work. The client launches the
server in the project it opened; the server finds the project from there. A
directory with no marker above it is simply not a MnemoDoc project: the server
runs, creates nothing, and says so.

`.mnemodoc.yml` is versionable and describes the project; `.mnemodoc/` is local,
git-ignored, and holds the index. A fresh clone therefore carries the
configuration but no index, and stays inert until someone runs `init` — indexing
stays a decision, never a side effect of opening a session.

An explicit `--config` overrides all of this: its own directory becomes the
project root.

## MCP tools

| Tool | Required args | Optional args | Returns |
|---|---|---|---|
| `query_documents` | `query` (string) | `top_k` (int), `mode` (hybrid\|semantic\|keyword) | chunks with file, heading, parent_heading, content, score; total_candidates, query_time_ms, mode |
| `ingest_path` | `path` (string) | — | indexed, skipped, pruned, failed counts |
| `list_files` | — | — | list of indexed files with metadata |
| `delete_file` | `path` (string) | — | confirmation |
| `status` | — | — | version, chunk_count, file_count, model, search_mode, db_path |
| `get_project_context` | — | `files` (string[]), `task` (string), `query` (string) | the selected role's markdown (text) + structured `role`, `reason`, `score`, `candidates` |

`query_documents` optional args override the config values for that request only.

`get_project_context` is the in-session, on-demand half of the contextual-role system — see [Contextual roles & the PreToolUse hook](#contextual-roles--the-pretooluse-hook).

## Behaviour notes

**Per-project daemon with auto-spawning proxy** — by default (`server.daemon: true`), `serve --stdio` does not serve MCP directly. It acts as a thin proxy to a per-project background daemon that owns the SQLite index. On the first connection the proxy spawns the daemon automatically and waits for it (up to 30 s). Subsequent `serve --stdio` sessions from any client (Zed, Claude Code, parallel agent sessions) all connect to the same daemon; only one process ever touches the index, eliminating concurrent-write and duplicate-indexing races. The daemon exits automatically after `server.daemon_idle_timeout` seconds of inactivity (default 600 s / 10 min) and is re-spawned on the next request. The socket, lock and pid files live beside the index DB (`daemon.sock`, `daemon.lock`, `daemon.pid`); `daemon status` and `daemon stop` drive the daemon from the CLI. No client configuration changes are needed — clients still launch `serve --stdio` exactly as before. If the daemon dies mid-session the proxy self-heals (re-spawns under a file lock, ≤ 3 attempts); on exhaustion it falls back to an in-process standalone handler for the rest of that session — no re-indexing, serving the existing on-disk index only. Set `server.daemon: false` to opt out and revert to the standalone stdio server.

**Live re-indexing (daemon)** — while the daemon runs it watches the configured `paths` and re-indexes a document within ~1 s of it being created, modified, or deleted (polling, via the `file_watcher` shard). Enabled by default (`server.daemon_watch: true`); tune the cadence with `server.daemon_watch_interval` (seconds) or set `daemon_watch: false` to keep boot-time indexing only. Only the daemon watches; the standalone stdio fallback does not.

**Auto-indexing on startup** — `serve` automatically re-indexes all `paths` from the config in the background. The server is immediately responsive; indexing happens concurrently. Files whose mtime hasn't changed since the last run are skipped, so restarts are cheap.

### The prompt hook

`prompt-hook` reads a client hook payload on standard input and injects the best matching passage on `UserPromptSubmit`, so documentation reaches the agent whether or not it thinks to search:

```bash
mnemodoc-server prompt-hook --config /path/to/project/.mnemodoc.yml || true
```

It gates on **cosine similarity**, not on the fused search score — the latter is a rank artifact, identical for the top hit of an off-topic query and of a targeted one. `hook.similarity_threshold` decides whether to inject at all; `hook.margin_threshold` decides how many, a runner-up within that distance meaning the ranking is not decisive; `hook.max_passages` caps the set. Every default is measured on the benchmark corpus rather than chosen — `mise bench:tokens` reports the firing rate, the false-firing rate on off-topic prompts, and how often the injected set actually contains the answer. Re-calibrate per corpus.

Every failure path is silent and exits 0 by design: this runs synchronously in front of the user, and a hook that errors on an unrelated turn is worse than one that says nothing.

`mnemodoc-server info --licenses` prints the third-party licence texts baked into the binary — the notices its statically linked dependencies require when the binary is redistributed on its own.

### Environment overrides

Every setting can be overridden without editing the YAML, which is what makes a systemd unit or a container image configurable: `MNEMODOC_OLLAMA_HOST`, `MNEMODOC_OLLAMA_MODEL`, `MNEMODOC_OLLAMA_TIMEOUT`, `MNEMODOC_OLLAMA_BATCH_SIZE`, `MNEMODOC_SEARCH_TOP_K`, `MNEMODOC_SEARCH_MODE`, `MNEMODOC_SEARCH_BACKEND`, `MNEMODOC_SEARCH_RECENCY_DAYS`, `MNEMODOC_SEARCH_RECENCY_BOOST`, `MNEMODOC_SEARCH_KEYWORD_WEIGHT`, `MNEMODOC_QDRANT_URL`, `MNEMODOC_QDRANT_API_KEY`, `MNEMODOC_QDRANT_COLLECTION`, `MNEMODOC_HOOK_THRESHOLD`, `MNEMODOC_HOOK_MARGIN`, `MNEMODOC_HOOK_MAX_PASSAGES`, `MNEMODOC_SERVER_SSE_HOST`, `MNEMODOC_SERVER_SSE_PORT`, `MNEMODOC_SERVER_LOG_FILE`, `MNEMODOC_SERVER_LOG_LEVEL`, `MNEMODOC_SERVER_DAEMON`, `MNEMODOC_SERVER_IDLE_TIMEOUT`, `MNEMODOC_SERVER_DAEMON_WATCH`, `MNEMODOC_SERVER_WATCH_INTERVAL`, `MNEMODOC_DB_PATH`, `MNEMODOC_INDEX_CONCURRENCY`, `MNEMODOC_INDEX_PDF`, `MNEMODOC_INDEX_MAX_FILE_SIZE`, `MNEMODOC_CHUNKING_STRIP_LINK_ONLY_LINES`, `MNEMODOC_CHUNKING_MERGE_PREAMBLE`, `MNEMODOC_EXCLUDE`.

Booleans accept `true/1/yes/on` in any case. A value that cannot be read — a non-numeric count, an unrecognised boolean — is reported by the startup validation alongside every other configuration problem, and the previous value is kept rather than silently replaced by zero.

**`ingest_path` refuses two things**, both to protect the index rather than to be strict. A path outside the roots listed under `paths:` is rejected: the indexed corpus is also what an agent reads, so a document that asks it to index `~/.aws/credentials` would otherwise get its way — add the directory to `paths:` to make it indexable. And a partial ingest is rejected when the configured embedding model no longer matches the one the stored vectors were built with: that invalidates every vector, so the index has to be rebuilt whole rather than half-refilled from one path.

**Chunking noise reduction (opt-in)** — docs that open each file with a navigation block (a breadcrumb of links plus a one-line description) otherwise turn that preamble into a keyword-rich but answer-less chunk that squats `top_k` slots. Two generic, config-driven options under `chunking:` (both default `false`, so the index is unchanged without them) address this: `strip_link_only_lines` drops lines made up solely of inline links and separators (e.g. `← [Index](…) — [Map](…)`) before chunking, while keeping any line that carries real text — it covers the line-based markup formats that feed raw markup into chunks (Markdown, Org-mode `[[…][…]]`, AsciiDoc `link:`/`xref:`/`<<…>>`/URLs, reStructuredText `` `text <url>`_ ``) and is a deliberate no-op for DOM/Office formats (HTML, `.docx`, `.odt`, EPUB, …), which flatten links to plain text (use `merge_preamble_into_first_section` for those); `merge_preamble_into_first_section` folds the pre-heading preamble into the first section's chunk instead of emitting it standalone. Re-index after changing either (run `ingest_path` or a full re-index) for the new chunks to take effect.

**Config paths resolve relative to the config file** — `doc/claude/` in `.mnemodoc.yml` is resolved relative to the directory that contains the config file, not the process working directory. Move the config file and the paths move with it.

**Index location** — by default the index lives in `.mnemodoc/index.db`, in the directory holding the config file. That directory also holds the SQLite WAL files and the daemon's socket and lock, and receives a self-ignoring `.gitignore` on creation, so none of it can be committed by accident. Keeping the index inside the project makes it discoverable, ties its lifetime to the project, and lets it survive a rename or a move of the project directory. Set `db.path` to put the database anywhere else — useful when the project directory is read-only, lives in a folder synchronised by Dropbox/iCloud (which can corrupt a SQLite database in WAL mode), or is wiped by `git clean -xdf`. An explicit `db.path` is used verbatim and gets no `.gitignore`.

**Model mismatch** — if you change `ollama.model` in the config, re-index before querying. Vectors from different models have incompatible dimensions and will silently score near-zero. `query_documents` emits a `warning` field in the response when it detects a mismatch.

**Streaming ingest** — MCP clients that support progress reporting can send `Accept: text/event-stream` with a `tools/call ingest_path` request. The server streams `notifications/progress` events per file indexed, followed by the final result frame. Include `_meta.progressToken` in the request arguments to receive progress notifications:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "ingest_path",
    "arguments": {
      "path": "/your/docs",
      "_meta": { "progressToken": "my-token" }
    }
  }
}
```

## Contextual roles & the PreToolUse hook

Most doc-RAG servers stop at "the agent can search the docs." The problem: **the agent only retrieves what it already knows to look for.** A convention it has never heard of is the one it will never query — and on-demand retrieval is the first thing sacrificed when the context window fills up. The conventions you most need enforced are exactly the ones that slip through.

mnemodoc-server closes that gap with a **role-selection engine** that runs through two channels sharing one codepath:

- **On-demand (in session)** — the `get_project_context` MCP tool. The agent calls it and adopts the returned role. Convenient, but only fires when the agent thinks to call it.
- **Mechanical (out of session)** — the `mnemodoc-server context` CLI command, designed to be driven by a Claude Code **`PreToolUse` hook**. The hook runs as a subprocess before *every* `Edit`/`Write`, outside the agent's cognitive loop, so the right conventions are injected **whether or not the agent asks**. Because a hook runs out of session it can't call an MCP tool — the CLI gives it the same selection engine through a command-line channel.

Same engine, two entry points. You get reliable, automatic guidance and explicit on-demand lookups, with no second copy of the selection logic to keep in sync.

### Defining roles

Add a `context:` section to `.mnemodoc.yml`. Each role points at a Markdown file (its instructions) plus trigger lists on three axes — the files being edited, the kind of task, and the user's query. Role paths resolve relative to the config file, like `paths`.

```yaml
context:
  # Optional fallback when no rule fires and there is no signal to arbitrate.
  default: doc/claude/roles/generalist.md
  # Rule score a prompt must reach for the query channel to inject anything.
  # Default 1: one keyword is enough. Raise it where one keyword is too thin.
  min_query_score: 1
  # Match when_task/when_query keywords as whole words. Default true.
  word_boundaries: true
  roles:
    - file: doc/claude/roles/backend.md
      description: Backend conventions — operations, persistence, policies
      when_files: ["app/concepts/**", "app/models/**", "app/policies/**"]
      when_task:  ["implement", "refactor"]
      when_query: ["operation", "policy", "persistence"]
    - file: doc/claude/roles/frontend.md
      description: Stimulus controllers, Turbo Streams, HAML views
      when_files: ["app/frontend/**", "app/views/**"]
      when_query: ["stimulus", "turbo", "view"]
```

**Selection algorithm.** Rule hits are scored (files ×3, task ×2, query ×1). A clear winner — above a confidence threshold and ahead of the runner-up by a margin — wins outright. When rules are ambiguous, the engine doesn't guess: it embeds the bundle (files + task + query) and breaks the tie by cosine similarity against each role's `description`. With no signal at all, it falls back to `default`. The result is rule-fast when rules are decisive and embedding-smart only when they aren't.

The tie-break only ever ranks roles that **actually matched a rule**. Similarity against a `description` says nothing about whether a role applies, so arbitrating among roles that matched nothing returns an arbitrary one — which is what a conversational prompt carrying one incidental technical word used to get.

**Keywords match whole words.** `when_task` and `when_query` fire on word boundaries, Unicode-aware, so `test` does not fire inside `tester` or `attestation`, and an accented keyword is bounded like any other. Set `word_boundaries: false` to restore plain substring matching.

**The query channel can require more than one signal.** `min_query_score` is the rule score a prompt must reach before `UserPromptSubmit` injects anything; below it the channel stays **silent** rather than falling back to the default role, since an unsolicited injection on every conversational turn costs context for nothing. The files channel is never gated: an edited file is a strong, unambiguous signal. The `get_project_context` MCP tool is not gated either — the agent asked for it deliberately, which is not the same thing as a hook firing on every turn.

### Wiring the hook

`mnemodoc-server install` registers this hook for you, pointing straight at the
binary. The rest of this section describes what it writes, and how to wire it by
hand for a client `install` does not cover.

Register a `PreToolUse` hook in `.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "bin/mnemodoc-hook" }
        ]
      }
    ]
  }
}
```

A hook now only needs to **pipe the payload straight to the CLI** — the
`--hook-stdin` flag makes `mnemodoc-server context` read the client's hook JSON,
derive the edited file (PreToolUse) or the user query (UserPromptSubmit), and
record the originating session/agent in its audit log. The CLI exits non-zero on
any selection failure (no roles, no signal, Ollama down); the hook script's
`|| true` wrapper absorbs that exit code, ensuring silent degradation so a
missing RAG never warns or blocks an edit.

```sh
#!/usr/bin/env sh
# bin/mnemodoc-hook — forward the hook payload to the role selector.
# `|| true` keeps the hook silent: a failed selection (no roles, no signal, Ollama
# down) must never surface a warning or block the edit.
mnemodoc-server context --hook-stdin --config .mnemodoc.yml || true
```

For clients other than Claude Code, pass `--client <name>` (only `claude-code`
ships today) or keep the explicit flags form as the portable fallback:
`mnemodoc-server context --files <path> --config .mnemodoc.yml`.

### Full setup examples

[`examples/`](examples/) has copy-paste setup guides on two axes: per **AI client**
(Claude Code, GitHub Copilot, Cursor, Windsurf, Zed — including a capability matrix of
which layers each one supports) and per **framework** (Rails, Laravel, Symfony, Django
— the `.mnemodoc.yml` role map). Pick one of each. Start at [`examples/README.md`](examples/README.md).

## Deployment

### systemd

To run as a systemd service (SSE mode), create `/etc/systemd/system/mnemodoc-server.service`:

```ini
[Unit]
Description=mnemodoc-server
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/mnemodoc-server serve --sse --config /path/to/.mnemodoc.yml
Restart=on-failure
WatchdogSec=30

[Install]
WantedBy=multi-user.target
```

```sh
systemctl daemon-reload
systemctl enable --now mnemodoc-server
```

The server sends `READY=1` once the startup index pass completes and `STOPPING=1` on `SIGTERM`. Log rotation via `SIGUSR1` is supported for use with `logrotate`.

The HTTP transport also exposes `GET /health` — a lightweight liveness probe that returns `200 OK`. Use it in `ExecStartPost` healthchecks or load balancer probes.

## Development

Requires: Crystal, mise, Ollama (native or Docker). The `sqlite-vec` vector
extension is a git submodule, so clone with `--recurse-submodules` (or run
`git submodule update --init` in an existing checkout) before building.

```sh
git clone --recurse-submodules <repo-url>
mise dev:ollama  # start Ollama (macOS native, Metal GPU) + pull model
mise dev:deps    # install dependencies
mise dev:spec    # run tests
mise dev:check   # build + lint + test
```

See [CLAUDE.md](CLAUDE.md) for full development guide.

### Measuring what it saves

`mise bench:tokens` quantifies the project's central claim: that fetching
relevant passages on demand costs less than loading the whole documentation set
at every session start.

```
Unit          : exact (count_tokens, model claude-opus-5)
Baseline      : 1411 (whole corpus, loaded every session)
Retrieved     : mean 302.8, median 314.5 (top-5)
Saving        : 78.5 %
Recall        : 94.4 % of 18 questions
```

**A saving is never reported without its recall**, because it would be
meaningless: returning nothing is a 100 % saving and a total failure. The
harness runs a hand-annotated question set — each question names the file and
heading that holds its answer — and measures whether the search returns that
passage in the top-K. A run whose recall is zero is printed as **not
meaningful** and exits non-zero, so no script can mistake it for a good result.

It runs against a fixture corpus committed under `bench/corpus/`, not against
real documentation: absolute figures from an artificial corpus mean little, but
their *evolution between versions* is comparable, which is what makes the
harness useful as a regression guard.

Counting uses Anthropic's `count_tokens` endpoint, which is free and
rate-limited separately from message creation. Put `ANTHROPIC_API_KEY` in a
git-ignored `.env` (mise loads it) for exact token counts. Without a key the
harness still runs, counting characters instead and saying so in its output —
ratios stay meaningful, absolute values are not tokens. Ollama is required
either way, since the corpus has to be embedded before it can be searched.

```sh
mise bench:tokens                       # human-readable report
mise bench:tokens -- --json             # machine-readable
mise bench:tokens -- --top-k 3          # fewer passages per question
mise bench:tokens -- --model claude-sonnet-5   # another tokenizer
```

## Alternatives

| Project | Language | Vector store | Embeddings | Chunking |
|---|---|---|---|---|
| [qpd-v/mcp-ragdocs](https://github.com/qpd-v/mcp-ragdocs) | TypeScript | Qdrant | Ollama / OpenAI | Fixed tokens |
| [sanderkooger/mcp-server-ragdocs](https://github.com/sanderkooger/mcp-server-ragdocs) | TypeScript | Qdrant | Ollama / OpenAI | Fixed tokens |
| [Zackriya-Solutions/MCP-Markdown-RAG](https://github.com/Zackriya-Solutions/MCP-Markdown-RAG) | Python | Milvus | Local | Fixed tokens |
| [Daniel-Barta/mcp-rag-server](https://github.com/Daniel-Barta/mcp-rag-server) | Python | In-memory | OpenAI | Fixed tokens |

**Why mnemodoc-server differs:**

- **Zero runtime dependencies** — static binary, no Node, no Python, no external vector database
- **SQLite + vec0 by default** — vector KNN runs in-process via `sqlite-vec` (pinned upstream submodule, linked statically); no external vector DB required to run (Qdrant is opt-in, not bundled — see *Pluggable vector backend*)
- **Multi-format, section-aware chunking** — Markdown/MDX, Org, AsciiDoc, reStructuredText, HTML, Jupyter notebooks, plain text, Office & e-book documents (`.docx`, `.odt`, `.pptx`, `.odp`, `.epub`, stdlib-only) and (opt-in) PDF, each split at its own heading boundaries instead of arbitrary token counts
- **Hybrid search** — semantic (vec0 KNN) + keyword (FTS5 / BM25) fused with RRF, with a recency bias option
- **Ollama only** — intentionally local-first; no OpenAI key required or supported
- **Mechanical context injection** — the projects above are search-on-demand only; mnemodoc-server adds a role-selection engine reachable from a `PreToolUse` hook, so conventions land before every edit instead of waiting for the agent to query

## Contributing

Contributions welcome. See [CLAUDE.md](CLAUDE.md) for the full development guide.

Both search signals are now index-backed and no longer scale linearly with the
corpus: semantic search uses a **vec0 KNN index** (`sqlite-vec`, pinned upstream
submodule, linked statically) and keyword search uses a **SQLite FTS5 / BM25
index**. Neither path
loads the whole corpus into RAM — only the matched files' chunks are hydrated on
demand. No specific scaling work is outstanding; profile before adding more.

## License

MIT
