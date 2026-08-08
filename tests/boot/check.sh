#!/bin/sh
set -eu

# The kofun-boot gate.
#
# Four things are checked, in this order:
#
#   1. the router-owned canonical surface still declares the framework
#      contract, and still stops at the documented compiler boundary rather
#      than pretending to be executable;
#   2. the executable seed runs identically on the reference interpreter and
#      the C11 backend, and specific dispatch decisions are read from its
#      output rather than accepted wholesale from a golden file;
#   3. nothing in the seed reaches ambient state — asserted against the code
#      with comments stripped, and demonstrated by re-running under a hostile
#      environment and comparing bytes.
#   4. the effects module preserves continuation ids and turns success,
#      timeout and subscription delivery into a deterministic Cmd/Msg trace.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
KOFUN="$ROOT/vendor/kofun/bin/kofun"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'boot: FAIL: %s\n' "$*" >&2
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

# ---------------------------------------------------- canonical surface

router_module=${ROUTER_MODULE:-"$ROOT/modules/router"}
canonical="$router_module/contract/router.kofun"
test -f "$canonical" || fail 'canonical surface is missing'

for declaration in \
    'type Method =' \
    'type Path = {' \
    'type Route = {' \
    'type RouteTable = {' \
    'type Request = {' \
    'type RouteResult =' \
    'type Capabilities = {' \
    'type Response = {' \
    'fn boot_compile(' \
    'fn boot_dispatch(' \
    'fn boot_handle(' \
    'fn boot_openapi(' \
    'fn boot_client('
do
    require_line 'canonical surface lost a declaration' \
        "$declaration" "$canonical"
done

# The contract's spine: failures carry what was observed, and the capability
# record is the only door to the outside.
require_line 'canonical MethodNotAllowed no longer carries the Allow set' \
    '| MethodNotAllowed(allowed: List[Method])' "$canonical"
require_line 'canonical PayloadTooLarge no longer carries the limit' \
    '| PayloadTooLarge(limit: Int, observed: Int)' "$canonical"
require_line 'canonical Capabilities lost the injected clock' \
    '    clock: MonotonicClock,' "$canonical"
# A match that does not say what it captured cannot serve `/things/:id`, and
# the seed's capture projection would then be answering a question the
# contract no longer asks.
require_line 'canonical Matched no longer carries the captured segments' \
    '| Matched(handler: HandlerId, captures: List[Text])' "$canonical"

# Still ahead of the compiler, on purpose. The executable evidence is the
# seed, not this file.
if "$KOFUN" check "$canonical" \
    >"$WORK/canonical.stdout" 2>"$WORK/canonical.stderr"
then
    fail 'canonical surface unexpectedly claimed executable codegen'
fi
require_line 'canonical surface did not stop at the documented boundary' \
    'error[E2S02]: expected top-level `fn` or `type`' "$WORK/canonical.stderr"

# ------------------------------------------------------------------ seed

core="$router_module/core/router.kofun"
shell="$router_module/shell/router.kofun"
expected="$router_module/tests/router.stdout"
test -f "$core" || fail 'core source is missing'
test -f "$shell" || fail 'shell source is missing'
test -f "$expected" || fail 'seed golden is missing'

# The core/shell boundary, enforced rather than described.
#
# Read with comments stripped: both files spend paragraphs explaining what the
# core refuses to reach, and a grep over the whole text cannot tell that
# explanation from a violation. The core may *name* the Capabilities type in a
# signature — receiving a capability is the whole point — but it may not
# construct one, because constructing is how a pure function would smuggle in
# an authority nobody handed it.
sed 's/[[:space:]]*#.*$//' "$core" >"$WORK/core.code"
if grep -qE 'Capabilities\(' "$WORK/core.code"; then
    printf '%s\n' \
        'boot: FAIL: the functional core constructs a capability instead of receiving one:' >&2
    grep -nE 'Capabilities\(' "$WORK/core.code" >&2
    exit 1
fi
if grep -qE '^fn main' "$WORK/core.code"; then
    fail 'the functional core owns an entry point; emission belongs to the shell'
fi
if ! grep -qE 'Capabilities\(' "$(sed 's/[[:space:]]*#.*$//' "$shell" >"$WORK/shell.code"; echo "$WORK/shell.code")"; then
    fail 'the shell no longer builds the capability record; the boundary has moved without being moved'
fi

# The seed the rest of this gate exercises is the two layers concatenated, the
# way scripts/build-seed.sh assembles them for a developer.
seed="$WORK/router.unit.kofun"
cat "$core" >"$seed"
printf '\n' >>"$seed"
cat "$shell" >>"$seed"

# Nothing ambient, asserted against code rather than prose: both files spend
# comments explaining what they refuse to reach, and a grep over the whole
# text cannot tell that explanation from a violation.
sed 's/[[:space:]]*#.*$//' "$seed" >"$WORK/seed.code"
if grep -qE 'clock_gettime|gettimeofday|getenv|fopen|socket\(|__linux_syscall|import ' \
    "$WORK/seed.code"
then
    fail 'the seed names ambient state'
fi

"$KOFUN" check "$seed" >"$WORK/check.stdout" 2>"$WORK/check.stderr" ||
    fail "seed did not check: $(cat "$WORK/check.stderr")"

"$KOFUN" build "$seed" -o "$WORK/router" --emit-c "$WORK/router.c" \
    >"$WORK/build.stdout" 2>"$WORK/build.stderr" ||
    fail "seed did not build: $(cat "$WORK/build.stderr")"

"$WORK/router" >"$WORK/backend.stdout"

"$KOFUN" run "$seed" >"$WORK/reference.stdout" 2>"$WORK/run.stderr" ||
    fail "seed did not run on the reference executor: $(cat "$WORK/run.stderr")"
cmp "$WORK/backend.stdout" "$WORK/reference.stdout" ||
    fail 'reference executor and C11 backend disagree'

