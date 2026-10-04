#!/bin/sh
set -eu

# The loader gate: N+1 as a measurement.
#
# Four things are checked, in this order:
#
#   1. the canonical contract still declares the loader surface, stops at the
#      documented compiler boundary, and shares its outcome sum with the seed;
#   2. the seed runs identically on both backends, twice, under a hostile time
#      zone and locale, and under env -i;
#   3. read out of what the binary printed: every strategy loads the same
#      answer at every N; the strategy the application ships with costs the
#      same number of statements at every N; the sequential strategy is
#      flagged, so the detector is shown to be able to fail; and the
#      interpreter sends one statement per source and each key once;
#   4. each of those fails, by name, when broken in an isolated copy.
#
# The bar is deliberately not a number. Django's assertNumQueries pins how
# many queries one fixture costs, which passes a per-row loader for as long as
# the fixture is small. This pins that the count does not depend on N.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
KOFUN="$ROOT/vendor/kofun/bin/kofun"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-loader.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'loader: FAIL: %s\n' "$*" >&2
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

module=${LOADER_MODULE:-"$ROOT/modules/loader"}
contract="$module/contract/loader.kofun"
core="$module/core/loader.kofun"
shell="$module/shell/loader.kofun"
expected="$module/tests/loader.stdout"
for file in "$contract" "$core" "$shell" "$expected"; do
    test -f "$file" || fail "missing: ${file#"$ROOT"/}"
done

# ---------------------------------------------------- canonical surface

for declaration in \
    'type Source =' \
    'type Fetch = {' \
    'type Round = {' \
    'type Statement = {' \
    'type Batch = {' \
    'type LoadOutcome =' \
    'fn loader_coalesce(' \
    'fn loader_scales(' \
    'type Load =' \
    'type Shape = {' \
    'type DialectCapabilities = {' \
    'type ShapeOutcome =' \
    'fn loader_compile_shape('
do
    require_line 'the canonical loader surface lost a declaration' \
        "$declaration" "$contract"
done
require_line 'a canonical statement no longer carries the keys it sends' \
    '    keys: List[Int],' "$contract"
require_line 'the canonical sources lost the declared shape' \
    '| Shape(name: Text)' "$contract"

for block in 'type LoadOutcome =' 'type ShapeOutcome ='; do
    sed -n "/^$block\$/,/^\$/p" "$contract" >"$WORK/contract.block"
    sed -n "/^$block\$/,/^\$/p" "$core" >"$WORK/core.block"
    test -s "$WORK/core.block" || fail "the seed no longer declares $block"
    cmp -s "$WORK/contract.block" "$WORK/core.block" ||
        fail "$block differs between the canonical contract and the seed:
$(diff "$WORK/contract.block" "$WORK/core.block")"
done

if "$KOFUN" check "$contract" >"$WORK/contract.stdout" 2>"$WORK/contract.stderr"; then
    fail 'the canonical loader contract unexpectedly claimed executable codegen'
fi
require_line 'the canonical contract did not stop at the documented boundary' \
    'error[E2S02]: expected top-level `fn` or `type`' "$WORK/contract.stderr"

printf 'loader: the canonical surface and the seed share one outcome sum: PASS\n'

# ------------------------------------------------------------------ seed

seed="$WORK/loader.unit.kofun"
cat "$core" >"$seed"
printf '\n' >>"$seed"
cat "$shell" >>"$seed"

sed 's/[[:space:]]*#.*$//' "$seed" >"$WORK/seed.code"
if grep -qE 'clock_gettime|gettimeofday|getenv|fopen|socket\(|__linux_syscall|import ' \
    "$WORK/seed.code"
then
    fail 'the loader seed names ambient state'
fi
# The database is the shell's. A core that could name it could read it, and
# then a row could load something behind a field read after all.
sed 's/[[:space:]]*#.*$//' "$core" >"$WORK/core.code"
if grep -nE 'Database|fn execute' "$WORK/core.code" >"$WORK/hit"; then
    fail "the loader core names the database: $(head -1 "$WORK/hit")"
fi

"$KOFUN" check "$seed" >"$WORK/check.stdout" 2>"$WORK/check.stderr" ||
    fail "the loader seed did not check: $(cat "$WORK/check.stderr")"
"$KOFUN" build "$seed" -o "$WORK/loader" --emit-c "$WORK/loader.c" \
    >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    fail "the loader seed did not build: $(cat "$WORK/build.stderr")"

"$WORK/loader" >"$WORK/out"
"$KOFUN" run "$seed" >"$WORK/reference" 2>"$WORK/run.stderr" ||
    fail "the loader seed did not run on the reference executor: $(cat "$WORK/run.stderr")"
