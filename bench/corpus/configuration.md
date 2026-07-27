# Configuration

## Where the index is stored

By default the index lives beside the configuration file, in a directory that
also holds the write-ahead log and the daemon's socket, lock and pid files.
That directory receives a self-ignoring ignore file when it is created.

## Overriding the index location

An explicit database path is used verbatim and receives no ignore file. Set it
when the project directory is read-only, is synchronised by a cloud folder, or
is wiped by clean commands.

## Relative paths

Relative paths are resolved against the directory holding the configuration
file, not the process working directory. Moving the configuration file moves
the paths with it.

## Environment overrides

Every setting can be overridden at runtime by an environment variable without
editing the configuration file. Overrides are applied after parsing and before
validation.
