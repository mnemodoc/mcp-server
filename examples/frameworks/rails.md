# Rails — `.mnemodoc.yml` role map

This guide covers the **framework-specific** half: which folders map to which domain
role. It's client-independent — the same `.mnemodoc.yml` works whether you wire it
into Claude Code, Copilot, or Cursor (see the [client guides](../README.md)).

It assumes **vanilla Rails** (stock `app/models`, `app/controllers`, `app/jobs`,
`app/policies`, `app/views`, `spec/`). Adapt the `when_files` globs to your actual
layout — they're the only part you must change.

## The config

mnemodoc indexes your docs and resolves a role from the file/query at hand. A minimal
`.mnemodoc.yml` at the project root:

```yaml
# What to index (paths resolve relative to this file)
paths:
  - doc/
  - app/

exclude:
  - "**/node_modules/**"
  - "**/tmp/**"

ollama:
  host: http://localhost:11434
  model: nomic-embed-text

search:
  top_k: 7
  mode: hybrid

# Layer 1 — the role engine. Each role points at a Markdown file plus triggers on
# three axes: files edited (x3), task kind (x2), user query (x1).
context:
  default: doc/roles/generalist.md
  roles:
    - file: doc/roles/models.md
      description: ActiveRecord models, migrations, validations, associations
      when_files: ["app/models/**", "db/migrate/**"]
      when_query: ["model", "migration", "association", "validation", "scope"]

    - file: doc/roles/controllers.md
      description: Controllers, routing, strong params, before_actions
      when_files: ["app/controllers/**", "config/routes.rb"]
      when_query: ["controller", "route", "action", "params", "before_action"]

    - file: doc/roles/jobs.md
      description: Background jobs, Active Job, mailers, async work
      when_files: ["app/jobs/**", "app/mailers/**"]
      when_query: ["job", "sidekiq", "async", "mailer", "perform"]

    - file: doc/roles/policies.md
      description: Authorization — Pundit policies and scopes
      when_files: ["app/policies/**"]
      when_query: ["policy", "authorization", "pundit", "scope", "permission"]

    - file: doc/roles/views.md
      description: Views, helpers, partials, Hotwire (Turbo/Stimulus)
      when_files: ["app/views/**", "app/helpers/**", "app/javascript/**"]
      when_query: ["view", "partial", "helper", "turbo", "stimulus"]

    - file: doc/roles/tests.md
      description: RSpec specs, factories, request/system tests
      when_files: ["spec/**", "test/**"]
      when_query: ["spec", "test", "rspec", "factory", "request spec"]
```

The role selector scores rule hits (files x3, task x2, query x1). A clear winner wins
outright; ambiguous cases are broken by embedding similarity against each role's
`description`; with no signal it falls back to `default`. So **write a sharp
`description`** — it's the tie-breaker.

## A role file

Each `file:` is a short Markdown brief — the posture to adopt, the project's
conventions, and a pointer to query the RAG for specifics. Example
`doc/roles/policies.md`:

```markdown
# Role: Authorization & policies

You write Pundit authorization rules, applied in controllers/operations.

## Project context

- Policies live in `app/policies/`, inherit from `ApplicationPolicy`
- Roles: guest, member, admin

## Posture

- One predicate method per action (`show?`, `update?`, ...); check inheritance
  before redefining
- Restrict listings with a `Scope` class (`resolve`) — never return `all` for
  non-admins
- Precise patterns / Scope examples: read `doc/conventions/policies.md` or query
  the RAG (`query_documents`)
```

Keep roles **short and behavioral**. They orient; the RAG (layer 2) holds the detail.
Don't paste whole conventions into a role — point at them.

> **Chunk hygiene:** mnemodoc treats everything before the first `##` as one chunk.
> If every doc opens with a breadcrumb + "when to use" preamble, those become
> low-value chunks that match domain keywords without carrying an answer. Keep
> preambles minimal, or let the routing metadata live here in `.mnemodoc.yml`
> (`when_query`/`when_files`/`description`) instead of repeating it in each doc.

## Wiring it into a client

This config is half the setup — it powers **layers 1 and 2**. To make layer 1 fire
mechanically (a hook that injects the role before each edit), follow your client
guide:

- [Claude Code](../clients/claude-code.md) — full dynamic injection via hooks
- [GitHub Copilot](../clients/github-copilot.md) — hooks (Preview)
- [Cursor](../clients/cursor.md) / [Windsurf](../clients/windsurf.md) / [Zed](../clients/zed.md) — RAG on demand + static glob-scoped rules

The role map above is identical across all of them; only the wiring changes.