cmp -s "$WORK/out" "$WORK/reference" ||
    fail 'reference executor and C11 backend disagree about the loader'
"$WORK/loader" >"$WORK/second"
cmp -s "$WORK/out" "$WORK/second" || fail 'two runs of the loader binary differ'
TZ=Pacific/Kiritimati LC_ALL=tr_TR.UTF-8 LANG=tr_TR.UTF-8 "$WORK/loader" >"$WORK/hostile"
cmp -s "$WORK/out" "$WORK/hostile" ||
    fail 'the loader changed under TZ=Pacific/Kiritimati and a Turkish locale'
env -i "$WORK/loader" >"$WORK/bare"
cmp -s "$WORK/out" "$WORK/bare" || fail 'the loader changed with an empty environment'

if grep -qE 'time\.h|clock_gettime|gettimeofday|localtime|getenv|fopen|socket' \
    "$WORK/loader.c"
then
    fail 'the emitted C reaches for ambient state'
fi

printf 'loader: both backends agree, twice, under hostile TZ, locale, and env -i: PASS\n'

# ---------------------------------------------------- recorded decisions

section() {
    grep -qx "$1" "$WORK/out" || fail "the binary printed no '$1' section"
    grep -qx "end $1" "$WORK/out" || fail "the '$1' section is never closed"
    sed -n "/^$1\$/,/^end $1\$/p" "$WORK/out" | sed '1d;$d'
}

test "$(sed -n 1p "$WORK/out")" = 'kofun-boot loader' ||
    fail 'the loader report does not open with its title'
test "$(sed -n '/^contract$/{n;p;q;}' "$WORK/out")" = \
    "$(sed -n 's/^let LOADER_CONTRACT_VERSION = //p' "$contract")" ||
    fail 'the binary names a contract version the canonical surface does not'

shipped=$(section strategy)

section requests >"$WORK/requests"
test "$(sed -n 1p "$WORK/requests")" = 12 || fail 'expected twelve requests: three strategies at four sizes'
sed -n '2,$p' "$WORK/requests" | paste - - - - - - - >"$WORK/rows"
test "$(wc -l <"$WORK/rows" | tr -d ' ')" -eq 12 ||
    fail 'the requests section does not hold twelve seven-line rows'

# Every request finished, and every strategy loaded the same answer at each
# N. Batching changes how the question is sent, never what the answer is.
stalled=$(awk -F'\t' '$6 != 1 { print "strategy " $1 " at N=" $2 " stalled at round " $7 }' "$WORK/rows")
test -z "$stalled" || fail "a request did not finish: $stalled"
for n in 1 2 3 4; do
    answers=$(awk -F'\t' -v n="$n" '$2 == n { print $7 }' "$WORK/rows" | sort -u | wc -l | tr -d ' ')
    test "$answers" = 1 ||
        fail "the strategies disagree about the answer at N=$n: $(awk -F'\t' -v n="$n" '$2 == n { printf "strategy %s=%s ", $1, $7 }' "$WORK/rows")"
done

# Statements per strategy, in N order, as one line: "2 3 4 5".
statements() {
    awk -F'\t' -v s="$1" '$1 == s { print $4 }' "$WORK/rows" | tr '\n' ' ' | sed 's/ $//'
}
rounds() {
    awk -F'\t' -v s="$1" '$1 == s { print $3 }' "$WORK/rows" | tr '\n' ' ' | sed 's/ $//'
}
constant() {
    test "$(printf '%s\n' $1 | sort -u | wc -l | tr -d ' ')" = 1
}

# The bar, applied to what the application ships with.
constant "$(statements "$shipped")" ||
    fail "N+1: the application's strategy $shipped costs $(statements "$shipped") statements for N = 1 2 3 4; a count that grows with N grows with production data"

# The detector must be able to say no. The sequential strategy is the await-
# in-a-loop shape, and it is in the output precisely so this check is never
# vacuous: if it ever stops growing, the measurement has stopped measuring.
test "$(statements 1)" = '2 3 4 5' ||
    fail "the sequential strategy no longer costs N + 1 statements ($(statements 1)); the detector has nothing to detect"
constant "$(statements 1)" &&
    fail 'the detector accepted a strategy whose statements grow with N'

test "$(statements 2)" = '2 2 2 2' ||
    fail "one round per dependency level is not two statements at every N: $(statements 2)"
test "$(rounds 2)" = '2 2 2 2' ||
    fail "rounds are not bounded by dependency depth: $(rounds 2)"
test "$(statements 3)" = '1 1 1 1' ||
    fail "a declared shape is not one statement at every N: $(statements 3)"