"$WORK/router" >"$WORK/backend.second"
cmp "$WORK/backend.stdout" "$WORK/backend.second" ||
    fail 'two executions of the same router binary differ'

# Replayable means replayable: hostile time zone, hostile locale, and an
# empty environment must not move one byte.
TZ=Pacific/Kiritimati LC_ALL=C LANG=C "$WORK/router" >"$WORK/hostile.stdout"
cmp "$WORK/backend.stdout" "$WORK/hostile.stdout" ||
    fail 'output changed under TZ=Pacific/Kiritimati'
env -i "$WORK/router" >"$WORK/bare.stdout"
cmp "$WORK/backend.stdout" "$WORK/bare.stdout" ||
    fail 'output changed with an empty environment'

# The emitted C reaches nothing the source did not name.
if grep -qE 'time\.h|clock_gettime|gettimeofday|localtime|getenv|fopen|socket' \
    "$WORK/router.c"
then
    fail 'the emitted C reaches for ambient state'
fi

# ------------------------------------------------ the capability manifest
#
# What the binary can reach, printed by the binary, read here from what it
# printed. Never from the source: a source-derived manifest proves what the
# source says, and the question is what this artifact does. That is the same
# technique the FCIS check uses in reverse — it reads code with comments
# stripped because prose about not doing something must not satisfy a check
# about not doing it.

grep -qx 'end manifest' "$WORK/backend.stdout" ||
    fail 'the binary printed no capability manifest'
marker=$(grep -n -x 'end manifest' "$WORK/backend.stdout" | head -1 | cut -d: -f1)
sed -n "1,${marker}p" "$WORK/backend.stdout" >"$WORK/manifest"
sed -n "$((marker + 1)),\$p" "$WORK/backend.stdout" >"$WORK/body"

# The manifest precedes every other line the program emits. A record printed
# after the first effect describes a binary that has already done something.
test "$(sed -n 1p "$WORK/manifest")" = 'kofun-boot capability manifest' ||
    fail 'the capability manifest is not the first thing the binary prints'

# Named rows, read out of the printed manifest. `grep -A` from the label so a
# row that moves is still found and a row that vanishes fails by its name.
row_state() {
    grep -A1 -Fx -- "$1" "$WORK/manifest" | sed -n 2p
}
row_scope() {
    grep -A2 -Fx -- "$1" "$WORK/manifest" | sed -n 3p
}

assert_granted() {
    label=$1
    test "$(row_state "$label")" = granted ||
        fail "$label: expected a granted row, got '$(row_state "$label")'"
    # A granted row for a scopable capability must name its scope. A capability
    # system whose grants are boolean is a feature-flag system with better
    # vocabulary, so an unscoped grant is a failure rather than a shorter row.
    scope=$(row_scope "$label")
    case $scope in
        ''|*[!0-9]*)
            fail "$label: granted without a scope (got '$scope')" ;;
    esac
    test "$scope" -ne 0 ||
        fail "$label: granted with the denied sentinel as its scope"
}

assert_denied() {
    label=$1
    test "$(row_state "$label")" = denied ||
        fail "$label: expected a denied row, got '$(row_state "$label")'"
}

for granted in clock.monotonic clock.system tzdb entropy log db.credential; do
    assert_granted "$granted"
done
# The three rows the manifest exists for. A set that listed only grants could
# not be read for what is absent, and absence is what an operator checks.
for denied in net.listen net.connect fs; do
    assert_denied "$denied"
done

# Tied to the artifact that printed it: the contract the manifest is written
# against, and a digest of the capability declaration itself.
test "$(row_state contract)" = "$(sed -n 's/^let BOOT_CONTRACT_VERSION = //p' "$canonical")" ||
    fail 'the manifest names a contract version the canonical surface does not'

digest=$(sh "$ROOT/scripts/capability-digest.sh" "$core")
test "$(row_state build)" = "$digest" ||
    fail "the manifest's build identity is stale: printed $(row_state build), the capability record digests to $digest"

# No secret material. The credential capability names its store; the material
# is never in the record, so the manifest has nothing to leak — asserted rather
# than assumed, because "it cannot happen" is what every leak was before it did.
#
# The fixture is read from the shell rather than repeated here, and the check
# is then proved non-vacuous in two steps: the value must exist, and it must be
# present in the built artifact. A grep for a value that is not in the binary
# passes for the wrong reason and would keep passing after the leak.
material=$(sed 's/[[:space:]]*#.*$//' "$shell" |
    sed -n '/^fn credential_material() -> Int {$/,/^}$/p' |
    sed -n 's/^[[:space:]]*return \([0-9][0-9]*\)$/\1/p')
test -n "$material" ||
    fail 'the shell no longer carries a credential fixture; the secret check would pass vacuously'
grep -q -- "$material" "$WORK/router.c" ||
    fail "the credential fixture $material is not in the built artifact; the secret check would pass vacuously"
if grep -qx -- "$material" "$WORK/manifest"; then
    fail 'the credential material appears in the capability manifest'
fi

printf 'boot: the effective capability set is printed, scoped, and read from the binary: PASS\n'
printf 'boot: denied capabilities are printed as denied: PASS\n'

# ------------------------------------------- recorded dispatch decisions
#
# Twenty table lines — four per slot, because the capture flag is compiled
# state — then five lines per dispatch (method, path, kind, payload, capture),
# then five handler lines. Kind 1 Matched, 2 NotFound, 3 MethodNotAllowed,
# 4 PayloadTooLarge. Each assertion names the rule it reads, so a failure says
# which decision moved.
#
# These read the binary's output, not the golden file. Asserting against the
# golden only proves the golden says what it says: a changed rule would be
# caught by the `cmp` below as "output differs" and name nothing. Reading the
# run is what lets a broken rule fail by the name of the rule, which is the
# same reason the effects section reads its own backend output.

