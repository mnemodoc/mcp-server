# Zed — RAG + baseline (no layer 1)

Zed covers **layer 2 (RAG)** and **layer 0 (baseline)** natively, but has **no layer 1**:
there are no native agent hooks (only a proposal — zed-industries/zed#57943), and the
project instructions file isn't glob-scoped. So on Zed you get on-demand retrieval
plus an always-on baseline, and that's it.

Verified against the official docs (June 2026):
[MCP](https://zed.dev/docs/ai/mcp) ·
[Instructions](https://zed.dev/docs/ai/instructions) ·
[Tasks](https://zed.dev/docs/tasks).

## Layer 2 — RAG on demand (MCP / "context servers")

Zed calls MCP servers **context servers**, configured under `context_servers` in
`settings.json`:

```json
{
  "context_servers": {
    "mnemodoc": {
      "command": "mnemodoc-server",
      "args": ["serve", "--config", ".mnemodoc.yml"],
      "env": {}
    }
  }
}
```

Remote servers use a `url` + `headers` form instead. Zed supports MCP **Tools** and
**Prompts** (not Resources), which is all mnemodoc needs — the agent calls
`query_documents` on demand.

> A `zed-mnemodoc` extension exists that packages the server as a Zed extension; the
> raw `context_servers` config above works without it.

## Layer 1 — not available

Zed has no hook that fires before an edit with the file path, and no glob-scoped
rules — so neither the dynamic injection (Claude Code) nor the static glob fallback
(Cursor/Windsurf) is reproducible today. The proposed `pre_tool_use` / `session_start`
hooks in issue #57943 are **not implemented**. (Zed *tasks* have a `hooks` field, but
its only event is `create_worktree` — unrelated to the agent.)

In practice: rely on layer 2 (the agent queries the index) and put the most important
conventions in the baseline (layer 0), since you can't scope them per file.

## Layer 0 — baseline

Zed loads one project instructions file from the root (first match wins): `.rules`,
`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, … as **always-on** context. Put the baseline
rules there.

## Recap

| Layer | Mechanism | Files |
| --- | --- | --- |
| 0 — baseline | always-on project instructions | `AGENTS.md` / `.rules` |
| 1 — role injection | **not available** (no agent hooks, no glob rules) | — |
| 2 — RAG | context server (stdio/HTTP) | `settings.json` → `context_servers`, `.mnemodoc.yml` |

Pair with a [framework guide](../README.md) for the `.mnemodoc.yml` role map (still
used by the layer-2 `get_project_context` tool).
