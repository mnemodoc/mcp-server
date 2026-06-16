# Windsurf (Cascade) — RAG + glob rules (no dynamic injection)

Like Cursor, Windsurf gives you **layer 2 (RAG)** fully and **layer 1 only as static
glob rules**. Windsurf's hooks *do* fire before an edit (`pre_write_code` even
receives the file path), but **their stdout is not re-injected into the model's
context** — a pre-hook can only *block* (via `stderr` + exit 2). So dynamic role
injection is **not reproducible**; the fallback is static rules.

Verified against the official docs (June 2026):
[Cascade MCP](https://docs.windsurf.com/plugins/cascade/mcp) ·
[Cascade Hooks](https://docs.windsurf.com/windsurf/cascade/hooks) ·
[Memories & Rules](https://docs.windsurf.com/windsurf/cascade/memories).

> Note: since the Cognition acquisition, `docs.windsurf.com` redirects to
> `docs.devin.ai` and the product is also branded "Devin Desktop"; the `~/.codeium/`
> and `.windsurf/` paths still apply.

## Layer 2 — RAG on demand (MCP)

`~/.codeium/mcp_config.json`, key `mcpServers`. Use an **absolute** path to the
config (this is a user-level file):

```json
{
  "mcpServers": {
    "mnemodoc": {
      "command": "mnemodoc-server",
      "args": ["serve", "--config", "/abs/path/to/project/.mnemodoc.yml"]
    }
  }
}
```

Transports: stdio, Streamable HTTP, SSE. Cascade calls `query_documents` on demand.

## Layer 1 — static glob rules (the degradation)

`pre_write_code` (in `.windsurf/hooks.json`) gets `file_path` + `edits`, but can only
block — its stdout never reaches the model. So map roles to **rules** in
`.windsurf/rules/*.md`, scoped with `trigger: glob`:

```text
---
trigger: glob
globs: app/policies/**
---
# Role: Authorization & policies

You write Pundit authorization rules.
- One predicate per action; check inheritance before redefining.
- Restrict listings with a Scope (`resolve`).
- For detail, query the mnemodoc RAG (`query_documents`).
```

Activation modes: `always_on`, `model_decision` (description-gated), `glob`, `manual`.
As with Cursor, the content is **static** — one rule file per domain, mirroring your
`.mnemodoc.yml` roles.

## Layer 0 — baseline

No `SessionStart` hook. Use **always-on rules**: `~/.codeium/windsurf/memories/global_rules.md`
(global) or `.windsurf/rules/*.md` with `trigger: always_on` (workspace). The legacy
`.windsurfrules` at the project root still works.

## Recap

| Layer | Mechanism | Files |
| --- | --- | --- |
| 0 — baseline | `always_on` rules / `global_rules.md` | `.windsurf/rules/*.md`, `~/.codeium/windsurf/memories/global_rules.md` |
| 1 — role injection | **static** `trigger: glob` rules — no dynamic hook | `.windsurf/rules/<domain>.md` |
| 2 — RAG | MCP server (stdio/HTTP) | `~/.codeium/mcp_config.json`, `.mnemodoc.yml` |

Pair with a [framework guide](../README.md): use its `when_files` globs as the
`globs:` of your rules.
