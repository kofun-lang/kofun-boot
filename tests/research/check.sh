#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BUILDER="$ROOT/scripts/build-research-pack.sh"
# Asked of the builder, never repeated here: one stamp, one place.
PACK_NAME=$(sh "$BUILDER" --name)

for tool in unzip cmp sha256sum mktemp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'research-pack: FAIL: required tool not found: %s\n' "$tool" >&2
        exit 1
    fi
done

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-research-check.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

# ------------------------------------------------------------- coverage
#
# Every dossier, decision record, and architecture document is either in the
# pack or excluded with a written reason. The candidates come from the
# filesystem, so a new file is checked without anyone remembering to add it
# to this gate.
sh "$BUILDER" --list | LC_ALL=C sort >"$TMP_ROOT/packed"
sh "$BUILDER" --excluded | LC_ALL=C sort >"$TMP_ROOT/excluded"

uncovered() {
    LC_ALL=C sort "$1" | while IFS= read -r file; do
        grep -qxF "$file" "$TMP_ROOT/packed" && continue
        grep -qxF "$file" "$TMP_ROOT/excluded" && continue
        printf '%s\n' "$file"
    done
}

(
    cd "$ROOT"
    find docs/research docs/adr docs/architecture -type f -name '*.md'
) >"$TMP_ROOT/candidates"
test -s "$TMP_ROOT/candidates" || {
    printf 'research-pack: FAIL: found no documents to check; the coverage check would be vacuous\n' >&2
    exit 1
}
missing=$(uncovered "$TMP_ROOT/candidates")
if test -n "$missing"; then
    printf 'research-pack: FAIL: neither in the pack nor excluded: %s\n' $missing >&2
    printf '  add each to FILES or EXCLUDED in scripts/build-research-pack.sh\n' >&2
    exit 1
fi

# The check can fail: an unlisted dossier beside the real ones is named.
cp "$TMP_ROOT/candidates" "$TMP_ROOT/candidates.break"
printf '%s\n' docs/research/ZZ_UNLISTED.md >>"$TMP_ROOT/candidates.break"
test "$(uncovered "$TMP_ROOT/candidates.break")" = docs/research/ZZ_UNLISTED.md || {
    printf 'research-pack: FAIL: the coverage check did not name an unlisted dossier\n' >&2
    exit 1
}

FIRST="$TMP_ROOT/first"
SECOND="$TMP_ROOT/second"
EXTRACTED="$TMP_ROOT/extracted"
mkdir -p "$FIRST" "$SECOND" "$EXTRACTED"

sh "$ROOT/scripts/build-research-pack.sh" "$FIRST" >/dev/null
env -i PATH="$PATH" LC_ALL=C TZ=Pacific/Kiritimati \
    sh "$ROOT/scripts/build-research-pack.sh" "$SECOND" >/dev/null

cmp "$FIRST/$PACK_NAME.zip" "$SECOND/$PACK_NAME.zip" || {
    printf 'research-pack: FAIL: ZIP changed under hostile environment\n' >&2
    exit 1
}
cmp "$FIRST/$PACK_NAME.zip.sha256" "$SECOND/$PACK_NAME.zip.sha256" || {
    printf 'research-pack: FAIL: ZIP digest changed under hostile environment\n' >&2
    exit 1
}

(
    cd "$FIRST"
    sha256sum -c "$PACK_NAME.zip.sha256" >/dev/null
)
unzip -tqq "$FIRST/$PACK_NAME.zip"
unzip -qq "$FIRST/$PACK_NAME.zip" -d "$EXTRACTED"

# Everything the builder lists is in the archive, plus the two files the
# builder writes itself. Read from the list rather than spelled out here, so a
# file added to the pack is checked without a second edit.
for file in README.md MANIFEST.sha256 $(cat "$TMP_ROOT/packed"); do
    if [ ! -f "$EXTRACTED/$PACK_NAME/$file" ]; then
        printf 'research-pack: FAIL: ZIP omitted %s\n' "$file" >&2
        exit 1
    fi
done

(
    cd "$EXTRACTED/$PACK_NAME"
    sha256sum -c MANIFEST.sha256 >/dev/null
)

# Prove the manifest rejects a changed dossier. This is deliberately confined
# to the mktemp tree and verifies the failure direction of the evidence gate.
printf '\ncorrupted\n' >>"$EXTRACTED/$PACK_NAME/docs/research/SPRING_FASTAPI_GIN.md"
if (
    cd "$EXTRACTED/$PACK_NAME"
    sha256sum -c MANIFEST.sha256 >/dev/null 2>&1
); then
    printf 'research-pack: FAIL: manifest accepted a changed dossier\n' >&2
    exit 1
fi

printf 'research-pack: PASS: every dossier, ADR, and architecture document is packed or excluded by name\n'
printf 'research-pack: PASS: deterministic ZIP, hostile env, manifest, break test\n'
