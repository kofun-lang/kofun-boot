#!/bin/sh
set -eu

# The schema gate.
#
# Five things are checked, in this order:
#
#   1. the canonical contract still declares the schema surface, still stops
#      at the documented compiler boundary, and shares its closed outcome and
#      drift sums with the seed exactly;
#   2. the seed runs identically on the reference interpreter and the C11
#      backend, twice, under a hostile time zone and locale, and under env -i;
#   3. named decisions are read out of what the binary printed: every
#      committed step applied, the history replays to the declared schema,
#      nothing is left to plan, the planner regenerates the history by key and
#      never supplies a policy, and every probe was refused without moving the
#      schema;
#   4. the committed SQL under contracts/ is exactly the projection of what
#      the binary printed;
#   5. each of those checks fails, by name, when the thing it protects is
#      broken in an isolated copy.
#
# Whether that SQL builds the same database both ways is a separate,
# real-database check: tests/schema/postgres.sh.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
KOFUN="$ROOT/vendor/kofun/bin/kofun"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-schema.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'schema: FAIL: %s\n' "$*" >&2
    exit 1
}

require_line() {
    label=$1
    needle=$2
    file=$3
    grep -Fq -- "$needle" "$file" ||
        fail "$label: no line matching: $needle"
}

test -x "$KOFUN" || test -f "$KOFUN" ||
    fail 'vendor/kofun is missing; run: git submodule update --init vendor/kofun'

module=${SCHEMA_MODULE:-"$ROOT/modules/schema"}
contracts=${SCHEMA_CONTRACTS:-"$ROOT/contracts"}
ddl=${SCHEMA_DDL:-"$ROOT/scripts/ddl.sh"}

contract="$module/contract/schema.kofun"
core="$module/core/schema.kofun"
shell="$module/shell/schema.kofun"
expected="$module/tests/schema.stdout"
for file in "$contract" "$core" "$shell" "$expected" "$ddl"; do
    test -f "$file" || fail "missing: ${file#"$ROOT"/}"
done

# ---------------------------------------------------- canonical surface

for declaration in \
    'type ColumnKey = {' \
    'type ColumnKind =' \
    'type Column = {' \
    'type Table = {' \
    'type Schema = {' \
    'type Policy =' \
    'type Migration =' \
    'type SchemaOutcome =' \
    'type Drift =' \
    'type ReplayError = {' \
    'fn schema_apply(' \
    'fn schema_replay(' \
    'fn schema_drift(' \
    'fn schema_plan(' \
    'fn schema_ddl(' \
    'fn schema_migration_sql('
do
    require_line 'the canonical schema surface lost a declaration' \
        "$declaration" "$contract"
done

# The spine of the contract: identity is a key, a retired key is part of the
# table, and a backfill carries the expression the slice cannot.
require_line 'a canonical column lost its key' '    key: ColumnKey,' "$contract"
require_line 'a canonical table no longer records its retired keys' \
    '    retired: List[ColumnKey],' "$contract"
require_line 'a canonical rename no longer names the key it renames' \
    '| RenameColumn(table: Text, key: ColumnKey, name: Text)' "$contract"
require_line 'the canonical backfill no longer carries its expression' \
    '| Backfill(expression: SqlExpression)' "$contract"

# The outcome and drift sums are the same type on both sides of the seam,
# compared as blocks: one constructor renamed or reordered is a difference.
for block in 'type SchemaOutcome =' 'type Drift ='; do
    sed -n "/^$block\$/,/^\$/p" "$contract" >"$WORK/contract.block"
    sed -n "/^$block\$/,/^\$/p" "$core" >"$WORK/core.block"
    test -s "$WORK/core.block" || fail "the seed no longer declares $block"
    cmp -s "$WORK/contract.block" "$WORK/core.block" ||
        fail "$block differs between the canonical contract and the seed:
$(diff "$WORK/contract.block" "$WORK/core.block")"
done

# Ahead of the compiler, on purpose: the executable evidence is the seed.
if "$KOFUN" check "$contract" >"$WORK/contract.stdout" 2>"$WORK/contract.stderr"; then
    fail 'the canonical schema contract unexpectedly claimed executable codegen'
fi
require_line 'the canonical contract did not stop at the documented boundary' \
    'error[E2S02]: expected top-level `fn` or `type`' "$WORK/contract.stderr"

printf 'schema: the canonical surface and the seed share one outcome sum: PASS\n'

# ------------------------------------------------------------------ seed

seed="$WORK/schema.unit.kofun"
cat "$core" >"$seed"
printf '\n' >>"$seed"
cat "$shell" >>"$seed"

sed 's/[[:space:]]*#.*$//' "$seed" >"$WORK/seed.code"
if grep -qE 'clock_gettime|gettimeofday|getenv|fopen|socket\(|__linux_syscall|import ' \
    "$WORK/seed.code"
