# Examples — wiring mnemodoc into your project

mnemodoc-server is **AI-client agnostic**: it speaks MCP, so the RAG half works
in any MCP-capable coding agent. What differs from one client to the next is how
much of the *mechanical context injection* (the role engine) you can wire up —
because that part rides on each client's hook/rules system, and those vary a lot.

These guides are split on two **orthogonal axes**. Pick one from each:

- **`clients/`** — how to wire the three layers into a given AI client (the hook
  and MCP plumbing). Client-specific, framework-independent.
- **`frameworks/`** — the `.mnemodoc.yml` role map for a given stack (which folders
  map to which domain role). Framework-specific, client-independent.

> Pick your **client** guide for the plumbing, and your **framework** guide for the
> roles. They compose: the framework's `.mnemodoc.yml` is the same whether you run
> Claude Code or Cursor; the hook wiring is the same whether you write Rails or Django.

## The pattern — three layers

Loading all your docs at every session is expensive and unreliable (bulk context
gets compacted away, and the agent only retrieves what it already knows to ask
for). Instead, context arrives in three layers:

| Layer | What | When it fires |
| --- | --- | --- |
| **0 — Baseline** | The few rules you can't afford the agent to *not* know (workflow rules, output formats, a path→domain map, project `CLAUDE.md`/instructions). | Preloaded **in full** at session start. |
| **1 — Mechanical role injection** | The domain role + conventions for what's being touched, injected *out of the agent's loop* so it lands whether or not the agent thinks to ask. | Before each edit (from the file path) and/or on each prompt (from the query). |
| **2 — RAG on demand** | Any precise fact (a convention, an ADR, an anti-pattern), fetched from the index. | When the agent queries `query_documents`. |

mnemodoc-server **powers layers 1 and 2** (the `get_project_context` role engine and
the `query_documents` search). **Layer 0 is a client feature** you configure (a
session-start hook or an always-on instructions file) — mnemodoc doesn't own it,
but the guides show how to set it up per client.

There's also a **closing loop**: an evaluation command (`rag-criticize`) that probes
all three layers and returns a binary verdict — see [`clients/claude-code.md`](clients/claude-code.md).

## Client capability matrix

Verified against each client's official docs (June 2026). These tools ship features
monthly — **re-check the linked docs before relying on a Preview feature.**

| Client | Layer 2 — RAG (MCP) | Layer 1 — *dynamic* per-file injection | Layer 0 — baseline | MCP config key |
| --- | --- | --- | --- | --- |
| **Claude Code** | ✅ stdio/HTTP | ✅ **full** — `PreToolUse` + `UserPromptSubmit` hooks return `additionalContext` | ✅ `SessionStart` hook + `CLAUDE.md` | `.mcp.json` → `mcpServers` |
| **GitHub Copilot** (VS Code agent) | ✅ stdio/HTTP/SSE | ⚠️ **yes, but Preview** — `PreToolUse`/`UserPromptSubmit`/`SessionStart` hooks; even accepts the `.claude/settings.json` format | ✅ `.github/copilot-instructions.md` | `.vscode/mcp.json` → **`servers`** |
| **Cursor** | ✅ stdio/SSE/HTTP | ❌ **no** — hooks are allow/deny only, they can't inject context. Fallback: **auto-attached `.mdc` rules** scoped by `globs` (static) | ✅ `alwaysApply` rule / `AGENTS.md` | `.cursor/mcp.json` → `mcpServers` |
| **Windsurf** (Cascade) | ✅ stdio/HTTP/SSE | ❌ **no** — `pre_write_code` gets the path but its stdout is **not** re-injected (blocking only). Fallback: **`glob` rules** (static) | ⚠️ no `SessionStart`; `always_on` rules | `~/.codeium/mcp_config.json` → `mcpServers` |
| **Zed** | ✅ stdio/HTTP | ❌ **no** native agent hooks (only proposed — zed-industries/zed#57943) | ✅ `AGENTS.md`/`.rules` (not glob-scoped) | `settings.json` → **`context_servers`** |

### How to read this matrix

- **Layer 2 is universal.** mnemodoc's core — on-demand, traceable retrieval — works
  in all five clients with no adaptation. This is the part everyone gets.
- **Layer 1 dynamic injection is the differentiator, and it's not universal.** It's
  fully available on **Claude Code**, and in **Preview** on **Copilot**. On
  **Cursor / Windsurf / Zed** it *degrades* to **static, glob-scoped rules**: you keep
  "the right context for this file," but the content is frozen in files rather than
  computed on the fly by a hook that queries the index. Still useful — just not dynamic.
- **Config keys differ.** Copying a config between clients without changing the root
  key (`servers` vs `mcpServers` vs `context_servers`) is the #1 mistake.

## Guides

**Clients** — `clients/claude-code.md` (reference) · `github-copilot.md` · `cursor.md` · `windsurf.md` · `zed.md`

**Frameworks** — `frameworks/rails.md` · `laravel.md` · `symfony.md` · `django.md`

> The framework guides write roles in plain, vanilla terms (a Rails guide assumes
> stock `app/models`, `app/controllers`, …). Adapt the `when_files` globs to your
> actual layout — they're the only framework-specific part.
