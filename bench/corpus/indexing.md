# Indexing

## Which files are indexed

Every configured path is walked recursively. A file is indexed when its
extension maps to a known format handler; unknown extensions found during a
directory walk are skipped silently rather than treated as plain text.

## Incremental re-indexing

Files whose modification time has not changed since the previous run are
skipped entirely, so re-running the indexer over an unchanged tree costs
nothing beyond the directory walk.

## Excluding paths

Glob patterns listed under the exclude key are matched against absolute paths
and skipped. Exclusion is evaluated during the walk, so an excluded directory
is never descended into.

## Handling embedding failures

When the embedding service rejects a chunk, the crawler logs it and moves on to
the next file rather than aborting the run. A partial index is preferred to no
index at all.