then
    fail 'the schema seed names ambient state'
fi

"$KOFUN" check "$seed" >"$WORK/check.stdout" 2>"$WORK/check.stderr" ||
    fail "the schema seed did not check: $(cat "$WORK/check.stderr")"
"$KOFUN" build "$seed" -o "$WORK/schema" --emit-c "$WORK/schema.c" \
    >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    fail "the schema seed did not build: $(cat "$WORK/build.stderr")"

"$WORK/schema" >"$WORK/out"
"$KOFUN" run "$seed" >"$WORK/reference" 2>"$WORK/run.stderr" ||
    fail "the schema seed did not run on the reference executor: $(cat "$WORK/run.stderr")"
cmp -s "$WORK/out" "$WORK/reference" ||
    fail 'reference executor and C11 backend disagree about the schema'
"$WORK/schema" >"$WORK/second"
cmp -s "$WORK/out" "$WORK/second" || fail 'two runs of the schema binary differ'
TZ=Pacific/Kiritimati LC_ALL=tr_TR.UTF-8 LANG=tr_TR.UTF-8 "$WORK/schema" >"$WORK/hostile"
cmp -s "$WORK/out" "$WORK/hostile" ||
    fail 'the schema changed under TZ=Pacific/Kiritimati and a Turkish locale'
env -i "$WORK/schema" >"$WORK/bare"
cmp -s "$WORK/out" "$WORK/bare" || fail 'the schema changed with an empty environment'

if grep -qE 'time\.h|clock_gettime|gettimeofday|localtime|getenv|fopen|socket' \
    "$WORK/schema.c"
then
    fail 'the emitted C reaches for ambient state'
fi

printf 'schema: both backends agree, twice, under hostile TZ, locale, and env -i: PASS\n'

# ---------------------------------------------------- recorded decisions
#
# Read from the binary's output by section, never from the golden file: an
# assertion against the golden only proves the golden says what it says, and a
# changed rule would then fail as "output differs" naming nothing.

section() {
    grep -qx "$1" "$WORK/out" || fail "the binary printed no '$1' section"
    grep -qx "end $1" "$WORK/out" || fail "the '$1' section is never closed"
    sed -n "/^$1\$/,/^end $1\$/p" "$WORK/out" | sed '1d;$d'
}

test "$(sed -n 1p "$WORK/out")" = 'kofun-boot schema' ||
    fail 'the schema report does not open with its title'
test "$(sed -n '/^contract$/{n;p;q;}' "$WORK/out")" = \
    "$(sed -n 's/^let SCHEMA_CONTRACT_VERSION = //p' "$contract")" ||
    fail 'the binary names a contract version the canonical surface does not'

# History: every committed step applied. A refused step means the history
# does not describe any database, and the fold would quietly replay around it.
section history >"$WORK/history"
count=$(sed -n 1p "$WORK/history")
test "$count" -ge 1 || fail 'the history is empty'
sed -n '2,$p' "$WORK/history" | paste - - - - - - - - - - - >"$WORK/history.rows"
test "$(wc -l <"$WORK/history.rows" | tr -d ' ')" -eq "$count" ||
    fail "the history section does not hold $count eleven-line steps"
while IFS='	' read -r step kind table key label column_kind nullable policy outcome payload live; do
    if test "$outcome" -lt 1 || test "$outcome" -gt 5; then
        fail "history step $step was refused: outcome $outcome carrying $payload (kind $kind at key $key)"
    fi
done <"$WORK/history.rows"

history_row() {
    sed -n "$1p" "$WORK/history.rows" | tr '\t' ' '
}
test "$(history_row 5)" = '5 3 1 3 4 0 0 0 3 3 4' ||
    fail "the committed rename is not applied as a rename of key 3: $(history_row 5)"
test "$(history_row 7)" = '7 4 1 4 0 0 0 1 4 4 3' ||
    fail "the committed drop does not retire key 4 under its discard policy: $(history_row 7)"

# Drift. When the declaration and the history disagree, say where, and say
# what the planner would write to close it — that is the whole message a
# developer needs, and it is all in the output already.
section drift >"$WORK/drift"
drift_kind=$(sed -n 1p "$WORK/drift")
drift_payload=$(sed -n 2p "$WORK/drift")
refused=$(sed -n 3p "$WORK/drift")
traced=$(sed -n 4p "$WORK/drift")
test "$refused" = 0 ||
    fail "history step $refused was refused, so the history replays to no database"
test "$traced" = 1 ||
    fail 'the printed history and the replay the drift check used are different folds'
