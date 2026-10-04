#!/bin/sh
set -eu

# The scaffold is a tested fixture, not a template.
#
# `boot new` emits a project; this generates one into a temporary directory,
# runs *its* gate, and then checks the properties the scaffold exists to
# guarantee: the boundary, and a schema whose history must replay to it. A
# scaffold verified only by having been written once rots the first time the
# language moves, and rots in someone else's afternoon rather than in this
# build.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-scaffold.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'scaffold: FAIL: %s\n' "$*" >&2
    exit 1
}

project="$WORK/acme"
sh "$ROOT/scripts/new.sh" "$project" --name acme >"$WORK/new.log" 2>&1 ||
    fail "boot new failed:
$(sed 's/^/    /' "$WORK/new.log")"

for expected in core/core.kofun core/core_test.kofun shell/shell.kofun \
    tests/check.sh build.sh README.md db.sh \
    modules/schema/core/schema.kofun modules/schema/core/schema_test.kofun \
    modules/schema/shell/schema.kofun
do
    test -f "$project/$expected" || fail "boot new did not emit $expected"
done

# The generated project's own gate: its boundary, its unit suite, its recorded
# output, and its determinism under an empty environment.
(cd "$project" && sh tests/check.sh) >"$WORK/gate.log" 2>&1 ||
    fail "the generated project did not pass its own gate:
$(sed 's/^/    /' "$WORK/gate.log")"
grep -q 'PASS' "$WORK/gate.log" ||
    fail "the generated project's gate produced no PASS line:
$(sed 's/^/    /' "$WORK/gate.log")"

suites=$(sed -n 's/.*Tests  \([0-9][0-9]*\) passed.*/\1/p' "$WORK/gate.log" | head -1)
test -n "$suites" && test "$suites" -ge 6 ||
    fail "the scaffold's suite shrank: expected at least 6 tests, saw '${suites:-none}'"
schema_tests=$(sed -n 's/.*Tests  \([0-9][0-9]*\) passed.*/\1/p' "$WORK/gate.log" | sed -n 2p)
test -n "$schema_tests" && test "$schema_tests" -ge 7 ||
    fail "the scaffold's schema suite shrank: expected at least 7 tests, saw '${schema_tests:-none}'"

# The schema the project starts with: one table whose history replays to it,
# and the SQL the gate recorded from the declaration.
grep -q '^db check: the history replays to the declaration' "$WORK/gate.log" ||
    fail "the generated gate did not run db check:
$(sed 's/^/    /' "$WORK/gate.log")"
test -f "$project/modules/schema/schema.sql" ||
    fail 'the generated gate did not record modules/schema/schema.sql'
grep -q '^create table items ($' "$project/modules/schema/schema.sql" ||
    fail "the recorded schema is not one items table:
$(sed 's/^/    /' "$project/modules/schema/schema.sql")"

# The scaffold's reason to exist: a new project starts on the right side of the
# boundary. Prove the generated gate actually enforces it rather than only
# printing about it — break the generated core and require its own gate to
# refuse.
cp "$project/core/core.kofun" "$WORK/core.bak"
printf '\nfn smuggle() -> Int {\n    let c: Capabilities = Capabilities(now_seconds: 0)\n    return c.now_seconds\n}\n' \
    >>"$project/core/core.kofun"
if (cd "$project" && sh tests/check.sh) >"$WORK/broken.log" 2>&1; then
    fail 'the generated gate accepted a core that constructs a capability'
fi
grep -q 'constructs a capability' "$WORK/broken.log" ||
    fail "the generated gate refused for the wrong reason:
$(sed 's/^/    /' "$WORK/broken.log")"
cp "$WORK/core.bak" "$project/core/core.kofun"

# A declaration edited without its migration. The generated gate must name
# the key and say what the planner proposes, not merely fail.
schema_core="$project/modules/schema/core/schema.kofun"
cp "$schema_core" "$WORK/schema.bak"
sed 's/^        c2_state: slot_empty(),$/        c2_state: slot_live(),/' "$WORK/schema.bak" >"$schema_core"
cmp -s "$schema_core" "$WORK/schema.bak" &&
    fail 'the declaration break changed nothing; its sed no longer matches the generated schema'
if (cd "$project" && sh tests/check.sh) >"$WORK/drifted.log" 2>&1; then
    fail 'the generated gate accepted a declaration edited without its migration'
fi
grep -q 'the declaration and the history disagree at key 2' "$WORK/drifted.log" ||
    fail "the generated gate did not name the drifted key:
$(sed 's/^/    /' "$WORK/drifted.log")"
grep -q 'Append the step the planner proposes' "$WORK/drifted.log" ||
    fail 'the generated gate named the key but not the step the planner proposes'
cp "$WORK/schema.bak" "$schema_core"

# A hand-edited schema.sql.
cp "$project/modules/schema/schema.sql" "$WORK/sql.bak"
sed 's/^    id bigint not null,/    id integer not null,/' "$WORK/sql.bak" >"$project/modules/schema/schema.sql"
cmp -s "$project/modules/schema/schema.sql" "$WORK/sql.bak" &&
    fail 'the schema.sql break changed nothing; its sed no longer matches the recorded SQL'
if (cd "$project" && sh tests/check.sh) >"$WORK/sql.log" 2>&1; then
    fail 'the generated gate accepted a hand-edited modules/schema/schema.sql'
fi
grep -q 'modules/schema/schema.sql is not the projection' "$WORK/sql.log" ||
    fail "the generated gate refused a hand-edited schema.sql for the wrong reason:
$(sed 's/^/    /' "$WORK/sql.log")"
cp "$WORK/sql.bak" "$project/modules/schema/schema.sql"

printf 'scaffold: boot new emits a project that passes its own gate: PASS\n'
printf 'scaffold: and that gate refuses a core which reaches for a capability: PASS\n'
printf 'scaffold: the project owns a schema, and its gate names a key edited without a migration: PASS\n'
