#!/bin/sh
set -eu

# The configuration gate: resolution is a value, and every byte of it is
# explained.
#
# Five things are checked, in this order:
#
#   1. the canonical contract declares the configuration surface, stops at
#      the documented compiler boundary, and shares its outcome sum with the
#      seed;
#   2. shell/input.kofun is what scripts/boot-config.sh compiles boot.conf
#      into, and the seed runs identically on both backends, twice, under a
#      hostile time zone and locale, and under env -i;
#   3. read out of what the binary printed: the application's input
#      resolved, each probe got the verdict it was written for, one override
#      changes exactly one line of `boot explain`, and an override beats the
#      pack that set the same field;
#   4. contracts/boot.explain is the projection of the resolved record;
#   5. each of those fails, by name, when broken in an isolated copy — and a
#      typo in boot.conf is refused with the nearest real name.
#
# The bar, from R2 (#17): one command reaches a passing application, and a
# second explains every byte of its wiring.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
KOFUN="$ROOT/vendor/kofun/bin/kofun"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-config.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'config: FAIL: %s\n' "$*" >&2
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

module=${CONFIG_MODULE:-"$ROOT/modules/config"}
explained=${CONFIG_EXPLAIN:-"$ROOT/contracts/boot.explain"}
contract="$module/contract/config.kofun"
core="$module/core/config.kofun"
shell="$module/shell/config.kofun"
input="$module/shell/input.kofun"
conf="$module/boot.conf"
expected="$module/tests/config.stdout"
for file in "$contract" "$core" "$shell" "$input" "$conf" "$expected"; do
    test -f "$file" || fail "missing: ${file#"$ROOT"/}"
done

# ---------------------------------------------------- canonical surface

for declaration in \
    'type Source =' \
    'type IntField = {' \
    'type TextField = {' \
    'type HttpMinimal = {' \
    'type ResolvedBoot = {' \
    'type BootInput = {' \
    'type ConfigCheck =' \
    'fn boot_resolve('
do
    require_line 'the canonical configuration surface lost a declaration' \
        "$declaration" "$contract"
done
require_line 'a canonical override no longer names its line' \
    '    | Override(file: Text, line: Int)' "$contract"

sed -n '/^type ConfigCheck =$/,/^$/p' "$contract" >"$WORK/contract.block"
sed -n '/^type ConfigCheck =$/,/^$/p' "$core" >"$WORK/core.block"
test -s "$WORK/core.block" || fail 'the seed no longer declares type ConfigCheck ='
cmp -s "$WORK/contract.block" "$WORK/core.block" ||
    fail "type ConfigCheck = differs between the canonical contract and the seed:
$(diff "$WORK/contract.block" "$WORK/core.block")"

if "$KOFUN" check "$contract" >"$WORK/contract.stdout" 2>"$WORK/contract.stderr"; then
    fail 'the canonical configuration contract unexpectedly claimed executable codegen'
fi
require_line 'the canonical contract did not stop at the documented boundary' \
    'error[E2S02]: expected top-level `fn` or `type`' "$WORK/contract.stderr"

printf 'config: the canonical surface and the seed share one outcome sum: PASS\n'

# ------------------------------------------------------------- the input

# boot.conf is read at build time and nowhere else. The input the shell
# resolves must be what the adapter compiles it into, under any environment.
sh "$ROOT/scripts/boot-config.sh" "$conf" >"$WORK/input.kofun" ||
    fail "boot.conf did not compile: $(sh "$ROOT/scripts/boot-config.sh" "$conf" 2>&1 >/dev/null)"
env -i PATH="$PATH" TZ=Pacific/Kiritimati LC_ALL=C \
    sh "$ROOT/scripts/boot-config.sh" "$conf" >"$WORK/input.bare.kofun"
cmp -s "$WORK/input.kofun" "$WORK/input.bare.kofun" ||
    fail 'boot.conf compiled differently under a hostile environment'
# The header names the file it came from, which differs for a copy.
sed 1d "$input" >"$WORK/input.committed"
sed 1d "$WORK/input.kofun" >"$WORK/input.compiled"
cmp -s "$WORK/input.committed" "$WORK/input.compiled" ||
    fail "shell/input.kofun is not what boot.conf compiles to; run: sh scripts/boot-config.sh >modules/config/shell/input.kofun