if test "$drift_kind" != 1; then
    section plan | paste - - - - - - - >"$WORK/plan.rows"
    planned=$(awk -F'\t' -v key="$drift_payload" '$3 == key { print $1; exit }' "$WORK/plan.rows")
    case ${planned:-0} in
        1) what='create the table' ;;
        2) what='an add' ;;
        3) what='a rename' ;;
        4) what='a drop, which needs a discard policy written into the history' ;;
        5) what='a nullability change' ;;
        *) what='nothing the planner can write; edit the declaration back or write the step by hand' ;;
    esac
    fail "the declared schema drifted from the migration history at key $drift_payload; the next migration for it is $what"
fi
test "$drift_payload" = 3 ||
    fail "the declared schema is in sync with $drift_payload live columns, expected 3"

section schema >"$WORK/schema.section"
test "$(sed -n '1,4p' "$WORK/schema.section" | tr '\n' ' ')" = '1 1 3 1 ' ||
    fail "the declared schema is not users(primary 1) with three live columns and one retired key: $(sed -n '1,4p' "$WORK/schema.section" | tr '\n' ' ')"
test "$(sed -n '20,24p' "$WORK/schema.section" | tr '\n' ' ')" = '4 0 0 0 2 ' ||
    fail 'key 4 is not declared retired; a dropped key that is not declared can be reissued'

# The plan is empty: a planned step is a migration somebody has not written.
section plan >"$WORK/plan"
test "$(wc -l <"$WORK/plan" | tr -d ' ')" -eq 28 ||
    fail 'the plan section is not seven lines for each of four keys'
paste - - - - - - - <"$WORK/plan" >"$WORK/plan.rows"
nonempty=$(awk -F'\t' '$1 != 0 { print "key " $3 " kind " $1 }' "$WORK/plan.rows")
test -z "$nonempty" || fail "the plan is not empty: $nonempty"

# The planner regenerates the history. Asked to get from the schema before
# each committed step to the schema after it, it proposes the same step at the
# same key — so a rename comes back as a rename, never as a drop and an add —
# and it proposes no policy, because every policy in the history was written
# by a person.
section regenerate >"$WORK/regenerate"
test "$(sed -n 1p "$WORK/regenerate")" = "$count" ||
    fail 'the planner was not asked to regenerate every committed step'
sed -n '2,$p' "$WORK/regenerate" | paste - - - - - - - - >"$WORK/regenerate.rows"
while IFS='	' read -r step kind table key label column_kind nullable policy; do
    test "$policy" = 0 ||
        fail "the planner supplied policy $policy for history step $step; a policy is a person's decision"
    committed=$(awk -F'\t' -v s="$step" '$1 == s { print $2, $3, $4, $5, $6, $7; exit }' "$WORK/history.rows")
    test "$kind $table $key $label $column_kind $nullable" = "$committed" ||
        fail "the planner did not regenerate history step $step: planned '$kind $table $key $label $column_kind $nullable', committed '$committed'"
done <"$WORK/regenerate.rows"

# Probes: each rule the history never needed, run once against the replayed
# schema. Refused, with the observed value, and the schema did not move.
section probes >"$WORK/probes"
test "$(sed -n 1p "$WORK/probes")" = 6 || fail 'expected six probes'
sed -n '2,$p' "$WORK/probes" | paste - - - - - - - - - - >"$WORK/probe.rows"
probe() {
    number=$1
    label=$2
    want=$3
    got=$(sed -n "${number}p" "$WORK/probe.rows" | awk -F'\t' '{ print $8, $9, $10 }')
    test "$got" = "$want" || fail "$label: expected '$want', got '$got'"
}
probe 1 'a second CreateTable names the table that exists' '6 1 0'
probe 2 'an add at a live key is a collision, not an update' '8 2 0'
probe 3 'a dropped key stays spent' '9 4 0'
probe 4 'a key past the bound names the bound' '15 4 0'
probe 5 'a drop with no policy is destructive' '13 3 0'
probe 6 'tightening a nullable column needs a backfill' '14 3 0'

lines=$(wc -l <"$WORK/out" | tr -d ' ')
test "$lines" -eq 267 || fail "the decisions above cover the whole report: expected 267 lines, got $lines"
cmp -s "$expected" "$WORK/out" ||
    fail "named decisions passed but the recorded schema golden still differs:
$(diff "$expected" "$WORK/out" | head -20)"

printf 'schema: every committed step applies and the history replays to the declaration: PASS\n'
printf 'schema: the planner regenerates the history by key and never supplies a policy: PASS\n'
printf 'schema: every refusal names what it observed and moves nothing: PASS\n'

# --------------------------------------------------------- the projections

