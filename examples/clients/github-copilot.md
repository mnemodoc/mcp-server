# GitHub Copilot (VS Code agent) — three-layer wiring

Copilot's **agent mode in VS Code** is the closest match to Claude Code: it ships a
hook system that mirrors Claude's (same event names, even accepts the
`.claude/settings.json` format), so **all three layers** are reachable — with one
caveat: **hooks are in Preview**.

Verified against the official docs (June 2026):
[MCP servers](https://code.visualstudio.com/docs/agent-customization/mcp-servers) ·
[Agent hooks (Preview)](https://code.visualstudio.com/docs/agent-customization/hooks) ·
[Custom instructions](https://code.visualstudio.com/docs/agent-customization/custom-instructions).

> ⚠️ **Preview.** The hook format and behavior may change, and the VS Code docs and
> GitHub docs diverge on whether `additionalContext` is carried by `PreToolUse`.
> Treat layer 1 here as "works, but validate on your installed version."

## Layer 2 — RAG on demand (MCP)

Declare the server in `.vscode/mcp.json`. **The root key is `servers`** — not
`mcpServers` (that's the #1 copy-paste bug coming from Cursor/Claude):

```json
{
  "servers": {
    "mnemodoc": {
      "type": "stdio",
      "command": "mnemodoc-server",
      "args": ["serve", "--config", ".mnemodoc.yml"]
    }
  }
}
```

Transports: stdio (local), HTTP, SSE. For a local index, stdio is the direct fit.

## Layer 1 — mechanical role injection (hooks, Preview)

VS Code loads every `.json` in `.github/hooks/` (workspace) or `~/.copilot/hooks`
(user). It also accepts the **Claude format** (`.claude/settings.json`), so the
[Claude Code hook script](claude-code.md#the-hook-script) (`bin/mnemodoc-hook`)
works unchanged — only the payload field names match (`tool_name`, `tool_input`).

```json
{
  "hooks": {
    "PreToolUse": [
      { "type": "command", "command": "bin/mnemodoc-hook", "timeout": 15 }
    ],
    "UserPromptSubmit": [
      { "type": "command", "command": "bin/mnemodoc-hook" }
    ]
  }
}
```

`PreToolUse` fires before any tool, with `tool_input` carrying the file path; the hook
returns the role via `additionalContext`. **Validate empirically** that
`additionalContext` is injected on your build (docs diverge — see the caveat above).

**Declarative alternative (stable, not Preview):** `*.instructions.md` files in
`.github/instructions/` with front-matter `applyTo: <glob>` are injected when the
agent works on matching files. This is the static counterpart — write one per domain
(`applyTo: app/policies/**`) if you'd rather not depend on a Preview hook.

## Layer 0 — baseline

`.github/copilot-instructions.md` at the workspace root is applied to **all** chat
requests, workspace-wide. Put the baseline rules there. (For larger baselines, a
`SessionStart` hook works too, same Preview caveat.)

## Recap

| Layer | Mechanism | Files |
| --- | --- | --- |
| 0 — baseline | `copilot-instructions.md` | `.github/copilot-instructions.md` |
| 1 — role injection | `PreToolUse`/`UserPromptSubmit` hooks (Preview) **or** `applyTo` instructions | `.github/hooks/*.json` (or `.claude/settings.json`), `bin/mnemodoc-hook`, `.github/instructions/*.instructions.md` |
| 2 — RAG | MCP server (stdio), key `servers` | `.vscode/mcp.json`, `.mnemodoc.yml` |

Pair with a [framework guide](../README.md) for the `.mnemodoc.yml` role map.