# Offsets are into the body — everything after the manifest — so the startup
# record can grow a section without renumbering every dispatch assertion below.
field() {
    sed -n "$1,$2p" "$WORK/body" | tr '\n' ' '
}

assert_field() {
    label=$1
    from=$2
    to=$3
    want=$4
    got=$(field "$from" "$to")
    test "$got" = "$want" ||
        fail "$label: expected '$want', got '$got'"
}

assert_field 'the compiled table is the five declared routes' \
    1 20 '1 101 1 0 2 102 2 0 1 103 3 0 2 103 4 0 1 104 5 1 '
assert_field 'exactly one slot is compiled as capturing' \
    17 20 '1 104 5 1 '
assert_field 'a matched route names its handler' \
    21 25 '1 101 1 1 0 '
assert_field 'a second route matches independently' \
    26 30 '2 102 1 2 0 '
assert_field 'a wrong method names the method that would have worked' \
    31 35 '1 102 3 2 0 '
assert_field 'a path with two methods matches the right one' \
    36 40 '2 103 1 4 0 '
assert_field 'an unknown path is NotFound carrying the path' \
    41 45 '1 999 2 999 0 '
assert_field 'an oversized body is refused before the table is consulted' \
    46 50 '1 101 4 4096 0 '
assert_field 'an oversized body to an unknown path reports the same thing' \
    51 55 '1 999 4 4096 0 '
assert_field 'the limit itself is inside the limit' \
    56 60 '1 101 1 1 0 '
assert_field 'the Allow set does not depend on the request method' \
    61 65 '9 103 3 3 0 '

# The capture rules. The first is the whole claim of this section: a capturing
# route reports the segment, and the segment is not the path — 7 out of
# 104007. An implementation that echoed the path would satisfy "a capture was
# reported" and fail here.
assert_field 'a capturing route reports the segment it captured, not the path' \
    66 70 '1 104007 1 5 7 '
# The flag decides, not the shape of the code. A request built exactly the way
# a captured path is built, aimed at a literal slot, matches nothing and
# captures nothing.
assert_field 'a captured-looking path does not match a literal route' \
    71 75 '1 103007 2 103007 0 '
# A capturing slot is a slot: it joins the Allow set like any other, and a
# refusal carries no capture because no route was taken.
assert_field 'a capturing route joins the Allow set and refuses without capturing' \
    76 80 '2 104007 3 1 0 '

assert_field 'a handler is pure and its clock is the injected field' \
    81 85 '200 101042 200 106 101043 '

lines=$(wc -l <"$WORK/body" | tr -d ' ')
test "$lines" -eq 85 ||
    fail "recorded decisions cover the whole body: expected 85 lines, got $lines"

# Every named decision passed, so a difference here is a line no assertion
# owns. Checked last, and against the run rather than the other way round.
cmp "$expected" "$WORK/backend.stdout" ||
    fail 'named decisions passed but the recorded dispatch golden still differs'

# The table refuses duplicates by construction today: prove the five pairs
# are distinct rather than trusting the comment that says so.
dupes=$(sed -n '1,20p' "$WORK/body" | paste - - - - | awk '{print $1, $2}' | sort | uniq -d)
test -z "$dupes" || fail "duplicate (method, path) pair in the table: $dupes"

# A capturing slot whose base collides with a literal slot's code would make
# one of them unreachable, and the matcher would answer by slot order rather
# than by the table. Nothing forbids it yet, so the gate does.
captures=$(sed -n '1,20p' "$WORK/body" | paste - - - - | awk '$4 == 1 { print $2 }')
literals=$(sed -n '1,20p' "$WORK/body" | paste - - - - | awk '$4 == 0 { print $2 }')
for base in $captures; do
    for code in $literals; do
        test "$base" != "$code" ||
            fail "capturing base $base collides with a literal route code"
    done
done

# Do not merely assert the capture rule — break it in an isolated module copy
# and require this same gate to reject it by name. Echoing the path is the
# failure worth testing for: it still reports "a capture", still varies with
# the request, and still replays identically, so every property around it
# holds while the one that matters is wrong. The recursive run skips this
# block, so a mutation can never pass by recursing.
if test "${ROUTER_SKIP_BREAK_TEST:-0}" != 1; then
    router_breaks="$WORK/router-breaks"
    mkdir -p "$router_breaks"

    cp -R "$router_module" "$router_breaks/capture"
    sed -i 's|return request_path % capture_base()|return request_path|' \
        "$router_breaks/capture/core/router.kofun"
    if ROUTER_MODULE="$router_breaks/capture" \
        ROUTER_SKIP_BREAK_TEST=1 EFFECTS_SKIP_BREAK_TEST=1 sh "$0" \
        >"$WORK/router.break-capture.log" 2>&1
    then
        fail 'making the capture echo the path did not break the gate'
    fi
    require_line 'the capture break was not rejected by name' \
        'a capturing route reports the segment it captured, not the path' \
        "$WORK/router.break-capture.log"

    printf 'boot: the capture break test fails by name: PASS\n'

    # A row dropped from the emission. This is the failure the manifest is
    # least able to notice on its own: the remaining rows are all correct, the
    # bytes are still stable, and the only evidence is a row that is no longer
    # there. The gate reads rows by name, so absence is what it reports.
    cp -R "$router_module" "$router_breaks/manifest-row"
    sed -i '/^    print("net.listen")$/,+1d' \
        "$router_breaks/manifest-row/shell/router.kofun"
    if ROUTER_MODULE="$router_breaks/manifest-row" \
        ROUTER_SKIP_BREAK_TEST=1 EFFECTS_SKIP_BREAK_TEST=1 sh "$0" \
        >"$WORK/router.break-manifest-row.log" 2>&1
    then
        fail 'dropping a row from the capability manifest did not break the gate'
    fi
    require_line 'the dropped manifest row was not named' \
        'net.listen: expected a denied row' \
        "$WORK/router.break-manifest-row.log"

    # A grant without a scope. "granted" alone is a feature flag with better
    # vocabulary: it cannot answer which roots, which hosts, which port.
    cp -R "$router_module" "$router_breaks/manifest-scope"
    sed -i '/^    print("granted")$/{n;/^    print(scope)$/d;}' \
        "$router_breaks/manifest-scope/shell/router.kofun"
    if ROUTER_MODULE="$router_breaks/manifest-scope" \
        ROUTER_SKIP_BREAK_TEST=1 EFFECTS_SKIP_BREAK_TEST=1 sh "$0" \
        >"$WORK/router.break-manifest-scope.log" 2>&1
    then
        fail 'a granted capability printed without its scope did not break the gate'
    fi
    require_line 'the unscoped grant was not rejected by name' \
        'granted without a scope' \
        "$WORK/router.break-manifest-scope.log"

    # A build identity that no longer describes the record it was computed
    # from. A manifest whose build line is stale describes the previous
    # binary, which is worse than printing none: it is a wrong answer to the
    # question the manifest exists to answer.
    cp -R "$router_module" "$router_breaks/manifest-digest"
    sed -i 's/^    return 226362803$/    return 1/' \
        "$router_breaks/manifest-digest/core/router.kofun"
    if ROUTER_MODULE="$router_breaks/manifest-digest" \
        ROUTER_SKIP_BREAK_TEST=1 EFFECTS_SKIP_BREAK_TEST=1 sh "$0" \
        >"$WORK/router.break-manifest-digest.log" 2>&1
    then
        fail 'a stale capability digest did not break the gate'
    fi
    require_line 'the stale build identity was not named' \
        "the manifest's build identity is stale" \
        "$WORK/router.break-manifest-digest.log"

    printf 'boot: dropped row, unscoped grant, and stale build identity fail by name: PASS\n'
