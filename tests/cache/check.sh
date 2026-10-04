#!/bin/sh
set -eu

# The cache gate: a key that is the handler's arguments, staleness that is
# declared, and a trace that replays.
#
# Five things are checked, in this order:
#
#   1. the canonical contract declares the cache surface, stops at the
#      documented compiler boundary, and shares both outcome sums with the
#      seed;
#   2. the seed runs identically on both backends, twice, under a hostile
#      time zone and locale, and under env -i, so the trace of hits and
#      misses is the same bytes on every run;
#   3. read out of what the binary printed: each read handler's parameters
#      are the arguments its cache declares, every declared cache passes the
#      build-time check, each probe gets the refusal it was written for, and
#      every value the session served is what the read returns uncached;
#   4. contracts/caches.txt is the projection of the declarations;
#   5. each of those fails, by name, when broken in an isolated copy.
#
# A key that omits an argument is refused before anything runs. The trace
# then shows what the refusal prevents: with the check out of the way, the
# same key serves one caller's answer to another.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
KOFUN="$ROOT/vendor/kofun/bin/kofun"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-cache.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'cache: FAIL: %s\n' "$*" >&2
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

module=${CACHE_MODULE:-"$ROOT/modules/cache"}
manifest=${CACHE_MANIFEST:-"$ROOT/contracts/caches.txt"}
contract="$module/contract/cache.kofun"
core="$module/core/cache.kofun"
shell="$module/shell/cache.kofun"
expected="$module/tests/cache.stdout"
for file in "$contract" "$core" "$shell" "$expected"; do
    test -f "$file" || fail "missing: ${file#"$ROOT"/}"
done

# ---------------------------------------------------- canonical surface

for declaration in \
    'type Lifetime =' \
    'type Tag = {' \
    'type Cache = {' \
    'type Invalidates = {' \
    'type CacheCheck =' \
    'type CacheEvent =' \
    'fn cache_check('
do
    require_line 'the canonical cache surface lost a declaration' \
        "$declaration" "$contract"
done
require_line 'a canonical key is no longer the parameter list' \
    '    key: List[Text],' "$contract"
require_line 'a canonical tag lost its scope' \
    '    scope: Option[Text],' "$contract"

for block in 'type CacheCheck =' 'type CacheEvent ='; do
    sed -n "/^$block\$/,/^\$/p" "$contract" >"$WORK/contract.block"
    sed -n "/^$block\$/,/^\$/p" "$core" >"$WORK/core.block"
    test -s "$WORK/core.block" || fail "the seed no longer declares $block"
    cmp -s "$WORK/contract.block" "$WORK/core.block" ||
        fail "$block differs between the canonical contract and the seed:
$(diff "$WORK/contract.block" "$WORK/core.block")"
done

if "$KOFUN" check "$contract" >"$WORK/contract.stdout" 2>"$WORK/contract.stderr"; then
    fail 'the canonical cache contract unexpectedly claimed executable codegen'
fi
require_line 'the canonical contract did not stop at the documented boundary' \
    'error[E2S02]: expected top-level `fn` or `type`' "$WORK/contract.stderr"

printf 'cache: the canonical surface and the seed share both outcome sums: PASS\n'

# ------------------------------------------------------------------ seed

seed="$WORK/cache.unit.kofun"
cat "$core" >"$seed"
printf '\n' >>"$seed"
cat "$shell" >>"$seed"

sed 's/[[:space:]]*#.*$//' "$seed" >"$WORK/seed.code"
if grep -qE 'clock_gettime|gettimeofday|getenv|fopen|socket\(|__linux_syscall|import ' \
    "$WORK/seed.code"
then
    fail 'the cache seed names ambient state'
fi

"$KOFUN" check "$seed" >"$WORK/check.stdout" 2>"$WORK/check.stderr" ||
    fail "the cache seed did not check: $(cat "$WORK/check.stderr")"
"$KOFUN" build "$seed" -o "$WORK/cache" --emit-c "$WORK/cache.c" \
    >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    fail "the cache seed did not build: $(cat "$WORK/build.stderr")"

"$WORK/cache" >"$WORK/out"
"$KOFUN" run "$seed" >"$WORK/reference" 2>"$WORK/run.stderr" ||
    fail "the cache seed did not run on the reference executor: $(cat "$WORK/run.stderr")"
cmp -s "$WORK/out" "$WORK/reference" ||
    fail 'reference executor and C11 backend disagree about the cache'
