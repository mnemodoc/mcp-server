#!/usr/bin/env bash
# Assembles the licenses/ folder baked into the binary from licenses.manifest:
# shard texts are copied from disk; clib/runtime texts are grouped by SPDX id
# from the committed canonical texts in licenses-spdx/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MANIFEST=licenses.manifest
OUT=licenses
rm -rf "$OUT"
mkdir -p "$OUT"

# clib/runtime licenses are grouped by SPDX id. macOS ships bash 3.2 (no
# associative arrays), so accumulate the "used by" names in per-id list files
# under a hidden scratch dir instead of `declare -A`. The dir is removed before
# the final count so it never lands in the baked output.
SCRATCH="$OUT/.used"
mkdir -p "$SCRATCH"

while IFS='|' read -r kind name source; do
  kind="$(echo "$kind" | tr -d '[:space:]')"
  name="$(echo "$name" | tr -d '[:space:]')"
  source="$(echo "$source" | tr -d '[:space:]')"
  [ -z "$kind" ] && continue
  case "$kind" in
    \#*) continue ;;
    shard|project)
      # On-disk license text copied verbatim (carries a real copyright line):
      # shards from lib/<name>/LICENSE, the project from the root LICENSE.
      if [ ! -f "$source" ]; then
        echo "harvest: missing license '$source' for '$name' (run shards install / the submodule plan)" >&2
        exit 1
      fi
      cp "$source" "$OUT/$name.txt"
      ;;
    clib|runtime)
      if [ ! -f "licenses-spdx/$source.txt" ]; then
        echo "harvest: missing licenses-spdx/$source.txt for '$name'" >&2
        exit 1
      fi
      echo "$name" >> "$SCRATCH/$source.list"
      ;;
  esac
done < <(grep -v '^#' "$MANIFEST")

# Sorted glob → deterministic baked output. Join the accumulated names with ", ".
for list in "$SCRATCH"/*.list; do
  [ -e "$list" ] || continue
  id="$(basename "$list" .list)"
  names="$(awk 'NR>1{printf ", "} {printf "%s", $0} END{print ""}' "$list")"
  {
    echo "Used by: $names"
    echo
    cat "licenses-spdx/$id.txt"
  } > "$OUT/clib-$id.txt"
done

rm -rf "$SCRATCH"

echo "harvested $(ls "$OUT" | wc -l | tr -d ' ') license files into $OUT/"