fi

# ------------------------------------------------------- the effect boundary
#
# ADR 6 moved canonical surfaces beside their bounded contexts.  The effect
# contract is therefore owned by modules/effects rather than duplicated under
# a global contracts/ directory.  It remains ahead of the compiler in its
# honest List/Bytes/multi-payload shape, while the core/shell projection below
# is executable in the Stage 2 slice.

effects_module=${EFFECTS_MODULE:-"$ROOT/modules/effects"}
effects_contract="$effects_module/contract/effects.kofun"
effects_trace_contract="$effects_module/contract/trace.kofun"
effects_core="$effects_module/core/effects.kofun"
effects_replay_core="$effects_module/core/trace.kofun"
effects_shell="$effects_module/shell/effects.kofun"
effects_expected="$effects_module/tests/effects.stdout"
effects_trace_expected="$effects_module/tests/effects.trace"
effects_trace_tool="$ROOT/scripts/effects-trace.sh"
test -f "$effects_contract" || fail 'effects canonical contract is missing'
test -f "$effects_trace_contract" || fail 'effects trace v1 contract is missing'
test -f "$effects_core" || fail 'effects core is missing'
test -f "$effects_replay_core" || fail 'effects replay core is missing'
test -f "$effects_shell" || fail 'effects shell is missing'
test -f "$effects_expected" || fail 'effects trace golden is missing'
test -f "$effects_trace_expected" || fail 'effects structured trace fixture is missing'
test -x "$effects_trace_tool" || fail 'effects record/replay tool is missing'

for declaration in \
    'type Cmd =' \
    'type Sub =' \
    'type Msg =' \
    'type Message = {' \
    'type Deadline = {' \
    'type CmdCapabilities = {' \
    'type SubCapabilities = {' \
    'fn boot_interpret(' \
    'fn boot_subscribe('
do
    require_line 'effects canonical surface lost a declaration' \
        "$declaration" "$effects_contract"
done

require_line 'command interpretation gained an undeclared capability bundle' \
    'capabilities: CmdCapabilities' "$effects_contract"
require_line 'subscription interpretation gained an undeclared capability bundle' \
    'capabilities: SubCapabilities' "$effects_contract"

sed -n '/^type CmdCapabilities = {$/,/^}$/p' "$effects_contract" \
    >"$WORK/effects.cmd-capabilities"
sed -n '/^type SubCapabilities = {$/,/^}$/p' "$effects_contract" \
    >"$WORK/effects.sub-capabilities"
for capability in \
    'clock: MonotonicClock' \
    'http: HttpClient' \
    'persistence: Persistence' \
    'custom: CustomEffectInterpreter'
do
    require_line 'CmdCapabilities lost a dependency its Cmd vocabulary uses' \
        "$capability" "$WORK/effects.cmd-capabilities"
done
for capability in \
    'clock: MonotonicClock' \
    'signals: SignalSource' \
    'custom: CustomEffectInterpreter'
do
    require_line 'SubCapabilities lost a dependency its Sub vocabulary uses' \
        "$capability" "$WORK/effects.sub-capabilities"
done
if grep -qE 'signals: SignalSource' "$WORK/effects.cmd-capabilities" ||
    grep -qE 'http: HttpClient|persistence: Persistence' \
        "$WORK/effects.sub-capabilities"
then
    fail 'an interpreter signature receives a capability its vocabulary cannot use'
fi
test "$(wc -l <"$WORK/effects.cmd-capabilities" | tr -d ' ')" -eq 6 ||
    fail 'CmdCapabilities contains an unnamed dependency'
test "$(wc -l <"$WORK/effects.sub-capabilities" | tr -d ' ')" -eq 5 ||
    fail 'SubCapabilities contains an unnamed dependency'

# Custom keeps both request families extensible. Check it before the generic
# continuation loop so removing one fails as an openness violation rather
# than as an incidental field mismatch.
require_line 'Cmd lost its Custom openness constructor' \
    '| Custom(tag: CmdTag, payload: Bytes, on_result: MsgId)' \
    "$effects_contract"