$(diff "$WORK/input.committed" "$WORK/input.compiled" | head -20)"

printf 'config: shell/input.kofun is boot.conf, compiled: PASS\n'

# ------------------------------------------------------------------ seed

seed="$WORK/config.unit.kofun"
: >"$seed"
for source in "$module"/core/*.kofun "$module"/shell/*.kofun; do
    cat "$source" >>"$seed"
    printf '\n' >>"$seed"
done

sed 's/[[:space:]]*#.*$//' "$seed" >"$WORK/seed.code"
if grep -qE 'clock_gettime|gettimeofday|getenv|fopen|socket\(|__linux_syscall|import ' \
    "$WORK/seed.code"
then
    fail 'the configuration seed names ambient state'
fi

"$KOFUN" check "$seed" >"$WORK/check.stdout" 2>"$WORK/check.stderr" ||
    fail "the configuration seed did not check: $(cat "$WORK/check.stderr")"
"$KOFUN" build "$seed" -o "$WORK/config" --emit-c "$WORK/config.c" \
    >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    fail "the configuration seed did not build: $(cat "$WORK/build.stderr")"

"$WORK/config" >"$WORK/out" || fail 'the configuration binary refused the application input'
"$KOFUN" run "$seed" >"$WORK/reference" 2>"$WORK/run.stderr" ||
    fail "the configuration seed did not run on the reference executor: $(cat "$WORK/run.stderr")"
cmp -s "$WORK/out" "$WORK/reference" ||
    fail 'reference executor and C11 backend disagree about the configuration'
"$WORK/config" >"$WORK/second"
cmp -s "$WORK/out" "$WORK/second" || fail 'two runs of the configuration binary differ'
TZ=Pacific/Kiritimati LC_ALL=tr_TR.UTF-8 LANG=tr_TR.UTF-8 "$WORK/config" >"$WORK/hostile"
cmp -s "$WORK/out" "$WORK/hostile" ||
    fail 'the configuration changed under TZ=Pacific/Kiritimati and a Turkish locale'
env -i "$WORK/config" >"$WORK/bare"
cmp -s "$WORK/out" "$WORK/bare" ||
    fail 'the resolved record changed with an empty environment'

if grep -qE 'time\.h|clock_gettime|gettimeofday|localtime|getenv|fopen|socket' \
    "$WORK/config.c"
then
    fail 'the emitted C reaches for ambient state'
fi

printf 'config: both backends agree, twice, under hostile TZ, locale, and env -i: PASS\n'

# ---------------------------------------------------- recorded decisions

section() {
    grep -qx "$1" "$WORK/out" || fail "the binary printed no '$1' section"
    grep -qx "end $1" "$WORK/out" || fail "the '$1' section is never closed"
    sed -n "/^$1\$/,/^end $1\$/p" "$WORK/out" | sed '1d;$d'
}

test "$(sed -n 1p "$WORK/out")" = 'kofun-boot config' ||
    fail 'the configuration report does not open with its title'
test "$(sed -n '/^contract$/{n;p;q;}' "$WORK/out")" = \
    "$(sed -n 's/^let CONFIG_CONTRACT_VERSION = //p' "$contract")" ||
    fail 'the binary names a contract version the canonical surface does not'

# Resolution comes first: the record is the first section after the title.
test "$(sed -n 4p "$WORK/out")" = resolved ||
    fail 'the resolved record is not the first thing the binary prints'
test "$(section resolved | wc -l | tr -d ' ')" = 16 ||
    fail 'the resolved record is not the packs and three lines for each of five fields'

# Rows are number kind payload conflicting. Kinds: 1 Accepted, 2 UnknownPack,
# 3 MissingBase, 4 PackConflict, 5 UnknownKey, 6 DuplicateKey, 7 OutOfRange.
section checks >"$WORK/checks"
test "$(sed -n 1p "$WORK/checks")" = 10 || fail 'expected ten probe inputs'
probe() {
    number=$1
    label=$2
    want=$3
    got=$(sed 1d "$WORK/checks" | paste - - - - | sed -n "${number}p" | cut -f2-4 | tr '\t' ' ')
    test "$got" = "$want" || fail "$label: expected '$want', got '$got'"
}
probe 1 'the base pack alone is accepted' '1 1 0'
probe 2 'one override is accepted' '1 1 0'
probe 3 'a starter on the base pack is accepted' '1 5 0'
probe 4 'an override on a starter is accepted' '1 5 0'
probe 5 'two starters that disagree are refused, naming body_limit and both packs' '4 3 12'
probe 6 'a starter without the base pack is refused' '3 1 0'
probe 7 'a pack nobody defined is refused' '2 16 0'
probe 8 'an unknown key is refused, naming it' '5 9 0'
probe 9 'a key set twice is refused, naming it' '6 2 0'
probe 10 'a value out of range is refused, naming the key' '7 2 0'

printf 'config: each probe input gets the verdict it was written for: PASS\n'

# boot explain, for the probes the binary resolved.
for number in 1 2 3 4; do
    sh "$ROOT/scripts/boot-explain.sh" --scenario "$number" "$WORK/config" \
        >"$WORK/explain.$number" || fail "probe $number has no explanation"
    test "$(wc -l <"$WORK/explain.$number" | tr -d ' ')" = 6 ||
        fail "probe $number's explanation is not the packs and five fields"
done
grep -q '^http.body_limit  2048       override  boot.conf:4$' "$WORK/explain.4" ||
    fail "an override did not win over the pack that set the same field:
$(sed 's/^/    /' "$WORK/explain.4")"
grep -q '^http.drain_ms    5000       pack      http_strict$' "$WORK/explain.4" ||
    fail 'a pack field next to an override no longer names its pack'
changed=$(diff "$WORK/explain.1" "$WORK/explain.2" | grep -c '^>' || true)
test "$changed" = 1 ||
    fail "one override changed $changed lines of boot explain, not exactly one"
diff "$WORK/explain.1" "$WORK/explain.2" | grep -q '^> http.port        9090       override  boot.conf:3$' ||
    fail 'the line one override changed is not http.port, from boot.conf line 3'
grep -c ' default   http_minimal$' "$WORK/explain.1" | grep -qx 5 ||
    fail 'the base pack alone does not explain all five fields as its defaults'

printf 'config: one override changes exactly one line of boot explain, and beats the pack: PASS\n'

lines=$(wc -l <"$WORK/out" | tr -d ' ')
test "$lines" -eq 135 || fail "the decisions above cover the whole report: expected 135 lines, got $lines"
cmp -s "$expected" "$WORK/out" ||
    fail "named decisions passed but the recorded configuration golden still differs:
$(diff "$expected" "$WORK/out" | head -20)"

# ----------------------------------------------------------- boot explain

sh "$ROOT/scripts/boot-explain.sh" "$WORK/config" >"$WORK/boot.explain" ||
    fail 'boot explain refused the application input'
test -f "$explained" || fail 'contracts/boot.explain is missing; run scripts/boot-explain.sh'
cmp -s "$explained" "$WORK/boot.explain" ||
    fail "contracts/boot.explain is not the projection of the resolved record:
$(diff "$explained" "$WORK/boot.explain" | head -20)"
for field in http.bind http.port http.body_limit http.drain_ms http.log_sink; do
    test "$(grep -c "^$field " "$WORK/boot.explain")" = 1 ||
        fail "boot explain does not explain $field exactly once"
done

printf 'config: contracts/boot.explain is the projection, one line per field, defaults included: PASS\n'

# ------------------------------------------------------------ break tests

if test "${CONFIG_SKIP_BREAK_TEST:-0}" != 1; then
    breaks="$WORK/breaks"
    mkdir -p "$breaks"

    # A typo in boot.conf is refused at the text, with the nearest real name.
    adapter_break() {
        name=$1
        text=$2
        message=$3
        printf '%s\n' "$text" >"$breaks/$name.conf"
        if sh "$ROOT/scripts/boot-config.sh" "$breaks/$name.conf" \
            >"$breaks/$name.kofun" 2>"$breaks/$name.log"
        then
            fail "the $name break compiled"
        fi
        require_line "the $name break was not refused by name" \
            "$message" "$breaks/$name.log"
    }
    adapter_break unknown-key 'http.prot = 9090' \
        'unknown key http.prot; did you mean http.port?'
    adapter_break unknown-pack 'packs = http_minimal, http_stric' \
        'unknown pack http_stric; did you mean http_strict?'
    adapter_break unnamed-value 'http.bind = localhost' \
        "http.bind takes 127.0.0.1 or 0.0.0.0, not 'localhost'"

    printf 'config: a typo in boot.conf is refused with the nearest real name: PASS\n'

    # A configuration with two packs that disagree. The binary must refuse
    # before printing any record, exit non-zero, and boot explain must name
    # the field and both packs.
    rm -rf "$breaks/conflict"
    cp -R "$module" "$breaks/conflict"
    printf 'packs = http_minimal, http_strict, http_lenient\n' >"$breaks/conflict/boot.conf"
    sh "$ROOT/scripts/boot-config.sh" "$breaks/conflict/boot.conf" \
        >"$breaks/conflict/shell/input.kofun"
    : >"$breaks/conflict.unit.kofun"
    for source in "$breaks/conflict"/core/*.kofun "$breaks/conflict"/shell/*.kofun; do
        cat "$source" >>"$breaks/conflict.unit.kofun"
        printf '\n' >>"$breaks/conflict.unit.kofun"
    done
    "$KOFUN" build "$breaks/conflict.unit.kofun" -o "$breaks/conflict.bin" >/dev/null 2>&1 ||
        fail 'the conflicting configuration did not build'
    if "$breaks/conflict.bin" >"$breaks/conflict.out"; then
        fail 'a configuration with two disagreeing packs resolved'
    fi
    grep -qx resolved "$breaks/conflict.out" &&
        fail 'a refused configuration printed a resolved record anyway'
    if sh "$ROOT/scripts/boot-explain.sh" "$breaks/conflict.bin" \
        >/dev/null 2>"$breaks/conflict.log"
    then
        fail 'boot explain explained a refused configuration'
    fi
    require_line 'the conflict was not named' \
        'refused: http.body_limit is set by both http_strict and http_lenient, to different values; select one' \
        "$breaks/conflict.log"

    printf 'config: two packs that disagree stop the boot before any record, naming both: PASS\n'

    config_break() {
        name=$1
        expression=$2
        message=$3
        rm -rf "$breaks/$name"
        cp -R "$module" "$breaks/$name"
        sed -i "$expression" "$breaks/$name/core/config.kofun"
        cmp -s "$core" "$breaks/$name/core/config.kofun" &&
            fail "the $name break changed nothing; its sed no longer matches the core"
        if CONFIG_MODULE="$breaks/$name" CONFIG_SKIP_BREAK_TEST=1 sh "$0" \
            >"$breaks/$name.log" 2>&1
        then
            fail "the $name break did not break the gate"
        fi
        require_line "the $name break was not rejected by name" \
            "$message" "$breaks/$name.log"
    }

    # A resolver that reads a starter before the override.
    config_break pack-beats-override \
        '/^fn value_of(input: BootInput, field: Int) -> Int {$/,/^}$/s/^    if slot > 0 {$/    if slot > 9 {/' \
        'an override did not win over the pack that set the same field'

    # A check that no longer compares the packs' values.
    config_break conflict-ignored \
        's/^    return 1 - eq(pack_value(left, field), pack_value(right, field))$/    return 0/' \
        "two starters that disagree are refused, naming body_limit and both packs: expected '4 3 12'"

    printf 'config: a pack that beats an override and an ignored conflict fail by name: PASS\n'

    # A hand-edited explanation.
    cp "$explained" "$breaks/boot.explain"
    sed -i 's/^http.port        9090       override  boot.conf:8$/http.port        8080       default   http_minimal/' \
        "$breaks/boot.explain"
    cmp -s "$explained" "$breaks/boot.explain" &&
        fail 'the explain hand-edit break changed nothing; its sed no longer matches contracts/boot.explain'
    if CONFIG_EXPLAIN="$breaks/boot.explain" CONFIG_SKIP_BREAK_TEST=1 sh "$0" \
        >"$breaks/explain.log" 2>&1
    then
        fail 'a hand-edited contracts/boot.explain did not break the gate'
    fi
    require_line 'the hand-edited explanation was not named' \
        'contracts/boot.explain is not the projection' "$breaks/explain.log"

    printf 'config: a hand-edited boot explain fails by name: PASS\n'
fi