# The binary's own detector agrees with the gate's reading of the rows.
section verdict >"$WORK/verdict"
test "$(sed -n 1p "$WORK/verdict")" = 3 || fail 'expected a verdict for each of three strategies'
sed -n '2,$p' "$WORK/verdict" | paste - - - - >"$WORK/verdict.rows"
test "$(tr '\t' ' ' <"$WORK/verdict.rows" | tr '\n' ';')" = '1 2 5 1;2 2 2 0;3 1 1 0;' ||
    fail "the binary's N+1 detector disagrees with the rows: $(tr '\t' ' ' <"$WORK/verdict.rows" | tr '\n' ';')"

section coalesce >"$WORK/coalesce"
test "$(sed -n 1p "$WORK/coalesce")" = 3 || fail 'expected three coalescing probes'
probe() {
    number=$1
    label=$2
    want=$3
    got=$(sed -n '2,$p' "$WORK/coalesce" | paste - - | sed -n "${number}p" | tr '\t' ' ')
    test "$got" = "$want" || fail "$label: expected '$want', got '$got'"
}
probe 1 'a key asked for twice in one round is sent once' '1 2'
probe 2 'three sources in one round are three statements' '3 1'
probe 3 'an empty round sends nothing' '0 0'

# Shapes: a join is one statement where the dialect has LATERAL, and refused
# by name where it does not; a split is one statement per level everywhere.
# Rows are load dialect outcome payload lateral; outcome 1 is Compiled, 2 is
# NeedsLateral.
section shapes >"$WORK/shapes"
test "$(sed -n 1p "$WORK/shapes")" = 4 || fail 'expected four (shape, dialect) rows'
shape_row() {
    sed -n '2,$p' "$WORK/shapes" | paste - - - - - | sed -n "$1p" | tr '\t' ' '
}
test "$(shape_row 1)" = '1 1 1 1 1' ||
    fail "a joined shape on postgresql is not one statement: $(shape_row 1)"
test "$(shape_row 2)" = '2 1 1 2 1' ||
    fail "a split shape on postgresql is not one statement per level: $(shape_row 2)"
test "$(shape_row 3)" = '1 2 2 1 0' ||
    fail "a join on a dialect without LATERAL was not refused naming its relation: $(shape_row 3)"
test "$(shape_row 4)" = '2 2 1 2 0' ||
    fail "a split shape on sqlite is not one statement per level: $(shape_row 4)"
# The shipped declared-shape strategy costs exactly what the shape compiles to.
test "$(statements 3 | cut -d' ' -f1)" = "$(shape_row 1 | cut -d' ' -f4)" ||
    fail 'the declared-shape strategy and the shape it declares disagree about the statement count'

section database >"$WORK/database"
test "$(tr '\n' ' ' <"$WORK/database")" = '4 3 1 4 1 ' ||
    fail "the seed database is not four authors with 3 1 4 1 posts: $(tr '\n' ' ' <"$WORK/database")"

lines=$(wc -l <"$WORK/out" | tr -d ' ')
test "$lines" -eq 147 || fail "the decisions above cover the whole report: expected 147 lines, got $lines"
cmp -s "$expected" "$WORK/out" ||
    fail "named decisions passed but the recorded loader golden still differs:
$(diff "$expected" "$WORK/out" | head -20)"

printf 'loader: every strategy loads the same answer at every N: PASS\n'
printf 'loader: the shipped strategy costs the same statements at every N, and N+1 is flagged: PASS\n'
printf 'loader: one statement per source, each key sent once: PASS\n'
printf 'loader: a join is one statement where LATERAL exists and refused by name where it does not: PASS\n'

# ------------------------------------------------------ the shape projection
#
# contracts/shapes.sql is what the shapes look like in PostgreSQL. It is the
# projection of what the binary printed, never an edit, and each block holds
# as many statements as the binary said its shape compiles to.

shapes_sql=${LOADER_SHAPES_SQL:-"$ROOT/contracts/shapes.sql"}
sh "$ROOT/scripts/shape-sql.sh" shapes "$WORK/loader" >"$WORK/shapes.sql" ||
    fail 'the shape projection refused the binary output'
env -i PATH="$PATH" TZ=Pacific/Kiritimati LC_ALL=C \
    sh "$ROOT/scripts/shape-sql.sh" shapes "$WORK/loader" >"$WORK/shapes.bare.sql"
cmp -s "$WORK/shapes.sql" "$WORK/shapes.bare.sql" ||
    fail 'the shape projection changed under a hostile environment'
test -f "$shapes_sql" || fail 'contracts/shapes.sql is missing; run scripts/shape-sql.sh shapes'
cmp -s "$shapes_sql" "$WORK/shapes.sql" ||
    fail "contracts/shapes.sql is not the projection of the shapes the binary printed:
