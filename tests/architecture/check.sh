#!/bin/sh
set -eu

# Verify the architecture gate in both directions.  The fixture adds a third
# module without editing router or mock, proves a public-contract reference is
# allowed, then reaches into router/core and requires the gate to name the
# offending source and target.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-architecture-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'architecture-test: FAIL: %s\n' "$*" >&2
    exit 1
}

sh "$ROOT/scripts/check-modules.sh" >"$WORK/current.log" 2>&1 ||
    fail "current modules failed the gate:
$(sed 's/^/    /' "$WORK/current.log")"

cp -R "$ROOT/modules" "$WORK/modules"
mkdir -p "$WORK/modules/orders/contract" "$WORK/modules/orders/core" \
    "$WORK/modules/orders/shell" "$WORK/modules/orders/tests"
printf '%s\n' \
    '# Public dependency: allowed.' \
    'import modules.router.contract.router' \
    'type OrderPlaced = | Placed(id: Int)' \
    >"$WORK/modules/orders/contract/orders.kofun"
printf '%s\n' \
    'fn decide_order(id: Int) -> Int {' \
    '    return id' \
    '}' \
    >"$WORK/modules/orders/core/orders.kofun"
printf '%s\n' \
    'fn main() -> Int {' \
    '    print(decide_order(1))' \
    '    return 0' \
    '}' \
    >"$WORK/modules/orders/shell/orders.kofun"
printf '%s\n' \
    'fn test_order_is_observed() -> Int {' \
    '    return expect_eq_int(decide_order(1), 1)' \
    '}' \
    >"$WORK/modules/orders/tests/orders_test.kofun"

sh "$ROOT/scripts/check-modules.sh" "$WORK/modules" \
    >"$WORK/added.log" 2>&1 ||
    fail "a third module required edits to existing modules:
$(sed 's/^/    /' "$WORK/added.log")"

printf '%s\n' 'import ../../router/core/router' \
    >>"$WORK/modules/orders/core/orders.kofun"
if sh "$ROOT/scripts/check-modules.sh" "$WORK/modules" \
    >"$WORK/broken.log" 2>&1
then
    fail 'the gate accepted a module reaching into router/core'
fi
grep -Fq 'modules/orders/core/orders.kofun:4:' "$WORK/broken.log" ||
    fail "the gate did not name the offending source and line:
$(sed 's/^/    /' "$WORK/broken.log")"
grep -Fq '../../router/contract' "$WORK/broken.log" ||
    fail "the gate did not name the only allowed target:
$(sed 's/^/    /' "$WORK/broken.log")"

# A core that forges a caller is refused, by its line, before anything else
# about it is read.
cp -R "$ROOT/modules" "$WORK/forged"
printf '%s\n' \
    'fn forge_caller() -> Int {' \
    '    let caller: Principal = Principal(subject: 9, role: 2)' \
    '    return caller.role' \
    '}' \
    >>"$WORK/forged/router/core/router.kofun"
if sh "$ROOT/scripts/check-modules.sh" "$WORK/forged" >"$WORK/forged.log" 2>&1; then
    fail 'the gate accepted a core that constructs a Principal'
fi
grep -Fq 'core constructs a principal' "$WORK/forged.log" ||
    fail "the gate did not name the forged principal:
$(sed 's/^/    /' "$WORK/forged.log")"
grep -Fq 'forged/router/core/router.kofun:' "$WORK/forged.log" ||
    fail "the gate did not name the source and line of the forged principal:
$(sed 's/^/    /' "$WORK/forged.log")"

printf 'architecture-test: a module is added without editing existing modules: PASS\n'
printf 'architecture-test: a core that constructs a Principal is refused by source and line: PASS\n'
printf 'architecture-test: an internal cross-module reference names source, line, and allowed target: PASS\n'
