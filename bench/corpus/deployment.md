# Deployment guide

## Building a release

Release builds are produced inside Docker so the resulting binary is fully
static and carries no dynamic dependency on the host. The build compiles the
vendored SQLite extension and links it into the binary, so no extension is
loaded at runtime.

## Rolling back a release

To roll back, redeploy the previously tagged image. Rollbacks never touch the
index: the on-disk database format is forward and backward compatible within a
minor version, so an older binary reads a newer index without migration.

## Health checks

The HTTP transport exposes a liveness endpoint that returns 200 once the
process is ready to serve. Readiness is not distinguished from liveness: the
server binds its socket only after the store has been opened.

## Log rotation

Sending SIGUSR1 reopens the log file in place. Rotate by moving the file aside
and then signalling the process; no restart is required and no lines are lost.