$(diff "$shapes_sql" "$WORK/shapes.sql" | head -20)"
for load in join split; do
    # Not `-v load=`: gawk refuses that name as a command-line variable.
    printed=$(awk -v want="$load" '
        $0 ~ ("load " want ":") { inside = 1; next }
        /^-- shape:/ { inside = 0 }
        inside && /;$/ { n++ }
        END { print n + 0 }
    ' "$WORK/shapes.sql")
    case $load in
        join) declared=$(shape_row 1 | cut -d' ' -f4) ;;
        split) declared=$(shape_row 2 | cut -d' ' -f4) ;;
    esac
    test "$printed" = "$declared" ||
        fail "the $load shape's SQL holds $printed statements, but the binary says it compiles to $declared"
done
if sh "$ROOT/scripts/shape-sql.sh" shapes --dialect sqlite "$WORK/loader" \
    >"$WORK/sqlite.sql" 2>"$WORK/sqlite.err"
then
    fail 'the shape projection produced SQL for a join on a dialect without LATERAL'
fi
require_line 'the sqlite refusal does not name the relation' \
    'a join of relation posts cannot compile for sqlite: it has no LATERAL' "$WORK/sqlite.err"
test ! -s "$WORK/sqlite.sql" || fail 'the shape projection printed SQL before refusing'

printf 'loader: contracts/shapes.sql is the projection, and each block holds the statements its shape compiles to: PASS\n'

# ------------------------------------------------------------ break tests

if test "${LOADER_SKIP_BREAK_TEST:-0}" != 1; then
    breaks="$WORK/breaks"
    mkdir -p "$breaks"

    loader_break() {
        name=$1
        expression=$2
        message=$3
        rm -rf "$breaks/$name"
        cp -R "$module" "$breaks/$name"
        sed -i "$expression" "$breaks/$name/core/loader.kofun"
        cmp -s "$core" "$breaks/$name/core/loader.kofun" &&
            fail "the $name break changed nothing; its sed no longer matches the core"
        if LOADER_MODULE="$breaks/$name" LOADER_SKIP_BREAK_TEST=1 sh "$0" \
            >"$breaks/$name.log" 2>&1
        then
            fail "the $name break did not break the gate"
        fi
        require_line "the $name break was not rejected by name" \
            "$message" "$breaks/$name.log"
    }

    # The application switched to awaiting one author at a time. Every other
    # property still holds — same answers, deterministic, both backends — and
    # only the measurement can see it.
    loader_break sequential-app \
        '/^fn app_strategy() -> Int {$/,/^}$/s/^    return 2$/    return 1/' \
        "N+1: the application's strategy 1 costs 2 3 4 5 statements"

    # An interpreter that sends each fetch as its own statement. The
    # application did nothing wrong, and its count grows anyway.
    loader_break no-coalescing \
        's/^    return positive(hits)$/    return hits/' \
        "N+1: the application's strategy 2 costs 2 3 4 5 statements"

    # An interpreter that forgets a key it already sent.
    loader_break no-dedupe \
        's/^        + eq(round.f2_source, source_posts_by_author()) \* (1 - repeats(round, 2))$/        + eq(round.f2_source, source_posts_by_author())/' \
        "a key asked for twice in one round is sent once: expected '1 2'"

    printf 'loader: a sequential application, an uncoalesced interpreter, and a lost dedupe fail by name: PASS\n'

    # A compiler that forgets to ask the dialect: a join "compiles" on a
    # target with no LATERAL, which is the silent fallback the refusal exists
    # to prevent.
    loader_break lateral-ignored \
        's/^        if target.lateral == 0 {$/        if target.lateral == 9 {/' \
        'a join on a dialect without LATERAL was not refused naming its relation'

    # A hand-edited projection.
    cp "$shapes_sql" "$breaks/shapes.sql"
    sed -i 's/^order by a.id;$/order by a.id desc;/' "$breaks/shapes.sql"
    cmp -s "$shapes_sql" "$breaks/shapes.sql" &&
        fail 'the shapes hand-edit break changed nothing; its sed no longer matches contracts/shapes.sql'
    if LOADER_SHAPES_SQL="$breaks/shapes.sql" LOADER_SKIP_BREAK_TEST=1 sh "$0" \
        >"$breaks/shapes.log" 2>&1
    then
        fail 'a hand-edited contracts/shapes.sql did not break the gate'
    fi
    require_line 'the hand-edited shapes were not named' \
        'contracts/shapes.sql is not the projection' "$breaks/shapes.log"

    printf 'loader: a compiler that ignores the dialect and a hand-edited shape fail by name: PASS\n'
fi
