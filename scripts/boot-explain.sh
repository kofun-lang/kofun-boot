#!/bin/sh
set -eu

# boot explain — where every resolved value came from.
#
#   scripts/boot-explain.sh [--scenario N] [BUILT_CONFIG]
#
# Reads the record the config binary resolved and prints one line per field:
# its value, its source, and the reason, which is the pack that set it or the
# boot.conf line that overrode it. Defaults are printed like everything else;
# a default absent from this output would be a default nobody can see.
#
#   http.port        9090       override  boot.conf:8
#
# contracts/boot.explain is this output, committed. With --scenario N it
# prints the field lines for one of the binary's probe inputs instead, which
# the gate uses to show that one override changes exactly one line.
#
# A configuration the core refused has no record. This prints the refusal,
# naming the field and both packs of a conflict, and exits 1.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/boot-names.sh"

fail() {
    printf 'boot explain: %s\n' "$*" >&2
    exit 1
}

scenario=''
if test "${1:-}" = --scenario; then
    scenario=${2:-}
    case $scenario in
        ''|*[!0-9]*) fail '--scenario needs a number' ;;
    esac
    shift 2
fi

binary=${1:-}
if test -z "$binary"; then
    binary=$(SEED=config sh "$ROOT/scripts/build-seed.sh" "$ROOT/build/config")
fi
test -x "$binary" || fail "no built config binary at $binary"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-explain.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

status=0
env -i "$binary" >"$WORK/out" || status=$?
test "$(sed -n 1p "$WORK/out")" = 'kofun-boot config' ||
    fail 'the binary did not print a config report'

section() {
    grep -qx "$1" "$WORK/out" || fail "the config report has no '$1' section"
    grep -qx "end $1" "$WORK/out" || fail "the '$1' section is never closed"
    sed -n "/^$1\$/,/^end $1\$/p" "$WORK/out" | sed '1d;$d'
}

refusal() {
    kind=$1
    payload=$2
    named=$3
    case $kind in
        2) printf 'pack mask %s names a pack that does not exist' "$payload" ;;
        3) printf 'the base pack %s is not selected, so some fields would have no value' "$(boot_pack_name "$payload")" ;;
        4)
            set -- $(boot_pack_list "$named")
            printf '%s is set by both %s and %s, to different values; select one' \
                "$(boot_field_name "$payload")" "$1" "${2:-?}"
            ;;
        5) printf 'override key %s names no field' "$payload" ;;
        6) printf '%s is overridden more than once' "$(boot_field_name "$payload")" ;;
        7) printf '%s is overridden with a value it cannot hold' "$(boot_field_name "$payload")" ;;
        *) return 1 ;;
    esac
}

if grep -qx refused "$WORK/out"; then
    section refused | paste - - - >"$WORK/refused"
    IFS='	' read -r kind payload named <"$WORK/refused"
    reason=$(refusal "$kind" "$payload" "$named") || fail "refusal kind $kind has no name"
    fail "refused: $reason"
fi
test "$status" = 0 || fail "the config binary exited $status without a refusal"

# Seven lines: packs, then each field.
explain() {
    record=$1
    packs=$(sed -n 1p "$record")
    names=$(boot_pack_list "$packs") || fail "pack mask $packs names a pack that does not exist"
    printf '%-16s %s\n' packs "$names"
    sed 1d "$record" | paste - - - >"$WORK/fields"
    field=0
    while IFS='	' read -r value source reason; do
        field=$((field + 1))
        name=$(boot_field_name "$field") || fail "field $field has no name"
        shown=$(boot_value_name "$field" "$value") || fail "$name holds $value, which has no name"
        from=$(boot_source_name "$source") || fail "$name has source $source, which has no name"
        case $source in
            3) why="boot.conf:$reason" ;;
            *) why=$(boot_pack_name "$reason") || fail "$name names pack $reason, which does not exist" ;;
        esac
        printf '%-16s %-10s %-9s %s\n' "$name" "$shown" "$from" "$why"
    done <"$WORK/fields"
}

if test -n "$scenario"; then
    section explains | sed 1d >"$WORK/explains"
    awk -v want="$scenario" '
        (NR - 1) % 17 == 0 { take = ($0 == want) ; next }
        take { print }
    ' "$WORK/explains" >"$WORK/record"
    test -s "$WORK/record" || fail "scenario $scenario has no resolved record"
    explain "$WORK/record"
    exit 0
fi

section resolved >"$WORK/record"
printf '# kofun-boot resolved configuration, projected by scripts/boot-explain.sh\n'
printf '# from the record the config binary printed. Regenerate; do not edit.\n'
explain "$WORK/record"