for mode in schema migrations; do
    sh "$ddl" "$mode" "$WORK/schema" >"$WORK/$mode.sql" ||
        fail "the $mode projection refused the binary's output"
    env -i PATH="$PATH" TZ=Pacific/Kiritimati LC_ALL=C \
        sh "$ddl" "$mode" "$WORK/schema" >"$WORK/$mode.bare.sql"
    cmp -s "$WORK/$mode.sql" "$WORK/$mode.bare.sql" ||
        fail "the $mode projection changed under a hostile environment"
    test "$mode" = schema && committed="$contracts/schema.sql"
    test "$mode" = migrations && committed="$contracts/migrations.sql"
    test -f "$committed" || fail "${committed#"$ROOT"/} is missing; run scripts/ddl.sh $mode"
    cmp -s "$committed" "$WORK/$mode.sql" ||
        fail "${committed#"$ROOT"/} is not the projection of the schema the binary printed:
$(diff "$committed" "$WORK/$mode.sql" | head -20)"
done

printf 'schema: contracts/schema.sql and contracts/migrations.sql are projections, not edits: PASS\n'

# ------------------------------------------------------------ break tests
#
# Each check above, broken in an isolated copy and required to fail by name.
# The recursive runs skip this block, so a mutation can never pass by
# recursing.

if test "${SCHEMA_SKIP_BREAK_TEST:-0}" != 1; then
    breaks="$WORK/breaks"
    mkdir -p "$breaks"

    schema_break() {
        name=$1
        expression=$2
        message=$3
        rm -rf "$breaks/$name"
        cp -R "$module" "$breaks/$name"
        sed -i "$expression" "$breaks/$name/core/schema.kofun"
        cmp -s "$core" "$breaks/$name/core/schema.kofun" &&
            fail "the $name break changed nothing; its sed no longer matches the core"
        if SCHEMA_MODULE="$breaks/$name" SCHEMA_SKIP_BREAK_TEST=1 sh "$0" \
            >"$breaks/$name.log" 2>&1
        then
            fail "the $name break did not break the gate"
        fi
        require_line "the $name break was not rejected by name" \
            "$message" "$breaks/$name.log"
    }

    # The declaration renamed without a migration. The gate names the key and
    # says the next migration is a rename — not a drop and an add.
    schema_break declared-rename \
        's/^        c3_label: label_display_name(),$/        c3_label: label_name(),/' \
        'drifted from the migration history at key 3; the next migration for it is a rename'

    # A dropped key that the declaration forgot to keep retired.
    schema_break forgotten-retirement \
        's/^        c4_state: slot_retired()$/        c4_state: slot_empty()/' \
        'drifted from the migration history at key 4'

    # A committed drop with its policy removed: the history no longer applies.
    schema_break history-policy \
        's/^            policy_discard()$/            policy_none()/' \
        'history step 7 was refused: outcome 13'

    # A planner that reads a label change as a drop. Every property around it
    # still holds — the history applies, nothing drifts — and only the
    # regeneration check can see that the planner would have destroyed data.
    schema_break planner-drop \
        's/^                    step_rename_column(), desired.table, key,$/                    step_drop_column(), desired.table, key,/' \
        'the planner did not regenerate history step 5'

    printf 'schema: a declared rename, a forgotten retirement, a missing policy, and a destructive planner fail by name: PASS\n'

    # A hand-edited projection.
    cp -R "$contracts" "$breaks/contracts"
    sed -i 's/^    display_name text, -- key 3$/    display_name text not null, -- key 3/' \
        "$breaks/contracts/schema.sql"
    cmp -s "$contracts/schema.sql" "$breaks/contracts/schema.sql" &&
        fail 'the hand-edit break changed nothing; its sed no longer matches contracts/schema.sql'
    if SCHEMA_CONTRACTS="$breaks/contracts" SCHEMA_SKIP_BREAK_TEST=1 sh "$0" \
        >"$breaks/contracts.log" 2>&1
    then
        fail 'a hand-edited contracts/schema.sql did not break the gate'
    fi
    require_line 'the hand-edited projection was not named' \
        'contracts/schema.sql is not the projection' "$breaks/contracts.log"

    # A column the projection cannot name is refused, and refused before any
    # SQL is printed: half a script on stdout is worse than none.
    sed "/^        4) printf 'display_name' ;;\$/d" "$ddl" >"$breaks/ddl.sh"
    cmp -s "$ddl" "$breaks/ddl.sh" &&
        fail 'the unnamed-column break changed nothing; its sed no longer matches scripts/ddl.sh'
    if sh "$breaks/ddl.sh" schema "$WORK/schema" >"$breaks/ddl.out" 2>"$breaks/ddl.err"; then
        fail 'the projection accepted a column label it has no name for'
    fi
    require_line 'the unnamed column was not named' \
        'column label 4 has no name' "$breaks/ddl.err"
    test ! -s "$breaks/ddl.out" ||
        fail 'the projection printed SQL before refusing'

    printf 'schema: a hand-edited projection and an unnamed column fail by name: PASS\n'
fi
