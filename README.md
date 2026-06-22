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

**3. Create a config in your project**

```sh
# Download the example config
curl -fsSL https://raw.githubusercontent.com/mnemodoc/mcp-server/master/.mnemodoc.example.yml \
  -o .mnemodoc.yml

# Then edit .mnemodoc.yml to set your doc paths
```

**4. Index your docs and test** *(optional — `serve` auto-indexes on startup)*

```sh
mnemodoc-server index doc/ --config .mnemodoc.yml
mnemodoc-server search "how to persist a model" --config .mnemodoc.yml
```

**5. Add to your MCP client**

*Claude Code* (`~/.claude/settings.json`) — stdio transport, no network exposure:

```json
{
  "mcpServers": {
    "doc": {
      "command": "mnemodoc-server",
      "args": ["serve", "--config", "/path/to/project/.mnemodoc.yml"]
    }
  }
}
```

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

## CLI

```sh
mnemodoc-server serve [--config .mnemodoc.yml]                        # Claude Code (stdio, default)
mnemodoc-server serve --sse [--port 8765] [--host 127.0.0.1]             # Cursor / other clients
mnemodoc-server index <path>                                               # Index a file or directory
mnemodoc-server search "<query>" [--mode hybrid|semantic|keyword] [--top 5] # Test search from terminal
mnemodoc-server status                                                     # Index stats
mnemodoc-server delete <path>                                              # Remove from index
mnemodoc-server context [--files <path>]... [--task <kind>] [--query "<text>"] # Resolve & print the role to adopt
mnemodoc-server info                                                       # Version info
```

## MCP tools

| Tool | Required args | Optional args | Returns |
|---|---|---|---|
| `query_documents` | `query` (string) | `top_k` (int), `mode` (hybrid\|semantic\|keyword) | chunks with file, heading, parent_heading, content, score; total_candidates, query_time_ms, mode |
| `ingest_path` | `path` (string) | — | indexed, skipped, pruned counts |
| `list_files` | — | — | list of indexed files with metadata |
| `delete_file` | `path` (string) | — | confirmation |
| `status` | — | — | version, chunk_count, file_count, model, search_mode, db_path |
| `get_project_context` | — | `files` (string[]), `task` (string), `query` (string) | the selected role's markdown (text) + structured `role`, `reason`, `candidates` |

`query_documents` optional args override the config values for that request only.

`get_project_context` is the in-session, on-demand half of the contextual-role system — see [Contextual roles & the PreToolUse hook](#contextual-roles--the-pretooluse-hook).

## Behaviour notes

**Per-project daemon with auto-spawning proxy** — by default (`server.daemon: true`), `serve --stdio` does not serve MCP directly. It acts as a thin proxy to a per-project background daemon that owns the SQLite index. On the first connection the proxy spawns the daemon automatically and waits for it (up to 30 s). Subsequent `serve --stdio` sessions from any client (Zed, Claude Code, parallel agent sessions) all connect to the same daemon; only one process ever touches the index, eliminating concurrent-write and duplicate-indexing races. The daemon exits automatically after `server.daemon_idle_timeout` seconds of inactivity (default 600 s / 10 min) and is re-spawned on the next request. The socket and lock file live beside the index DB (`daemon.sock`, `daemon.lock`). No client configuration changes are needed — clients still launch `serve --stdio` exactly as before. If the daemon dies mid-session the proxy self-heals (re-spawns under a file lock, ≤ 3 attempts); on exhaustion it falls back to an in-process standalone handler for the rest of that session — no re-indexing, serving the existing on-disk index only. Set `server.daemon: false` to opt out and revert to the standalone stdio server.

**Live re-indexing (daemon)** — while the daemon runs it watches the configured `paths` and re-indexes a document within ~1 s of it being created, modified, or deleted (polling, via the `file_watcher` shard). Enabled by default (`server.daemon_watch: true`); tune the cadence with `server.daemon_watch_interval` (seconds) or set `daemon_watch: false` to keep boot-time indexing only. Only the daemon watches; the standalone stdio fallback does not.

**Auto-indexing on startup** — `serve` automatically re-indexes all `paths` from the config in the background. The server is immediately responsive; indexing happens concurrently. Files whose mtime hasn't changed since the last run are skipped, so restarts are cheap.

**Chunking noise reduction (opt-in)** — docs that open each file with a navigation block (a breadcrumb of links plus a one-line description) otherwise turn that preamble into a keyword-rich but answer-less chunk that squats `top_k` slots. Two generic, config-driven options under `chunking:` (both default `false`, so the index is unchanged without them) address this: `strip_link_only_lines` drops lines made up solely of inline links and separators (e.g. `← [Index](…) — [Map](…)`) before chunking, while keeping any line that carries real text — it covers the line-based markup formats that feed raw markup into chunks (Markdown, Org-mode `[[…][…]]`, AsciiDoc `link:`/`xref:`/`<<…>>`/URLs, reStructuredText `` `text <url>`_ ``) and is a deliberate no-op for DOM/Office formats (HTML, `.docx`, `.odt`, EPUB, …), which flatten links to plain text (use `merge_preamble_into_first_section` for those); `merge_preamble_into_first_section` folds the pre-heading preamble into the first section's chunk instead of emitting it standalone. Re-index after changing either (run `ingest_path` or a full re-index) for the new chunks to take effect.

**Config paths resolve relative to the config file** — `doc/claude/` in `.mnemodoc.yml` is resolved relative to the directory that contains the config file, not the process working directory. Move the config file and the paths move with it.

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

### Wiring the hook

Register a `PreToolUse` hook in your project's `.claude/settings.json` (the hook script itself lives in your project, not in this repo):

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

A minimal hook reads the tool payload on stdin, extracts the edited path, calls the CLI, and prints the role to stdout — which Claude Code injects as context. **It must degrade silently** (`exit 0`) when the server or Ollama is unavailable, so a missing RAG never blocks an edit:

```python
#!/usr/bin/env python3
import json, sys, subprocess
try:
    file_path = json.load(sys.stdin).get("tool_input", {}).get("file_path", "")
except Exception:
    sys.exit(0)
if not file_path:
    sys.exit(0)
try:
    result = subprocess.run(
        ["mnemodoc-server", "context", "--files", file_path, "--config", ".mnemodoc.yml"],
        capture_output=True, text=True, timeout=5,
    )
    if result.returncode == 0 and result.stdout.strip():
        print(f"[mnemodoc] role for {file_path}:\n{result.stdout}")
except Exception:
    pass
sys.exit(0)
```

The CLI prints the selected role's Markdown to stdout and exits 0; on any failure (no roles, no signal, missing role file, Ollama down) it writes a short message to stderr and exits non-zero, so callers can degrade cleanly.

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
