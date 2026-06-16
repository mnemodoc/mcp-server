# Laravel — `.mnemodoc.yml` role map

The framework-specific half: which folders map to which domain role. Client-independent
— pair it with a [client guide](../README.md) for the wiring. Assumes **vanilla
Laravel**; adapt the `when_files` globs to your layout.

## The config

```yaml
paths:
  - docs/
  - app/

exclude:
  - "**/vendor/**"
  - "**/storage/**"

ollama:
  host: http://localhost:11434
  model: nomic-embed-text

search:
  top_k: 7
  mode: hybrid

context:
  default: docs/roles/generalist.md
  roles:
    - file: docs/roles/models.md
      description: Eloquent models, migrations, relationships, casts
      when_files: ["app/Models/**", "database/migrations/**"]
      when_query: ["model", "eloquent", "migration", "relationship", "scope"]

    - file: docs/roles/controllers.md
      description: HTTP controllers, routing, form requests, middleware
      when_files: ["app/Http/**", "routes/**"]
      when_query: ["controller", "route", "request", "middleware", "validation"]

    - file: docs/roles/jobs.md
      description: Queued jobs, mail, notifications, events/listeners
      when_files: ["app/Jobs/**", "app/Mail/**", "app/Notifications/**", "app/Listeners/**"]
      when_query: ["job", "queue", "mail", "notification", "event"]

    - file: docs/roles/policies.md
      description: Authorization — policies and gates
      when_files: ["app/Policies/**"]
      when_query: ["policy", "gate", "authorization", "can", "ability"]

    - file: docs/roles/views.md
      description: Blade views, components, Livewire
      when_files: ["resources/views/**", "app/View/**", "app/Livewire/**"]
      when_query: ["blade", "view", "component", "livewire"]

    - file: docs/roles/tests.md
      description: Pest/PHPUnit feature and unit tests, factories
      when_files: ["tests/**", "database/factories/**"]
      when_query: ["test", "pest", "phpunit", "factory", "feature test"]
```

The selector scores rule hits (files x3, task x2, query x1), breaks ties by embedding
similarity against each `description`, and falls back to `default`. Write sharp
descriptions.

## A role file

Each `file:` is a short behavioral brief. Example `docs/roles/policies.md`:

```markdown
# Role: Authorization — policies & gates

You write Laravel authorization rules.

## Project context
- Policies in `app/Policies/`, registered in `AuthServiceProvider`
- Abilities checked via `$user->can(...)` / `authorize(...)` in controllers

## Posture
- One method per ability (`view`, `update`, ...); return bool/Response
- Use policy `before()` for super-admin short-circuits, deliberately
- For detail, query the mnemodoc RAG (`query_documents`)
```

Keep roles short — they orient; the RAG (layer 2) holds the detail. Don't paste whole
conventions in; point at them.

## Wiring

This config powers **layers 1 and 2**. To make layer 1 fire, follow your client guide:
[Claude Code](../clients/claude-code.md) (dynamic hooks) ·
[Copilot](../clients/github-copilot.md) (hooks, Preview) ·
[Cursor](../clients/cursor.md) / [Windsurf](../clients/windsurf.md) (static glob rules) ·
[Zed](../clients/zed.md) (RAG only). The role map is identical across all of them.