"$WORK/cache" >"$WORK/second"
cmp -s "$WORK/out" "$WORK/second" || fail 'two runs of the cache binary differ'
TZ=Pacific/Kiritimati LC_ALL=tr_TR.UTF-8 LANG=tr_TR.UTF-8 "$WORK/cache" >"$WORK/hostile"
cmp -s "$WORK/out" "$WORK/hostile" ||
    fail 'the cache changed under TZ=Pacific/Kiritimati and a Turkish locale'
env -i "$WORK/cache" >"$WORK/bare"
cmp -s "$WORK/out" "$WORK/bare" || fail 'the cache changed with an empty environment'

if grep -qE 'time\.h|clock_gettime|gettimeofday|localtime|getenv|fopen|socket' \
    "$WORK/cache.c"
then
    fail 'the emitted C reaches for ambient state'
fi

printf 'cache: both backends agree, twice, under hostile TZ, locale, and env -i: PASS\n'

# ---------------------------------------------------- recorded decisions

section() {
    grep -qx "$1" "$WORK/out" || fail "the binary printed no '$1' section"
    grep -qx "end $1" "$WORK/out" || fail "the '$1' section is never closed"
    sed -n "/^$1\$/,/^end $1\$/p" "$WORK/out" | sed '1d;$d'
}

test "$(sed -n 1p "$WORK/out")" = 'kofun-boot cache' ||
    fail 'the cache report does not open with its title'
test "$(sed -n '/^contract$/{n;p;q;}' "$WORK/out")" = \
    "$(sed -n 's/^let CACHE_CONTRACT_VERSION = //p' "$contract")" ||
    fail 'the binary names a contract version the canonical surface does not'

op_name() {
    case $1 in
        1) printf 'list' ;;
        2) printf 'show' ;;
        3) printf 'mine' ;;
        4) printf 'put' ;;
        5) printf 'give' ;;
        *) return 1 ;;
    esac
}

arg_bit() {
    case $1 in
        id) printf 1 ;;
        caller) printf 2 ;;
        *) return 1 ;;
    esac
}

arg_list() {
    names=''
    if test $(($1 % 2)) = 1; then
        names='id'
    fi
    if test $(($1 / 2 % 2)) = 1; then
        names=${names:+"$names, "}caller
    fi
    printf '(%s)' "$names"
}

section caches >"$WORK/caches"
test "$(sed -n 1p "$WORK/caches")" = 3 || fail 'expected a cache on each of three read endpoints'
sed 1d "$WORK/caches" | paste - - - - - >"$WORK/cache.rows"
test "$(wc -l <"$WORK/cache.rows" | tr -d ' ')" = 3 ||
    fail 'the caches section does not hold three five-line rows'

# The key's half of the rule is in the core: the key must hold the declared
# arguments. This is the other half: the declared arguments must be the
# handler's parameters. The slice has no reflection, so the source is read.
# The first parameter is the data the cache stands in front of; every one
# after it is an argument a key must hold.
sed 's/[[:space:]]*#.*$//' "$core" >"$WORK/core.code"
while IFS='	' read -r read args key lifetime tags; do
    name=$(op_name "$read") || fail "read code $read has no name"
    signature=$(grep -E "^fn read_$name\(" "$WORK/core.code" | head -1)
    test -n "$signature" || fail "cache.$name: the core has no handler read_$name"
    parameters=$(printf '%s\n' "$signature" |
        sed 's/^fn [a-z_]*(//; s/).*$//' | tr ',' '\n' |
        sed 's/:.*$//; s/^[[:space:]]*//' | sed 1d)
    taken=0
    for parameter in $parameters; do
        bit=$(arg_bit "$parameter") ||
            fail "read_$name takes parameter $parameter, which no argument bit names; a key could not hold it"
        if test $((args / bit % 2)) != 1; then
            fail "read_$name takes parameter $parameter, but its declared arguments are $(arg_list "$args")"
        fi
        taken=$((taken + bit))
    done
    test "$taken" = "$args" ||
        fail "read_$name is declared to take $(arg_list "$args"), but its parameters are $(arg_list "$taken")"
done <"$WORK/cache.rows"

printf "cache: each read handler's parameters are the arguments its cache declares: PASS\n"

# Every declared cache passes the build-time check. The projection names a
# refusal, so the gate asks it rather than keeping a second set of names.
section check >"$WORK/check"
test "$(sed -n 1p "$WORK/check")" = 3 || fail 'expected a verdict for each of three caches'
if sed 1d "$WORK/check" | paste - - - | awk -F'\t' '$2 != 1 { found = 1 } END { exit !found }'; then
    if sh "$ROOT/scripts/cache-manifest.sh" "$WORK/cache" >/dev/null 2>"$WORK/refused"; then
        fail 'the build-time check refused a cache, and the manifest projection did not'
    fi
    fail "$(sed 's/^cache-manifest: //' "$WORK/refused")"