require_line 'Sub lost its Custom openness constructor' \
    '| Custom(tag: SubTag, payload: Bytes, on_event: MsgId)' \
    "$effects_contract"
custom_count=$(grep -Fc '    | Custom(' "$effects_contract")
test "$custom_count" -eq 2 ||
    fail "effects openness moved: expected Custom in Cmd and Sub, found $custom_count"

# Correlation is inside every effecting constructor, not an application
# convention. Keep these separate: a moved field must name its constructor.
require_line 'HttpRequest lost its on_result continuation' \
    '| HttpRequest(request: OutboundRequest, on_result: MsgId)' \
    "$effects_contract"
require_line 'ReadClock lost its on_result continuation' \
    '| ReadClock(on_result: MsgId)' "$effects_contract"
require_line 'Persist lost its on_result continuation' \
    '| Persist(entity: EntityId, bytes: Bytes, on_result: MsgId)' \
    "$effects_contract"
require_line 'Cmd.Custom lost its on_result continuation' \
    '| Custom(tag: CmdTag, payload: Bytes, on_result: MsgId)' \
    "$effects_contract"
require_line 'Every lost its on_tick continuation' \
    '| Every(interval_ms: Int, on_tick: MsgId)' "$effects_contract"
require_line 'OnSignal lost its on_signal continuation' \
    '| OnSignal(signal: SignalId, on_signal: MsgId)' "$effects_contract"
require_line 'Sub.Custom lost its on_event continuation' \
    '| Custom(tag: SubTag, payload: Bytes, on_event: MsgId)' \
    "$effects_contract"

if "$KOFUN" check "$effects_contract" \
    >"$WORK/effects.contract.stdout" 2>"$WORK/effects.contract.stderr"
then
    fail 'effects canonical surface unexpectedly claimed executable codegen'
fi
require_line 'effects canonical surface did not stop at the documented boundary' \
    'error[E2S02]: expected top-level `fn` or `type`' \
    "$WORK/effects.contract.stderr"

for declaration in \
    'type TraceVersion =' \
    'type ContractDigest = {' \
    'type TraceStep = {' \
    'type EffectTrace = {' \
    'type ReplayDivergence = {' \
    'type ReplayResult =' \
    'fn boot_record_effect_trace(' \
    'fn boot_replay_effect_trace('
do
    require_line 'effects trace v1 canonical surface lost a declaration' \
        "$declaration" "$effects_trace_contract"
done
require_line 'effects trace format version moved without a new version' \
    'kofun-boot.effects-trace/v1' "$effects_trace_contract"
if "$KOFUN" check "$effects_trace_contract" \
    >"$WORK/effects.trace-contract.stdout" \
    2>"$WORK/effects.trace-contract.stderr"
then
    fail 'effects trace canonical surface unexpectedly claimed executable codegen'
fi
require_line 'effects trace canonical surface did not stop at its documented boundary' \
    'error[E2S32]: record `ContractDigest` has a field type outside the Stage 2 Int/Bool slice' \
    "$WORK/effects.trace-contract.stderr"

# The executable projection carries the same extension and continuation
# properties. Pinning the rich contract alone would let the seed silently
# narrow it while the prose stayed correct.
for projection in \
    '| HttpRequest(on_result: Int)' \
    '| ReadClock(on_result: Int)' \
    '| Persist(on_result: Int)' \
    '| CustomCmd(on_result: Int)' \
    '| Every(on_tick: Int)' \
    '| OnSignal(on_signal: Int)' \
    '| CustomSub(on_event: Int)'
do
    require_line 'effects Stage 2 projection lost a contract property' \
        "$projection" "$effects_core"
done

