# Claude Code — full three-layer wiring

Claude Code is the reference client: it supports **all three layers** natively, with
no SDK or custom integration. This guide wires each one. Pair it with a framework
guide (e.g. [`../frameworks/rails.md`](../frameworks/rails.md)) for the `.mnemodoc.yml`
role map.

Verified against the official docs (June 2026):
[hooks](https://code.claude.com/docs/en/hooks) ·
[MCP](https://code.claude.com/docs/en/mcp) ·
[memory](https://code.claude.com/docs/en/memory).

## Layer 2 — RAG on demand (MCP)

Declare the server in `.mcp.json` at the project root (committable, shared with the
team). Transport is **stdio** for a local index:

```json
{
  "mcpServers": {
    "mnemodoc": {
      "command": "mnemodoc-server",
      "args": ["serve", "--config", "${CLAUDE_PROJECT_DIR}/.mnemodoc.yml"]
    }
  }
}
```

The tools land as `mcp__mnemodoc__query_documents`, `mcp__mnemodoc__get_project_context`,
`mcp__mnemodoc__status`, etc.

The config path is **absolute** on purpose. The server resolves a relative one against
its own working directory, which is whatever the client happened to start it in — not
necessarily the project root. `${CLAUDE_PROJECT_DIR}` is expanded by Claude Code when it
reads `.mcp.json`; the server itself knows nothing of that variable, so any absolute path
does just as well.

> SSE transport is deprecated in Claude Code — use stdio (local) or HTTP (remote).

## Layer 1 — mechanical role injection (hooks)

This is the part most RAG setups skip. A hook runs as a subprocess **outside the
agent's loop**, before each edit and/or on each prompt, and returns the domain role
via `additionalContext` — so guidance lands whether or not the agent thinks to ask.

### The hook script

A small wrapper reads the event payload on stdin, resolves the role via the
`mnemodoc-server context` CLI (same engine as the `get_project_context` tool), and
prints it. It handles **two channels**:

- `PreToolUse` (Edit/Write) → resolve from the **edited file path** (`--files`).
- `UserPromptSubmit` → resolve from the **prompt text** (`--query`), to cover
  reasoning/reading turns with no edit.

It **must degrade silently** (`exit 0`) if the server or Ollama is down, so a missing
index never blocks an edit — which the command already does on every failure path.

`--hook-stdin` reads the client's payload directly, so there is nothing to re-implement:
it derives the files or the query from the event itself, and records the session and
agent in the audit log, which a wrapper passing `--files`/`--query` cannot do.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "mnemodoc-server context --hook-stdin --config \"${CLAUDE_PROJECT_DIR}/.mnemodoc.yml\" || true"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "mnemodoc-server context --hook-stdin --config \"${CLAUDE_PROJECT_DIR}/.mnemodoc.yml\" || true"
          }
        ]
      }
    ]
  }
}
```

On the `UserPromptSubmit` channel the command stays silent by itself when the selection
falls back to the default role, so an undecided prompt does not pollute every turn with
the generalist context. That decision is the selector's, reported in the `default` field
of `context --json` — not something to guess from the markdown's first line.

### Wiring it in `.claude/settings.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "bin/mnemodoc-hook" }]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [{ "type": "command", "command": "bin/mnemodoc-hook" }]
      }
    ]
  }
}
```

`PreToolUse` filters on tool name via `matcher` (`Edit|Write`); `UserPromptSubmit`
takes no matcher. Both pass their payload on stdin and inject the hook's stdout as
context. The role files themselves live in your repo and are pointed at by
`.mnemodoc.yml` (see any framework guide).

## Layer 0 — baseline (session start)

Preload the few rules the agent must never miss. Two native options, combinable:

- **`CLAUDE.md`** at the project root is loaded *in full* at launch — good for short,
  stable rules.
- A **`SessionStart` hook** that prints the baseline files, for larger or composed
  baselines (and it re-fires after `/compact`):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [{ "type": "command", "command": "cat doc/workflow-rules.md doc/workflow-formats.md" }]
      }
    ]
  }
}
```

Keep layer 0 small: it's the *unknown unknowns* (behavioral rules, output formats) the
agent couldn't know to search for. Everything else belongs in layers 1–2.

## The closing loop — an evaluation command

Add a slash command that probes all three layers and returns a **binary verdict**, so
you can tell when the index has drifted (a RAG that's *confident but wrong* is worse
than no RAG). Save as `.claude/commands/rag-criticize.md` and run `/rag-criticize`:

```markdown
# Evaluate the mnemodoc context system — baseline, hooks, RAG

Validate the integration without complacency. Golden rule: PROOF, NOT CLAIMS —
never assert something is "in context" or "correct" without quoting it verbatim or
checking it against the code. Read-only; change nothing.

0. Reproducibility: record `status` (chunk_count, file_count, model) and the search
   config (top_k, mode). Use that top_k explicitly for every query below.
A. Baseline: prove each critical rule is loaded by quoting its source line verbatim
   (not from memory). Cite one rule deep in the file to test for truncation.
B. Hooks: for 4 representative paths, run the PreToolUse hook and check the role is
   correct AND adds a convention you wouldn't have had. Then check UserPromptSubmit
   stays SILENT on a non-technical prompt (its #1 risk).
C. RAG: 4 well-documented questions + 2 adversarial (one with a false premise). Per
   question score Relevance /5, Sufficiency /5, Veracity-vs-code (check the actual
   source), and signal/noise (content chunks / top_k).
D. Synthesis: real weaknesses with proof; list any doc inconsistencies found.
E. Binary verdict. BLOCKING (any fail => FAIL): veracity >= 5/6 vs code; no
   hallucination on the adversarial pair; UserPromptSubmit silent on noise; 4/4 hook
   routing. QUALITY (fail => HOLDS BUT NEEDS WORK): relevance >= 4/5; signal/noise
   >= 3 per query; baseline proven; negative-path hook falls back cleanly.
```

This command is **client-specific** (it drives the Claude Code hook); the same idea
ports to any client whose layer 1 you wired.

## Recap

| Layer | Mechanism | Files |
| --- | --- | --- |
| 0 — baseline | `SessionStart` hook and/or `CLAUDE.md` | `.claude/settings.json`, `CLAUDE.md` |
| 1 — role injection | `PreToolUse` + `UserPromptSubmit` hooks → `mnemodoc-server context` | `bin/mnemodoc-hook`, `.claude/settings.json`, `.mnemodoc.yml` roles |
| 2 — RAG | MCP server (stdio) | `.mcp.json`, `.mnemodoc.yml` |
| eval | `/rag-criticize` | `.claude/commands/rag-criticize.md` |
