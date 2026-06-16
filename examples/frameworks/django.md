# Django — `.mnemodoc.yml` role map

The framework-specific half: which folders map to which domain role. Client-independent
— pair it with a [client guide](../README.md) for the wiring. Assumes **vanilla
Django** (apps with `models.py`, `views.py`, …); adapt the globs to your layout.

> Django spreads each domain across per-app files rather than top-level folders, so the
> `when_files` globs match **by file name across apps** (`**/models.py`) rather than by
> directory. If you split modules (`models/`, `views/`), broaden to `**/models/**`.

## The config

```yaml
paths:
  - docs/

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
      description: ORM models, migrations, managers, querysets
      when_files: ["**/models.py", "**/models/**", "**/migrations/**"]
      when_query: ["model", "orm", "migration", "queryset", "manager"]

    - file: docs/roles/views.md
      description: Views, DRF serializers and viewsets, URLs
      when_files: ["**/views.py", "**/views/**", "**/serializers.py", "**/urls.py"]
      when_query: ["view", "drf", "serializer", "viewset", "url", "endpoint"]

    - file: docs/roles/forms.md
      description: Forms, admin, templates
      when_files: ["**/forms.py", "**/admin.py", "**/templates/**"]
      when_query: ["form", "admin", "template", "widget"]

    - file: docs/roles/tasks.md
      description: Async — Celery tasks, signals
      when_files: ["**/tasks.py", "**/signals.py"]
      when_query: ["celery", "task", "async", "signal", "worker"]

    - file: docs/roles/tests.md
      description: Tests — pytest/Django tests, factories
      when_files: ["**/tests.py", "**/tests/**", "**/factories.py"]
      when_query: ["test", "pytest", "factory", "fixture", "testcase"]
```

The selector scores rule hits (files x3, task x2, query x1), breaks ties by embedding
similarity against each `description`, and falls back to `default`. Write sharp
descriptions.

## A role file

Each `file:` is a short behavioral brief. Example `docs/roles/views.md`:

```markdown
# Role: Views & API

You write Django views and DRF endpoints.

## Project context
- Function/class-based views in `views.py`; DRF serializers/viewsets per app
- URLs wired in each app's `urls.py`, included from the project `urls.py`

## Posture
- Keep business logic out of views — push to models/services
- DRF: validate in the serializer, authorize in `permission_classes`
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
