# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/mnemodoc/mcp-server/releases/tag/v1.0.0