fi

printf 'cache: every declared cache passes the build-time check: PASS\n'

# Each probe is a declaration the application does not make. Rows are read
# args key lifetime tags covered kind payload.
section probes >"$WORK/probes"
test "$(sed -n 1p "$WORK/probes")" = 5 || fail 'expected five probes of the check'
probe() {
    number=$1
    label=$2
    want=$3
    got=$(sed 1d "$WORK/probes" | paste - - - - - - - - | sed -n "${number}p" | cut -f7,8 | tr '\t' ' ')
    test "$got" = "$want" || fail "$label: expected verdict '$want', got '$got'"
}
probe 1 'a per-caller cache whose key omits the caller is refused as KeyOmits(caller)' '2 2'
probe 2 'a key naming an argument the handler does not take is refused as KeyForeign(caller)' '3 2'
probe 3 'a cache that never expires under a tag no write drops is refused as Uninvalidated(thing)' '4 2'
probe 4 'a cache that never expires and has no tag is refused as NeverRefreshed(show)' '5 2'
probe 5 'a finite lifetime makes an uncovered tag sound' '1 3'

printf 'cache: each refusal of the check fires on the declaration written for it: PASS\n'

# The session. Rows are step op id value caller now event payload fresh
# removed live; events are 1 Miss, 2 Hit, 3 Expired, 4 Invalidated.
section trace >"$WORK/trace"
calls=$(sed -n 1p "$WORK/trace")
sed 1d "$WORK/trace" | paste - - - - - - - - - - - >"$WORK/steps"
test "$(wc -l <"$WORK/steps" | tr -d ' ')" = "$calls" ||
    fail "the trace says $calls calls but holds $(wc -l <"$WORK/steps" | tr -d ' ') rows"

# Read your writes, and nobody else's answers: every value a read served is
# what the same read returns with no cache in front of it. A stale entry and
# a leaked one fail this the same way, and the row names which call it was.
awk -F'\t' '$7 != 4 && $8 != $9 { print; exit }' "$WORK/steps" >"$WORK/wrong"
if test -s "$WORK/wrong"; then
    IFS='	' read -r step op id value caller now event payload fresh removed live <"$WORK/wrong"
    name=$(op_name "$op") || fail "read code $op has no name"
    kind=hit
    if test "$event" = 3; then
        kind='refreshed read'
    fi
    fail "step $step: $name (id $id, caller $caller) was a $kind that served $payload, but the read returns $fresh uncached; an entry outlived a write that changed it, or was shared across a key it should not have been"
fi

for event in 1 2 3 4; do
    awk -F'\t' -v e="$event" '$7 == e { found = 1 } END { exit !found }' "$WORK/steps" ||
        fail "the session never records event $event; the trace no longer exercises every way a call can meet the cache"
done
awk -F'\t' '$7 != 4 && $10 > 0 { found = 1 } END { exit !found }' "$WORK/steps" ||
    fail 'the session never fills the cache, so eviction is never exercised'
awk -F'\t' '$11 > 4 { print "step " $1 " holds " $11 " entries"; exit 1 }' "$WORK/steps" >"$WORK/over" ||
    fail "the cache grew past its four slots: $(cat "$WORK/over")"
# One row, two callers, two answers: the session must ask a question whose
# answer depends on who asks, or the check above could not see a leak.
test "$(awk -F'\t' '$2 == 3 && $3 == 1 && $6 < 6 { print $8 }' "$WORK/steps" | sort -u | wc -l | tr -d ' ')" = 2 ||
    fail 'the session no longer asks one row for two callers with different answers'

printf 'cache: every served value equals the uncached read, and every event is exercised: PASS\n'

lines=$(wc -l <"$WORK/out" | tr -d ' ')
test "$lines" -eq 339 || fail "the decisions above cover the whole report: expected 339 lines, got $lines"
cmp -s "$expected" "$WORK/out" ||
    fail "named decisions passed but the recorded cache golden still differs:
$(diff "$expected" "$WORK/out" | head -20)"

printf 'cache: the trace of hits and misses is the recorded one, byte for byte: PASS\n'

# ------------------------------------------------------------ the manifest

sh "$ROOT/scripts/cache-manifest.sh" "$WORK/cache" >"$WORK/caches.txt" ||
    fail 'the manifest projection refused the declared caches'
