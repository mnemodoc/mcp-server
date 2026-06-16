# Cursor — RAG + glob-scoped rules (no dynamic injection)

Cursor gives you **layer 2 (RAG) and layer 0 (baseline)** directly. **Layer 1
degrades**: Cursor *has* a hook system, but its hooks are **allow/deny/post-process
only — they cannot inject context**. So the dynamic "compute the role from the path
and push it before the edit" trick from Claude Code is **not reproducible**. The
fallback is **static, glob-scoped rules**.

Verified against the official docs (June 2026):
[MCP](https://cursor.com/docs/context/mcp) ·
[Rules](https://cursor.com/docs/context/rules) ·
[Hooks](https://cursor.com/docs/agent/hooks).

## Layer 2 — RAG on demand (MCP)

`.cursor/mcp.json` (project) or `~/.cursor/mcp.json` (global), key `mcpServers`:

```json
{
  "mcpServers": {
    "mnemodoc": {
      "command": "mnemodoc-server",
      "args": ["serve", "--config", ".mnemodoc.yml"]
    }
  }
}
```

Transports: stdio, SSE, Streamable HTTP. The agent calls `query_documents` on demand,
exactly as in Claude Code. **This is the part that works identically everywhere.**

## Layer 1 — static glob rules (the degradation)

Cursor's hooks (`afterFileEdit`, `beforeReadFile`, `beforeSubmitPrompt`, …) return
`allow`/`deny`/blocking decisions — **no `additionalContext` channel**. You cannot
drive `mnemodoc-server context` into the agent's context before an edit.

Instead, map each domain role to an **Auto-Attached rule** in `.cursor/rules`
(`.mdc` files), scoped by `globs`. When the agent touches a matching file, the rule's
content is injected:

```text
---
description: Authorization — Pundit policies and scopes
globs: app/policies/**
alwaysApply: false
---
# Role: Authorization & policies

You write Pundit authorization rules.
- One predicate per action; check inheritance before redefining.
- Restrict listings with a Scope (`resolve`) — never `all` for non-admins.
- For detail, query the mnemodoc RAG (`query_documents`).
```

Trade-off vs Claude Code: the role content is **frozen in the `.mdc`**, not computed
by a hook that queries the live index. You keep "right context for this file," you
lose "dynamically resolved + always in sync with the index." Write one `.mdc` per
domain, mirroring your `.mnemodoc.yml` roles (the framework guide lists them).

> Cursor still benefits from the role *engine* via MCP: the agent can call
> `get_project_context` on demand. The static rules just guarantee a floor.

## Layer 0 — baseline

An **Always-Apply** rule (`alwaysApply: true`, no `globs`) is injected into every
chat — put the baseline there. `AGENTS.md` at the root works as well.

## Recap

| Layer | Mechanism | Files |
| --- | --- | --- |
| 0 — baseline | Always-Apply rule / `AGENTS.md` | `.cursor/rules/*.mdc`, `AGENTS.md` |
| 1 — role injection | **static** Auto-Attached rules (glob) — no dynamic hook | `.cursor/rules/<domain>.mdc` |
| 2 — RAG | MCP server (stdio/HTTP) | `.cursor/mcp.json`, `.mnemodoc.yml` |

Pair with a [framework guide](../README.md): use its `when_files` globs as the
`globs:` of your `.mdc` rules.
