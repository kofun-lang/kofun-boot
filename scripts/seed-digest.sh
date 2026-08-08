#!/bin/sh
set -eu

# The digest of the seed a session was recorded against.
#
# A trace is only a replay if it is a replay *of something*. The header has
# always named the seed — `# seed: seeded_store` — but a name is not a pin: a
# seed can be edited without being renamed, and then a trace recorded against
# the old rows is replayed against the new ones. That diverges at step 1 with a
# confusing row mismatch instead of saying the thing that is actually true,
# which is that this trace is of a different resource.
#
# So the seed is digested the way the language pins its tzdb fixture: the
# recorded digest is compared before any step is, and a mismatch is refused by
# name.
#
# Read with comments stripped, for the same reason the FCIS gate reads code
# that way — rewording the paragraph above `seeded_store` must not read as a
# change to the rows it returns.
#
# usage: scripts/seed-digest.sh [CORE_SOURCE]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
core=${1:-"$ROOT/modules/mock/core/mock.kofun"}

fail() {
    printf 'seed-digest: %s\n' "$*" >&2
    exit 1
}

test -f "$core" || fail "no such core source: $core"

block=$(sed 's/[[:space:]]*#.*$//' "$core" |
    sed -n '/^fn seeded_store() -> Store {$/,/^}$/p')

test -n "$block" || fail "$core declares no seeded_store()"

if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n' "$block" | sha256sum | cut -c1-16
elif command -v shasum >/dev/null 2>&1; then
    printf '%s\n' "$block" | shasum -a 256 | cut -c1-16
else
    fail 'no sha256sum or shasum available'
fi