effects_seed="$WORK/effects.unit.kofun"
: >"$effects_seed"
for source in "$effects_module"/core/*.kofun; do
    cat "$source" >>"$effects_seed"
    printf '\n' >>"$effects_seed"
done
cat "$effects_shell" >>"$effects_seed"
sed 's/[[:space:]]*#.*$//' "$effects_seed" >"$WORK/effects.code"
if grep -qE 'clock_gettime|gettimeofday|getenv|fopen|socket\(|__linux_syscall|import ' \
    "$WORK/effects.code"
then
    fail 'the effects seed names ambient state'
fi

"$KOFUN" check "$effects_seed" \
    >"$WORK/effects.check.stdout" 2>"$WORK/effects.check.stderr" ||
    fail "effects seed did not check: $(cat "$WORK/effects.check.stderr")"
"$KOFUN" build "$effects_seed" -o "$WORK/effects" \
    --emit-c "$WORK/effects.c" \
    >"$WORK/effects.build.stdout" 2>"$WORK/effects.build.stderr" ||
    fail "effects seed did not build: $(cat "$WORK/effects.build.stderr")"

"$WORK/effects" >"$WORK/effects.backend.stdout"
"$KOFUN" run "$effects_seed" \
    >"$WORK/effects.reference.stdout" 2>"$WORK/effects.run.stderr" ||
    fail "effects seed did not run on the reference executor: $(cat "$WORK/effects.run.stderr")"
cmp "$WORK/effects.backend.stdout" "$WORK/effects.reference.stdout" ||
    fail 'effects reference executor and C11 backend disagree'

"$WORK/effects" >"$WORK/effects.second.stdout"
cmp "$WORK/effects.backend.stdout" "$WORK/effects.second.stdout" ||
    fail 'two executions of the effects seed differ'
TZ=Pacific/Kiritimati LC_ALL=C LANG=C \
    "$WORK/effects" >"$WORK/effects.hostile.stdout"
cmp "$WORK/effects.backend.stdout" "$WORK/effects.hostile.stdout" ||
    fail 'effects output changed under hostile TZ or locale'
env -i "$WORK/effects" >"$WORK/effects.bare.stdout"
cmp "$WORK/effects.backend.stdout" "$WORK/effects.bare.stdout" ||
    fail 'effects output changed with an empty environment'
if grep -qE 'time\.h|clock_gettime|gettimeofday|localtime|getenv|fopen|socket' \
    "$WORK/effects.c"
then
    fail 'the emitted effects C reaches for ambient state'
fi

effect_field() {
    sed -n "$1,$2p" "$WORK/effects.backend.stdout" | tr '\n' ' '
}

assert_effect_field() {
    label=$1
    from=$2
    to=$3
    want=$4
    got=$(effect_field "$from" "$to")
    test "$got" = "$want" ||
        fail "$label: expected '$want', got '$got'"
}

# Six lines per step: Cmd/Sub source, effect kind, argument, continuation,
# message kind, observed answer. Every line is owned by one named assertion.
assert_effect_field 'an empty Cmd produces the named empty answer' \
    1 6 '1 0 0 0 0 0 '
assert_effect_field 'a Batch carries its deterministic command count' \
    7 12 '1 1 2 0 0 0 '
assert_effect_field 'an HTTP result carries its continuation' \
    13 18 '1 2 9001 41 1 200 '
assert_effect_field 'an HTTP timeout is a Msg carrying its continuation' \
    19 24 '1 2 9002 42 2 1000 '
assert_effect_field 'a subscription tick carries its continuation' \
    25 30 '2 1 5000 51 6 1700000000 '
assert_effect_field 'a clock answer separates continuation and observation' \
    31 36 '1 3 0 43 3 1700000001 '
assert_effect_field 'a persistence answer carries entity and continuation' \
    37 42 '1 4 7001 44 4 7001 '
assert_effect_field 'a custom command remains executable and correlated' \
    43 48 '1 5 8001 45 5 8001 '
assert_effect_field 'a signal subscription remains executable and correlated' \
    49 54 '2 2 9 52 7 9 '
assert_effect_field 'a custom subscription remains executable and correlated' \
    55 60 '2 3 8002 53 8 8002 '

effects_lines=$(wc -l <"$WORK/effects.backend.stdout" | tr -d ' ')
test "$effects_lines" -eq 60 ||
    fail "named effects decisions cover 60 lines, got $effects_lines"
cmp "$effects_expected" "$WORK/effects.backend.stdout" ||
    fail 'named decisions passed but the recorded Cmd/Msg trace still differs'

printf 'boot: Cmd/Sub continuations and total Msg answers are pinned: PASS\n'
printf 'boot: effects agree on both backends under hostile TZ, locale, env -i: PASS\n'

if test "${EFFECTS_SKIP_BREAK_TEST:-0}" != 1; then
    EFFECTS_TRACE_RUNNER=c11 sh "$effects_trace_tool" record \
        "$WORK/effects.trace.c11" >"$WORK/effects.trace-record-c11.log"
    EFFECTS_TRACE_RUNNER=c11 sh "$effects_trace_tool" record \
        "$WORK/effects.trace.second" >"$WORK/effects.trace-record-second.log"
    EFFECTS_TRACE_RUNNER=reference sh "$effects_trace_tool" record \
        "$WORK/effects.trace.reference" >"$WORK/effects.trace-record-reference.log"
    TZ=Pacific/Kiritimati LC_ALL=C LANG=C EFFECTS_TRACE_RUNNER=c11 \
        sh "$effects_trace_tool" record "$WORK/effects.trace.hostile" \
        >"$WORK/effects.trace-record-hostile.log"
    env -i PATH="$PATH" EFFECTS_TRACE_RUNNER=c11 \
        sh "$effects_trace_tool" record "$WORK/effects.trace.bare" \
        >"$WORK/effects.trace-record-bare.log"
    for recorded in \
        "$WORK/effects.trace.second" \
        "$WORK/effects.trace.reference" \
        "$WORK/effects.trace.hostile" \
        "$WORK/effects.trace.bare"
    do
        cmp "$WORK/effects.trace.c11" "$recorded" ||
            fail "structured effect trace changed across a replay environment: $recorded"
    done
    cmp "$effects_trace_expected" "$WORK/effects.trace.c11" ||
        fail 'committed effect trace v1 no longer matches record mode'
    sh "$effects_trace_tool" replay "$effects_trace_expected" \
        >"$WORK/effects.trace-replay.log" 2>&1 ||
        fail "effect trace replay failed: $(cat "$WORK/effects.trace-replay.log")"
    require_line 'effect trace replay did not name both backends' \
        'replayed byte-identically on reference and C11' \
        "$WORK/effects.trace-replay.log"

    sed 's/^# contract-sha256: .*/# contract-sha256: 0000000000000000000000000000000000000000000000000000000000000000/' \
        "$effects_trace_expected" >"$WORK/effects.trace-wrong-contract"
    if sh "$effects_trace_tool" replay "$WORK/effects.trace-wrong-contract" \
        >"$WORK/effects.trace-wrong-contract.log" 2>&1
    then
        fail 'a trace recorded against another effect contract was accepted'
    fi
    require_line 'contract mismatch was not refused by name' \
        'contract digest mismatch:' "$WORK/effects.trace-wrong-contract.log"

    sed 's/^3[[:space:]]\+1[[:space:]]\+2[[:space:]]\+9001[[:space:]]\+41[[:space:]]\+1[[:space:]]\+200$/3\t1\t2\t9001\t41\t2\t200/' \
        "$effects_trace_expected" >"$WORK/effects.trace-corrupt-msg"
    if sh "$effects_trace_tool" replay "$WORK/effects.trace-corrupt-msg" \
        >"$WORK/effects.trace-corrupt-msg.log" 2>&1
    then
        fail 'a corrupted recorded Msg replayed successfully'
    fi
    for diagnostic in \
        'replay diverged at step 4' \
        'fed Msg:' \
        'expected Cmd:' \
        'emitted Cmd:'
    do
        require_line 'corrupted Msg divergence lost a required field' \
            "$diagnostic" "$WORK/effects.trace-corrupt-msg.log"
    done
    printf 'boot: effect trace v1 records and replays; digest and Msg breaks fail by name: PASS\n'
