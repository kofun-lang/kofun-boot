#!/bin/sh
set -eu

# One data-driven architecture gate for every bounded context.
#
# A module owns contract/core/shell/tests.  Another module may name only its
# public contract; reaching into core, shell, or tests is a boundary violation.
# The gate reports the actual source path, line, and target instead of keeping
# a second list of prose rule names that can drift from its assertions.
#
# usage: scripts/check-modules.sh [MODULES_ROOT]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODULES_ROOT=${1:-"$ROOT/modules"}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-architecture.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'architecture: FAIL: %s\n' "$*" >&2
    exit 1
}

test -d "$MODULES_ROOT" || fail "modules root is missing: $MODULES_ROOT"

modules=''
count=0
for module_dir in "$MODULES_ROOT"/*; do
    test -d "$module_dir" || continue
    module=$(basename -- "$module_dir")
    case $module in
        [a-z]* ) ;;
        * ) fail "$module: module names must start with a lowercase letter" ;;
    esac
    case $module in
        *[!a-z0-9_-]* ) fail "$module: module names may contain lowercase letters, digits, _ and -" ;;
    esac

    for layer in contract core shell tests; do
        test -d "$module_dir/$layer" ||
            fail "$module: missing owned layer modules/$module/$layer"
    done
    for layer in contract core shell; do
        set -- "$module_dir/$layer"/*.kofun
        test -f "$1" || fail "$module: modules/$module/$layer has no .kofun source"
    done
    set -- "$module_dir/tests"/*_test.kofun
    test -f "$1" || fail "$module: modules/$module/tests has no *_test.kofun suite"

    modules="$modules $module"
    count=$((count + 1))
done
test "$count" -ge 2 || fail "expected at least two modules, found $count"

# FCIS is a module rule, not a router exception.  Read code with comments
# stripped so the explanatory prose does not look like a violation.
for module in $modules; do
    core_dir="$MODULES_ROOT/$module/core"
    shell_dir="$MODULES_ROOT/$module/shell"
    for source in "$core_dir"/*.kofun; do
        code="$WORK/$module.$(basename -- "$source").code"
        sed 's/[[:space:]]*#.*$//' "$source" >"$code"
        if grep -nE 'Capabilities\(' "$code" >"$WORK/hit"; then
            hit=$(head -1 "$WORK/hit")
            fail "$source:${hit%%:*}: core constructs a capability: ${hit#*:}"
        fi
        # A Principal is what the authentication adapter concluded about a
        # credential it verified with a capability. A core that could build
        # one could admit any caller it liked, so it may only receive one.
        if grep -nE 'Principal\(' "$code" >"$WORK/hit"; then
            hit=$(head -1 "$WORK/hit")
            fail "$source:${hit%%:*}: core constructs a principal; only the shell's authentication adapter may: ${hit#*:}"
        fi
        if grep -nE '^fn main' "$code" >"$WORK/hit"; then
            hit=$(head -1 "$WORK/hit")
            fail "$source:${hit%%:*}: core owns main; entry points belong to shell"
        fi
        if grep -nE 'clock_gettime|gettimeofday|getenv|fopen|socket\(|__linux_syscall' \
            "$code" >"$WORK/hit"
        then
            hit=$(head -1 "$WORK/hit")
            fail "$source:${hit%%:*}: core names ambient authority: ${hit#*:}"
        fi
    done
    grep -qE '^fn main' "$shell_dir"/*.kofun ||
        fail "$module: shell has no entry point"
done

# Accepted spellings cover the current contract path convention and the
# future dotted import surface.  Any reference to another module must start
# with contract; everything else prints the precise line that crossed over.
for module in $modules; do
    for source in $(find "$MODULES_ROOT/$module" -type f -name '*.kofun' | LC_ALL=C sort); do
        code="$WORK/ref.$module.$(basename -- "$source").code"
        sed 's/[[:space:]]*#.*$//' "$source" >"$code"
        for other in $modules; do
            test "$other" = "$module" && continue
            awk -v slash="modules/$other/" -v dot="modules.$other." \
                -v relative="../../$other/" \
                -v source="$source" -v module="$module" -v other="$other" '
                {
                    rest = $0
                    while ((at = index(rest, slash)) > 0) {
                        tail = substr(rest, at + length(slash))
                        if (tail !~ /^contract([\/.]|$)/) {
                            printf "%s:%d: module %s may name only modules/%s/contract; saw: %s\n", source, NR, module, other, $0
                            bad = 1
                        }
                        rest = substr(tail, 2)
                    }
                    rest = $0
                    while ((at = index(rest, dot)) > 0) {
                        tail = substr(rest, at + length(dot))
                        if (tail !~ /^contract([\/.]|$)/) {
                            printf "%s:%d: module %s may name only modules.%s.contract; saw: %s\n", source, NR, module, other, $0
                            bad = 1
                        }
                        rest = substr(tail, 2)
                    }
                    rest = $0
                    while ((at = index(rest, relative)) > 0) {
                        tail = substr(rest, at + length(relative))
                        if (tail !~ /^contract([\/.]|$)/) {
                            printf "%s:%d: module %s may name only ../../%s/contract; saw: %s\n", source, NR, module, other, $0
                            bad = 1
                        }
                        rest = substr(tail, 2)
                    }
                }
                END { exit bad ? 1 : 0 }
            ' "$code" >"$WORK/cross" || {
                cat "$WORK/cross" >&2
                exit 1
            }
        done
    done
done

printf 'architecture: %s modules own contract/core/shell/tests: PASS\n' "$count"
printf 'architecture: another module may name only the public contract: PASS\n'
