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
      "args": ["serve", "--config", ".mnemodoc.yml"]
    }
  }
}
```

The tools land as `mcp__mnemodoc__query_documents`, `mcp__mnemodoc__get_project_context`,
`mcp__mnemodoc__status`, etc. Claude Code injects `CLAUDE_PROJECT_DIR` into the server's
environment, so config paths resolve against the project, not the process cwd.

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
index never blocks an edit. Save as `bin/mnemodoc-hook` (chmod +x):

```python
#!/usr/bin/env python3
# mnemodoc hook — injects the domain role to adopt.
#   PreToolUse (Edit/Write): from the edited file  -> `context --files`
#   UserPromptSubmit:        from the prompt text   -> `context --query`
# On the query channel, only inject on a decisive domain match: if the selector
# falls back to the generalist role, stay silent (don't pollute every turn).
# Degrades silently (exit 0) when the server is unavailable.
import json, sys, subprocess, os

CONFIG = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".mnemodoc.yml")

def run(*args):
    try:
        r = subprocess.run(["mnemodoc-server", "context", *args, "--config", CONFIG],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

event = payload.get("hook_event_name", "")
role = ""
if event == "PreToolUse":
    path = payload.get("tool_input", {}).get("file_path", "")
    if path:
        role = run("--files", path)
elif event == "UserPromptSubmit":
    prompt = payload.get("prompt", "")
    if prompt:
        out = run("--query", prompt)
        # skip the generalist fallback so reasoning turns aren't spammed
        if out and "generalist" not in out.splitlines()[0].lower():
            role = out

if role:
    print(f"[mnemodoc] role:\n{role}")
sys.exit(0)
```

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