fi

# Do not merely say these checks are structural: break each property in an
# isolated module copy and require this same gate to reject it by name. The
# recursive runs skip this block, so a mutation can never pass by recursing.
if test "${EFFECTS_SKIP_BREAK_TEST:-0}" != 1; then
    effects_breaks="$WORK/effects-breaks"
    mkdir -p "$effects_breaks"

    cp -R "$effects_module" "$effects_breaks/continuation"
    sed -i \
        's/HttpRequest(request: OutboundRequest, on_result: MsgId)/HttpRequest(request: OutboundRequest)/' \
        "$effects_breaks/continuation/contract/effects.kofun"
    if EFFECTS_MODULE="$effects_breaks/continuation" \
        EFFECTS_SKIP_BREAK_TEST=1 ROUTER_SKIP_BREAK_TEST=1 sh "$0" \
        >"$WORK/effects.break-continuation.log" 2>&1
    then
        fail 'dropping an effect continuation did not break the gate'
    fi
    require_line 'the continuation break was not rejected by name' \
        'HttpRequest lost its on_result continuation' \
        "$WORK/effects.break-continuation.log"

    cp -R "$effects_module" "$effects_breaks/openness"
    sed -i '/CmdTag, payload: Bytes, on_result: MsgId/d' \
        "$effects_breaks/openness/contract/effects.kofun"
    if EFFECTS_MODULE="$effects_breaks/openness" \
        EFFECTS_SKIP_BREAK_TEST=1 ROUTER_SKIP_BREAK_TEST=1 sh "$0" \
        >"$WORK/effects.break-openness.log" 2>&1
    then
        fail 'removing Cmd.Custom did not break the gate'
    fi
    require_line 'the openness break was not rejected by name' \
        'Cmd lost its Custom openness constructor' \
        "$WORK/effects.break-openness.log"

    cp -R "$effects_module" "$effects_breaks/timeout"
    sed -i \
        's/return step_cmd(command, request_code, HttpTimedOut(deadline_ms))/let timeout: Msg = NoMessage\
        return step_cmd(command, request_code, timeout)/' \
        "$effects_breaks/timeout/core/effects.kofun"
    if EFFECTS_MODULE="$effects_breaks/timeout" \
        EFFECTS_SKIP_BREAK_TEST=1 ROUTER_SKIP_BREAK_TEST=1 sh "$0" \
        >"$WORK/effects.break-timeout.log" 2>&1
    then
        fail 'making timeout produce no Msg did not break the gate'
    fi
    require_line 'the timeout totality break was not rejected by name' \
        'an HTTP timeout is a Msg carrying its continuation' \
        "$WORK/effects.break-timeout.log"

    printf 'boot: continuation, openness, and timeout-totality break tests fail by name: PASS\n'
fi

# The mock resource's core lives under the same rule: it may receive a store
# and an operation, and may not construct a capability or own an entry point.
# A second core added without a second check is a boundary that exists for one
# directory.
mock_contract="$ROOT/modules/mock/contract/mock.kofun"
mock_core="$ROOT/modules/mock/core/mock.kofun"
test -f "$mock_contract" || fail 'mock canonical contract is missing'
test -f "$mock_core" || fail 'mock core is missing'

# Business refusal is a value.  Pin the complete outcome block between the
# rich canonical contract and its bounded Stage 2 seed so neither can add a
# default, drop an observed value, or silently rename a rule.
sed -n '/^type MockOutcome =$/,/^$/p' "$mock_contract" >"$WORK/mock.contract.outcome"
sed -n '/^type MockOutcome =$/,/^$/p' "$mock_core" >"$WORK/mock.seed.outcome"
cmp "$WORK/mock.contract.outcome" "$WORK/mock.seed.outcome" ||
    fail "mock business outcomes differ between canonical contract and seed:
$(diff "$WORK/mock.contract.outcome" "$WORK/mock.seed.outcome")"
for observed in \
    'Collection(live: Int)' \
    'Item(value: Int)' \
    'Created(id: Int)' \
    'Updated(id: Int)' \
    'Deleted(id: Int)' \
    'Missing(id: Int)' \
    'Full(capacity: Int)'
do
    require_line 'mock canonical outcome lost its observed value' \
        "$observed" "$mock_contract"
done
sed 's/[[:space:]]*#.*$//' "$mock_core" >"$WORK/mock.code"
if grep -qE 'Capabilities\(' "$WORK/mock.code"; then
    printf '%s\n' \
        'boot: FAIL: the mock core constructs a capability instead of receiving one:' >&2
    grep -nE 'Capabilities\(' "$WORK/mock.code" >&2
    exit 1
fi
if grep -qE '^fn main' "$WORK/mock.code"; then
    fail 'the mock core owns an entry point; emission belongs to the shell'
fi
mock_shell="$ROOT/modules/mock/shell/mock.kofun"
test -f "$mock_shell" || fail 'the mock shell is missing'
grep -qE '^fn main' "$mock_shell" ||
    fail 'the mock shell no longer owns the entry point; the boundary has moved without being moved'
if grep -qE 'clock_gettime|gettimeofday|getenv|fopen|socket\(|__linux_syscall|import ' \
    "$WORK/mock.code"
then
    fail 'the mock core names ambient state'
fi

printf 'boot: the core cannot construct a capability, and does not own main: PASS\n'
printf 'boot: mock business rules are a closed sum and every refusal carries what was observed: PASS\n'
# ------------------------------------------------- the OpenAPI projection
#
# The document is generated from the twelve lines the router printed, so it
# cannot describe a route the dispatcher does not serve. Two things are
# checked: the recorded document still matches what the table projects, and
# every route in the table reaches the document — the second catches a route
# added to the table whose path has no name, which would otherwise appear as a
# number or vanish.

