#!/bin/sh
set -eu

# Released migration history is append-only.
#
#   scripts/migrations-lock.sh check              verify the released steps
#   scripts/migrations-lock.sh release VERSION    lock every unreleased step
#
# A database that was migrated past step 2 has run step 2's SQL. If step 2 is
# later edited, the history still replays to the declaration — the schema gate
# stays green — and every database already past it now disagrees with the
# history while nothing says so. Atlas answers this with a checksum file over
# its migration directory; Prisma records a checksum per applied migration.
#
# Here the lock is one line per released step:
#
#   step  digest  version
#
# The digest is over the step's executable SQL in contracts/migrations.sql,
# with comment lines and blank lines removed: the schema gate already proves
# that file is the projection of the history, and SQL is what a database ran.
# Rewording a projection comment is not a change to a released migration;
# changing a statement is.
#
# `release` appends the steps that are not yet locked, under the version being
# tagged. `check` refuses a locked step whose SQL changed or disappeared, by
# step and version, and lists the steps that are not yet released. The lock is
# never edited by hand.
#
# MIGRATIONS_SQL and MIGRATIONS_LOCK override the two paths, for the gate's
# break tests.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SQL=${MIGRATIONS_SQL:-"$ROOT/contracts/migrations.sql"}
LOCK=${MIGRATIONS_LOCK:-"$ROOT/contracts/migrations.lock"}

fail() {
    printf 'migrations-lock: FAIL: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'usage: scripts/migrations-lock.sh check | release VERSION\n' >&2
    exit 2
}

test -f "$SQL" || fail "no migration SQL at $SQL"
test -f "$LOCK" || fail "no lock file at $LOCK"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-migrations-lock.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -c1-16
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -c1-16
    else
        fail 'no sha256sum or shasum available'
    fi
}

# One file per step, holding that step's executable SQL. A step starts at its
# `-- step N:` header and runs to the next header.
awk -v dir="$WORK" '
    /^-- step [0-9]+:/ {
        step = $3
        sub(/:$/, "", step)
        file = dir "/step." step
        printf "" > file
        print step > (dir "/steps")
        next
    }
    step == "" { next }
    /^--/ { next }
    {
        # A trailing comment is annotation, not SQL. The projection writes no
        # string literals, so " --" cannot be inside one.
        sub(/[[:space:]]+--.*$/, "")
    }
    /^[[:space:]]*$/ { next }
    { print >> file }
' "$SQL"
test -s "$WORK/steps" || fail "found no '-- step N:' blocks in $SQL"

# The steps must be 1..n in order; a gap would make "released up to k"
# meaningless.
expected=1
while IFS= read -r step; do
    test "$step" = "$expected" ||
        fail "the migration SQL numbers its steps out of order: expected step $expected, found step $step"
    expected=$((expected + 1))
done <"$WORK/steps"
count=$((expected - 1))

step_digest() {
    digest <"$WORK/step.$1"
}

# Lock lines, without comments or blank lines.
sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$LOCK" >"$WORK/lock"

released=0
expected=1
while read -r step locked version extra; do
    test -z "${extra:-}" || fail "lock line for step $step has more than three fields"
    case $version in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) fail "lock line for step $step names no version" ;;
    esac
    test "$step" = "$expected" ||
        fail "the lock is not a prefix of the history: expected step $expected, found step $step"
    test -f "$WORK/step.$step" ||
        fail "history step $step was released at v$version and is missing from the history"
    actual=$(step_digest "$step")
    test "$actual" = "$locked" ||
        fail "history step $step was released at v$version and has changed (locked $locked, now $actual)"
    released=$step
    expected=$((expected + 1))
done <"$WORK/lock"

case "${1:-}" in
    check)
        if test "$released" -eq "$count"; then
            printf 'migrations-lock: %s released steps unchanged; none unreleased\n' "$released"
        else
            printf 'migrations-lock: %s released steps unchanged; unreleased:' "$released"
            step=$((released + 1))
            while test "$step" -le "$count"; do
                printf ' %s' "$step"
                step=$((step + 1))
            done
            printf '\n'
        fi
        ;;
    release)
        version=${2:-}
        printf '%s' "$version" | grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ||
            fail "release needs a plain semver version, got '$version'"
        test "$released" -lt "$count" ||
            { printf 'migrations-lock: nothing to release; all %s steps are locked\n' "$count"; exit 0; }
        step=$((released + 1))
        while test "$step" -le "$count"; do
            printf '%s %s %s\n' "$step" "$(step_digest "$step")" "$version" >>"$LOCK"
            step=$((step + 1))
        done
        printf 'migrations-lock: locked steps %s..%s at v%s\n' "$((released + 1))" "$count" "$version"
        ;;
    *)
        usage
        ;;
esac