env -i PATH="$PATH" TZ=Pacific/Kiritimati LC_ALL=C \
    sh "$ROOT/scripts/cache-manifest.sh" "$WORK/cache" >"$WORK/caches.bare.txt"
cmp -s "$WORK/caches.txt" "$WORK/caches.bare.txt" ||
    fail 'the manifest projection changed under a hostile environment'
test -f "$manifest" || fail 'contracts/caches.txt is missing; run scripts/cache-manifest.sh'
cmp -s "$manifest" "$WORK/caches.txt" ||
    fail "contracts/caches.txt is not the projection of the caches the binary declared:
$(diff "$manifest" "$WORK/caches.txt" | head -20)"
for name in list show mine; do
    test "$(grep -c "^cache\.$name " "$WORK/caches.txt")" = 1 ||
        fail "cache.$name does not appear exactly once in the manifest"
done
grep -q '^cache\.mine .* http private, ' "$WORK/caches.txt" ||
    fail 'a cache whose key holds the caller is not private to HTTP caches'
grep -q '^cache\.show .* http public, no-cache$' "$WORK/caches.txt" ||
    fail 'a cache that never expires was handed to HTTP caches that nothing invalidates'

printf 'cache: contracts/caches.txt is the projection, one row per declared cache: PASS\n'

# ------------------------------------------------------------ break tests

if test "${CACHE_SKIP_BREAK_TEST:-0}" != 1; then
    breaks="$WORK/breaks"
    mkdir -p "$breaks"

    cache_break() {
        name=$1
        expression=$2
        message=$3
        rm -rf "$breaks/$name"
        cp -R "$module" "$breaks/$name"
        sed -i "$expression" "$breaks/$name/core/cache.kofun"
        cmp -s "$core" "$breaks/$name/core/cache.kofun" &&
            fail "the $name break changed nothing; its sed no longer matches the core"
        if CACHE_MODULE="$breaks/$name" CACHE_SKIP_BREAK_TEST=1 sh "$0" \
            >"$breaks/$name.log" 2>&1
        then
            fail "the $name break did not break the gate"
        fi
        require_line "the $name break was not rejected by name" \
            "$message" "$breaks/$name.log"
    }

    # The leak itself: the per-caller cache keyed on the row alone.
    cache_break key-omits-caller \
        's/^    return cache(op_mine(), arg_id() + arg_caller(), 30, tag_thing())$/    return cache(op_mine(), arg_id(), 30, tag_thing())/' \
        'cache.mine is refused by the build-time check: its key omits argument caller'

    # The same key, with the declared arguments edited to agree with it. The
    # core's check passes; the handler still takes the caller.
    cache_break arguments-follow-key \
        's/arg_id() + arg_caller()/arg_id()/g' \
        'read_mine takes parameter caller, but its declared arguments are (id)'

    # No write drops `thing`, and show never expires.
    cache_break uninvalidated-tag \
        's/invalidating(op_put(), tag_things() + tag_thing())/invalidating(op_put(), tag_things())/;s/invalidating(op_give(), tag_thing())/invalidating(op_give(), 0)/' \
        'cache.show is refused by the build-time check: tag thing(id) has no invalidating write and the cache never expires'

    # Giving a row away forgets to drop it. Every tag is still covered by
    # some write, so the build-time check passes; the trace does not.
    cache_break forgotten-invalidation \
        's/invalidating(op_give(), tag_thing())/invalidating(op_give(), 0)/' \
        'step 13: mine (id 1, caller 9) was a hit that served 0, but the read returns 15 uncached'

    printf 'cache: a key without the caller, arguments edited to match it, an uninvalidated tag, and a forgotten invalidation fail by name: PASS\n'

    # A hand-edited manifest: the per-caller row made public.
    cp "$manifest" "$breaks/caches.txt"
    sed -i 's/http private, max-age=30$/http public, max-age=30/' "$breaks/caches.txt"
    cmp -s "$manifest" "$breaks/caches.txt" &&
        fail 'the manifest hand-edit break changed nothing; its sed no longer matches contracts/caches.txt'
    if CACHE_MANIFEST="$breaks/caches.txt" CACHE_SKIP_BREAK_TEST=1 sh "$0" \
        >"$breaks/manifest.log" 2>&1
    then
        fail 'a hand-edited contracts/caches.txt did not break the gate'
    fi
    require_line 'the hand-edited manifest was not named' \
        'contracts/caches.txt is not the projection' "$breaks/manifest.log"

    printf 'cache: a hand-edited manifest fails by name: PASS\n'
fi