recorded="$ROOT/contracts/openapi.yaml"
test -f "$recorded" || fail 'the recorded OpenAPI document is missing'

sh "$ROOT/scripts/openapi.sh" "$WORK/router" >"$WORK/openapi.yaml" ||
    fail 'the OpenAPI projection failed'
cmp "$recorded" "$WORK/openapi.yaml" ||
    fail "the recorded OpenAPI document no longer matches the table the router runs:
$(diff "$recorded" "$WORK/openapi.yaml" | head -12)"

# Every distinct path in the table appears exactly once as a path object, and
# every row appears as a method under it. Counting rather than eyeballing: a
# projection that silently dropped a route would still cmp clean against a
# golden regenerated from the same bug.
table_paths=$(sed -n '1,20p' "$WORK/body" | paste - - - - | awk '{print $2}' | sort -u | wc -l)
document_paths=$(grep -cE '^  /' "$recorded")
test "$table_paths" -eq "$document_paths" ||
    fail "the table has $table_paths paths and the document has $document_paths"

table_rows=$(sed -n '1,20p' "$WORK/body" | paste - - - - | wc -l)
document_ops=$(grep -cE '^      operationId:' "$recorded")
test "$table_rows" -eq "$document_ops" ||
    fail "the table has $table_rows routes and the document has $document_ops operations"

printf 'boot: the OpenAPI document is a projection of the table the router ran: PASS\n'

# ------------------------------------------------------- the session trace
#
# The replay lane's whole claim: a recorded session runs again and produces
# the same bytes. It is only meaningful because nothing in the core can reach
# a clock, an id source, or a file — so if this ever diverges, something
# ambient got in, and the divergence is the alarm rather than the noise.

trace="$ROOT/contracts/session.trace"
test -f "$trace" || fail 'the recorded session trace is missing'
sh "$ROOT/scripts/trace.sh" replay "$trace" >"$WORK/replay.log" 2>&1 ||
    fail "the recorded session did not replay:
$(sed 's/^/    /' "$WORK/replay.log")"

# A create after a delete must not reuse the freed id: two resources sharing
# an id are indistinguishable in a replay, which would make every trace above
# worth less than it looks. Read from the trace rather than trusted.
freed=$(grep -v '^#' "$trace" | awk -F'\t' '$5 == 5 { print $6 }' | head -1)
allocated=$(grep -v '^#' "$trace" | awk -F'\t' '$2 == 3 { print $6 }' | tail -1)
test -n "$freed" && test -n "$allocated" ||
    fail 'the trace no longer contains both a delete and a later create'
test "$freed" != "$allocated" ||
    fail "a create reused the id a delete freed ($freed); ids must be spent"

printf 'boot: a recorded session replays byte-identically, and freed ids stay spent: PASS\n'

# ------------------------------------------------ the TypeScript client
#
# Same projection path, and one claim the document cannot make: a wrong path
# or a wrong method must be a compile error at the call site. Both directions
# are checked, because a client that rejected everything would also make the
# negative fixtures fail and would be worthless.

recorded_client="$ROOT/contracts/client.ts"
test -f "$recorded_client" || fail 'the generated client is missing'

sh "$ROOT/scripts/client-ts.sh" "$WORK/router" >"$WORK/client.ts" ||
    fail 'the client projection failed'
cmp "$recorded_client" "$WORK/client.ts" ||
    fail "the generated client no longer matches the table the router runs:
$(diff "$recorded_client" "$WORK/client.ts" | head -12)"

# Both member shapes count: a literal route is a quoted string, a capturing
# route is a template literal in backticks. Counting only the quoted ones
# would let a capturing route vanish from the client while the totals still
# looked right.
client_paths=$(grep -cE '^  \| ("/|`/)' "$recorded_client")
table_rows=$(sed -n '1,20p' "$WORK/body" | paste - - - - | wc -l)
test "$client_paths" -eq "$table_rows" ||
    fail "the table has $table_rows routes and the client exposes $client_paths"

if command -v tsc >/dev/null 2>&1; then
    mkdir -p "$WORK/ts"
    cp "$recorded_client" "$WORK/ts/client.ts"
    cp "$ROOT/tests/client/"*.ts "$WORK/ts/"
    TSC_FLAGS='--noEmit --strict --target es2022 --lib es2022,dom --moduleResolution bundler --module esnext'

    # shellcheck disable=SC2086
    (cd "$WORK/ts" && tsc $TSC_FLAGS accepts.ts) >"$WORK/tsc.accept" 2>&1 ||
        fail "a call the table allows did not type-check:
$(sed 's/^/    /' "$WORK/tsc.accept")"

    for fixture in rejects-wrong-method rejects-unknown-path \
        rejects-capture-template
    do
        # shellcheck disable=SC2086
        if (cd "$WORK/ts" && tsc $TSC_FLAGS "$fixture.ts") \
            >"$WORK/tsc.$fixture" 2>&1
        then
            fail "$fixture.ts type-checked; the client accepts a call the table refuses"
        fi
        grep -q 'is not assignable to parameter of type' "$WORK/tsc.$fixture" ||
            fail "$fixture.ts failed for the wrong reason:
$(sed 's/^/    /' "$WORK/tsc.$fixture")"
    done
    printf 'boot: a wrong path or method is a compile error at the call site: PASS\n'
else
    printf 'boot: SKIP client type-check (tsc unavailable); projection still gated\n'
fi

printf 'boot: canonical contract pinned at its boundary: PASS\n'
printf 'boot: fixed-rank dispatch, every closed outcome read by name: PASS\n'
printf 'boot: handlers are pure and time is an injected capability: PASS\n'
printf 'boot: reference and C11 agree; bytes hold under hostile TZ, locale, env -i: PASS\n'
