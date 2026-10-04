#!/bin/sh
set -eu

# The declared caches, as manifest rows an operator reads.
#
#   scripts/cache-manifest.sh [BUILT_CACHE]
#
# Reads the `caches`, `writes`, and `check` sections the cache binary
# printed, and prints one row per cache and one per write:
#
#   cache.mine  key (id, caller)  lifetime 30s  tags thing(id)  http private, max-age=30
#   write.give  invalidates thing(id)
#
# contracts/caches.txt is this output, committed, and tests/cache/check.sh
# refuses a copy that is not the projection.
#
# The http column is the only HTTP this projects: the declared lifetime,
# with two rules that follow from the key and the lifetime.
#
#   A key that holds the caller is `private`. The answer differs per caller,
#   and a shared cache that stored it would serve it to the next one.
#   A cache that never expires is `no-cache`. It is fresh on the server
#   because writes drop it; nothing drops a copy a client already holds.
#
# Codes become names here and only here (ADR 4). A code with no name, and a
# cache the build-time check refused, fail by name before any row prints.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
    printf 'cache-manifest: %s\n' "$*" >&2
    exit 1
}

binary=${1:-}
if test -z "$binary"; then
    binary=$(SEED=cache sh "$ROOT/scripts/build-seed.sh" "$ROOT/build/cache")
fi
test -x "$binary" || fail "no built cache binary at $binary"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-cache-manifest.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

env -i "$binary" >"$WORK/out" || fail 'the cache binary exited non-zero'
test "$(sed -n 1p "$WORK/out")" = 'kofun-boot cache' ||
    fail 'the binary did not print a cache report'

section() {
    grep -qx "$1" "$WORK/out" || fail "the cache report has no '$1' section"
    grep -qx "end $1" "$WORK/out" || fail "the '$1' section is never closed"
    sed -n "/^$1\$/,/^end $1\$/p" "$WORK/out" | sed '1d;$d'
}

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

# An argument mask, as the parameter list it stands for.
key_names() {
    test "$1" -ge 0 -a "$1" -le 3 || return 1
    names=''
    if test $(($1 % 2)) = 1; then
        names='id'
    fi
    if test $(($1 / 2 % 2)) = 1; then
        names=${names:+"$names, "}caller
    fi
    printf '(%s)' "$names"
}

tag_names() {
    test "$1" -ge 0 -a "$1" -le 3 || return 1
    names=''
    if test $(($1 % 2)) = 1; then
        names='things'
    fi
    if test $(($1 / 2 % 2)) = 1; then
        names=${names:+"$names "}'thing(id)'
    fi
    printf '%s' "${names:--}"
}

check_name() {
    case $1 in
        2) printf 'its key omits argument %s' "$(key_names "$2" | tr -d '()')" ;;
        3) printf 'its key names argument %s, which its handler does not take' "$(key_names "$2" | tr -d '()')" ;;
        4) printf 'tag %s has no invalidating write and the cache never expires' "$(tag_names "$2")" ;;
        5) printf 'it never expires and carries no tag, so nothing can refresh it' ;;
        *) return 1 ;;
    esac
}

section caches | sed 1d | paste - - - - - >"$WORK/caches"
section writes | sed 1d | paste - - >"$WORK/writes"
section check | sed 1d | paste - - - >"$WORK/check"
test -s "$WORK/caches" || fail 'the binary declares no caches'

while IFS='	' read -r read kind payload; do
    name=$(op_name "$read") || fail "read code $read has no name"
    test "$kind" = 1 && continue
    reason=$(check_name "$kind" "$payload") || fail "check outcome $kind has no name"
    fail "cache.$name is refused by the build-time check: $reason"
done <"$WORK/check"

printf '# kofun-boot declared caches, projected by scripts/cache-manifest.sh from\n'
printf '# the caches and writes the cache binary printed. Regenerate; do not edit.\n'
while IFS='	' read -r read args key lifetime tags; do
    name=$(op_name "$read") || fail "read code $read has no name"
    keys=$(key_names "$key") || fail "cache.$name has key mask $key, which names no argument set"
    tagged=$(tag_names "$tags") || fail "cache.$name has tag mask $tags, which names no tag set"
    scope=public
    if test $((key / 2 % 2)) = 1; then
        scope=private
    fi
    if test "$lifetime" = 0; then
        life=forever
        http="$scope, no-cache"
    else
        life="${lifetime}s"
        http="$scope, max-age=$lifetime"
    fi
    printf '%-11s key %-15s lifetime %-8s tags %-15s http %s\n' \
        "cache.$name" "$keys" "$life" "$tagged" "$http"
done <"$WORK/caches"
while IFS='	' read -r write invalidates; do
    name=$(op_name "$write") || fail "write code $write has no name"
    tagged=$(tag_names "$invalidates") || fail "write.$name has tag mask $invalidates, which names no tag set"
    printf '%-11s invalidates %s\n' "write.$name" "$tagged"
done <"$WORK/writes"
