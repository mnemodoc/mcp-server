# Daemon

## Why a daemon exists

Without one, every client that starts the server opens the same index and
triggers its own background re-index, so several processes compete over one
database. With it, a single process owns the index and every client is a thin
proxy to it.

## Idle shutdown

After a configurable period without activity the daemon exits on its own. The
next client connection spawns it again, so the idle timeout costs a short
start-up delay rather than a manual restart.

## Recovering from a crash

Crash safety rests on the write-ahead log and on indexing each file
atomically. A proxy that loses its connection re-spawns the daemon under an
exclusive lock, and gives up after three attempts.

## Live re-indexing

While running, the daemon watches the configured paths and re-indexes a single
file when it changes. Only the daemon watches; a standalone server does not.
