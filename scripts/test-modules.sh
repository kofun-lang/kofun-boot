#!/bin/sh
set -eu

# Assemble and test every module-owned core/test pair.
#
# kotest's native companion convention expects X.kofun and X_test.kofun in
# one directory.  A bounded context deliberately owns separate core/ and
# tests/ directories, so this adapter concatenates them into a temporary
# suite.  No generated test unit enters the worktree.
#
# Each tests/*_test.kofun file is its own suite: the module's core, then the
# module's support files (tests/*.kofun that are not suites, holding helpers
# several suites share), then that one test file.  kotest's generated harness
# is a single `main`, and the language bounds lexical uses per function, so a
# suite holds a few dozen tests; splitting by file is how a module grows past
# that without renaming its core.  Suite names must be unique across modules,
# because kotest labels every test by its suite.
#
# usage: scripts/test-modules.sh [--watch] [kotest options]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODULES_ROOT=${MODULES_ROOT:-"$ROOT/modules"}
KOTEST="$ROOT/vendor/kofun/tooling/kotest/run.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-modules.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'modules-test: FAIL: %s\n' "$*" >&2
    exit 2
}

test -d "$MODULES_ROOT" || fail "no modules directory at $MODULES_ROOT"
test -f "$KOTEST" || fail 'vendor/kofun kotest runner is missing'

watch=false
if test "${1:-}" = --watch; then
    watch=true
    shift
fi

assemble() {
    suites=''
    found=0
    rm -f "$WORK"/*_test.kofun
    for module_dir in "$MODULES_ROOT"/*; do
        test -d "$module_dir" || continue
        module=$(basename -- "$module_dir")

        set -- "$module_dir"/core/*.kofun
        test -f "$1" || fail "$module has no core/*.kofun"

        tests=0
        for test_file in "$module_dir"/tests/*_test.kofun; do
            test -f "$test_file" || continue
            suite="$WORK/$(basename -- "$test_file")"
            test ! -e "$suite" ||
                fail "two modules own a suite named $(basename -- "$test_file"); suite names must be unique"
            : >"$suite"
            for source in "$module_dir"/core/*.kofun; do
                cat "$source" >>"$suite"
                printf '\n' >>"$suite"
            done
            for source in "$module_dir"/tests/*.kofun; do
                case $source in
                    *_test.kofun) continue ;;
                esac
                test -f "$source" || continue
                cat "$source" >>"$suite"
                printf '\n' >>"$suite"
            done
            cat "$test_file" >>"$suite"
            printf '\n' >>"$suite"
            suites="$suites $suite"
            tests=$((tests + 1))
        done
        test "$tests" -gt 0 || fail "$module has no tests/*_test.kofun"

        found=$((found + 1))
    done
    test "$found" -gt 0 || fail 'no modules found'
}

snapshot() {
    find "$MODULES_ROOT" -type f -name '*.kofun' -exec cksum {} \; |
        LC_ALL=C sort | cksum
}

run_once() {
    assemble
    # Module names and the temporary root are whitespace-free by gate, so the
    # intentional split expands one suite path per module.
    # shellcheck disable=SC2086
    sh "$KOTEST" $suites "$@"
}

run_once "$@"
$watch || exit 0

printf 'modules-test: watching modules/ — save to re-run\n'
before=$(snapshot)
while :; do
    sleep 1
    after=$(snapshot)
    test "$after" = "$before" && continue
    before=$after
    run_once "$@" || true
done
