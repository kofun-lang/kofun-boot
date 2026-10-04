#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# The stamp is defined here and nowhere else. The gate asks this script for
# the name (`--name`) instead of repeating it, so the two cannot drift, and the
# fixed timestamp inside the ZIP is derived from the same date.
STAMP=2026-10-04
PACK_NAME=kofun-boot-framework-research-$STAMP
FIXED_MTIME=$(printf '%s' "$STAMP" | tr -d '-')0000.00

# What the pack carries. Every Markdown file under docs/research/, docs/adr/
# and docs/architecture/ must be listed here or in EXCLUDED with its reason;
# tests/research/check.sh fails, by file name, on one that is neither. A
# dossier that silently stays out of the pack is how a snapshot starts to
# claim a date its contents no longer have.
FILES='
docs/DESIGN.md
docs/ROADMAP.md
docs/BACKLOG.md
docs/research/README.md
docs/research/PACKAGE.md
docs/research/WEB_FRAMEWORKS.md
docs/research/SPRING_FASTAPI_GIN.md
docs/research/MODULAR_MONOLITH_DDD.md
docs/research/DESKTOP_FRAMEWORKS.md
docs/research/RENDER_BACKENDS.md
docs/research/EFFECT_SYSTEMS.md
docs/research/NEXT_PRISMA_DRIZZLE.md
docs/research/N_PLUS_ONE.md
docs/architecture/BLUEPRINT.md
docs/architecture/DATA.md
docs/architecture/EFFECTS.md
docs/architecture/FDDD.md
docs/architecture/TEA.md
docs/adr/0001-record-architecture-decisions.md
docs/adr/0002-enforce-boundaries-by-gate-not-by-named-test.md
docs/adr/0003-mutations-return-a-new-state.md
docs/adr/0004-projections-read-the-table-the-dispatcher-printed.md
docs/adr/0005-a-trace-is-the-fold-the-core-already-performs.md
docs/adr/0006-a-module-owns-its-whole-vertical.md
docs/adr/0007-a-full-resource-is-a-conflict-not-a-storage-failure.md
docs/adr/0008-a-column-is-its-key.md
docs/adr/0009-a-migration-history-is-a-fold.md
docs/adr/0010-a-round-is-a-value.md
docs/adr/0011-a-cache-key-is-the-arguments.md
'

# Files under those directories that are deliberately not packed, one per
# line as "path — reason". Empty today; the format exists so that leaving a
# file out is a written decision rather than an omission.
EXCLUDED='
'

case "${1:-}" in
    --name)
        printf '%s\n' "$PACK_NAME"
        exit 0
        ;;
    --list)
        printf '%s\n' "$FILES" | sed '/^$/d'
        exit 0
        ;;
    --excluded)
        printf '%s\n' "$EXCLUDED" | sed '/^$/d' | sed 's/ — .*$//'
        exit 0
        ;;
esac

OUT=${1:-"$ROOT/dist"}

for tool in zip sha256sum mktemp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'research-pack: FAIL: required tool not found: %s\n' "$tool" >&2
        exit 1
    fi
done

mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-research.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM
STAGE="$TMP_ROOT/$PACK_NAME"
mkdir -p "$STAGE/docs/research" "$STAGE/docs/architecture" "$STAGE/docs/adr"

cp "$ROOT/docs/research/PACKAGE.md" "$STAGE/README.md"
cp "$ROOT/LICENSE-APACHE" "$STAGE/LICENSE-APACHE"
cp "$ROOT/LICENSE-MIT" "$STAGE/LICENSE-MIT"

printf '%s\n' "$FILES" | while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ ! -f "$ROOT/$file" ]; then
        printf 'research-pack: FAIL: missing input: %s\n' "$file" >&2
        exit 1
    fi
    cp "$ROOT/$file" "$STAGE/$file"
done

(
    cd "$STAGE"
    find . -type f ! -name MANIFEST.sha256 -print |
        LC_ALL=C sort |
        while IFS= read -r file; do
            sha256sum "$file"
        done
) >"$STAGE/MANIFEST.sha256"

# ZIP stores file timestamps and optional platform metadata by default. Fix the
# former and strip the latter so two builds of one source tree are identical.
# Normalize permissions as well; the caller's umask is not package content.
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +
find "$STAGE" -exec touch -t "$FIXED_MTIME" {} +
ZIP_TMP="$TMP_ROOT/$PACK_NAME.zip"
(
    cd "$TMP_ROOT"
    find "$PACK_NAME" -type f -print |
        LC_ALL=C sort |
        zip -X -q "$ZIP_TMP" -@
)

ZIP_HASH=$(sha256sum "$ZIP_TMP" | cut -d ' ' -f 1)
HASH_TMP="$TMP_ROOT/$PACK_NAME.zip.sha256"
printf '%s  %s.zip\n' "$ZIP_HASH" "$PACK_NAME" >"$HASH_TMP"

mv "$ZIP_TMP" "$OUT/$PACK_NAME.zip"
mv "$HASH_TMP" "$OUT/$PACK_NAME.zip.sha256"
printf '%s\n' "$OUT/$PACK_NAME.zip" "$OUT/$PACK_NAME.zip.sha256"
