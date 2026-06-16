# Symfony — `.mnemodoc.yml` role map

The framework-specific half: which folders map to which domain role. Client-independent
— pair it with a [client guide](../README.md) for the wiring. Assumes **vanilla
Symfony**; adapt the `when_files` globs to your layout.

## The config

```yaml
paths:
  - docs/
  - src/

exclude:
  - "**/vendor/**"
  - "**/var/**"

ollama:
  host: http://localhost:11434
  model: nomic-embed-text

search:
  top_k: 7
  mode: hybrid

context:
  default: docs/roles/generalist.md
  roles:
    - file: docs/roles/entities.md
      description: Doctrine entities, repositories, migrations
      when_files: ["src/Entity/**", "src/Repository/**", "migrations/**"]
      when_query: ["entity", "doctrine", "repository", "migration", "orm"]

    - file: docs/roles/controllers.md
      description: Controllers, routing, request handling
      when_files: ["src/Controller/**", "config/routes/**"]
      when_query: ["controller", "route", "request", "response", "action"]

    - file: docs/roles/services.md
      description: Services, dependency injection, event subscribers
      when_files: ["src/Service/**", "src/EventSubscriber/**", "config/services.yaml"]
      when_query: ["service", "dependency injection", "autowire", "subscriber"]

    - file: docs/roles/messenger.md
      description: Async — Messenger messages and handlers
      when_files: ["src/Message/**", "src/MessageHandler/**"]
      when_query: ["messenger", "async", "message", "handler", "queue"]

    - file: docs/roles/templates.md
      description: Twig templates, form types, UX components
      when_files: ["templates/**", "src/Form/**", "src/Twig/**"]
      when_query: ["twig", "template", "form", "render", "component"]

    - file: docs/roles/tests.md
      description: PHPUnit unit/functional tests, fixtures
      when_files: ["tests/**"]
      when_query: ["test", "phpunit", "fixture", "functional test", "kernel test"]
```

The selector scores rule hits (files x3, task x2, query x1), breaks ties by embedding
similarity against each `description`, and falls back to `default`. Write sharp
descriptions.

## A role file

Each `file:` is a short behavioral brief. Example `docs/roles/messenger.md`:

```markdown
# Role: Async — Messenger

You write Symfony Messenger messages and handlers.

## Project context
- Messages in `src/Message/`, handlers in `src/MessageHandler/`
- Transports configured in `config/packages/messenger.yaml`

## Posture
- A message is a plain DTO; the handler is `#[AsMessageHandler]`, side-effect only
- Keep handlers idempotent — transports retry
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
