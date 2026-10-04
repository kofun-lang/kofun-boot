#!/bin/sh
set -eu

# boot db plan — the next migrations, as source to append.
#
#   scripts/db-plan.sh [BUILT_SCHEMA]
#
# Reads the `plan` section the schema binary printed: what the planner
# proposes to get each key of each table from the replayed history to the
# declaration. It prints those steps as Kofun source for the next entries of
# history_step() in modules/schema/core/schema.kofun.
#
# drizzle-kit generate asks whether a column was renamed or created, and
# `prisma migrate dev` prompts before data loss. This asks nothing. The key
# already says rename or add, and the planner never supplies a policy. A
# planned step that apply would refuse until a person writes a policy is
# printed with a comment naming the policy apply will ask for, never with
# the policy filled in.
#
# The planner proposes one step per key per pass, so a key that needs a
# rename and a tightening gets the rename now and the tightening on the next
# run. When the history already replays to the declaration, this says so and
# prints no source.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
    printf 'db-plan: %s\n' "$*" >&2
    exit 1
}

binary=${1:-}
if test -z "$binary"; then
    binary=$(SEED=schema sh "$ROOT/scripts/build-seed.sh" "$ROOT/build/schema")
fi
test -x "$binary" || fail "no built schema binary at $binary"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-db-plan.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

env -i "$binary" >"$WORK/out" || fail 'the schema binary exited non-zero'
test "$(sed -n 1p "$WORK/out")" = 'kofun-boot schema' ||
    fail 'the binary did not print a schema report'

section() {
    grep -qx "$1" "$WORK/out" || fail "the schema report has no '$1' section"
    grep -qx "end $1" "$WORK/out" || fail "the '$1' section is never closed"
    sed -n "/^$1\$/,/^end $1\$/p" "$WORK/out" | sed '1d;$d'
}

# Codes to the source names the core declares. A code without a name is
# refused before anything is printed.
step_fn() {
    case $1 in
        1) printf 'step_create_table()' ;;
        2) printf 'step_add_column()' ;;
        3) printf 'step_rename_column()' ;;
        4) printf 'step_drop_column()' ;;
        5) printf 'step_set_nullable()' ;;
        6) printf 'step_alter_kind()' ;;
        *) return 1 ;;
    esac
}

table_fn() {
    case $1 in
        1) printf 'table_users()' ;;
        2) printf 'table_posts()' ;;
        *) return 1 ;;
    esac
}

label_fn() {
    case $1 in
        0) printf '0' ;;
        1) printf 'label_id()' ;;
        2) printf 'label_email()' ;;
        3) printf 'label_name()' ;;
        4) printf 'label_display_name()' ;;
        5) printf 'label_nickname()' ;;
        6) printf 'label_author_id()' ;;
        7) printf 'label_views()' ;;
        *) return 1 ;;
    esac
}

kind_fn() {
    case $1 in
        0) printf '0' ;;
        1) printf 'kind_bigint()' ;;
        2) printf 'kind_text()' ;;
        3) printf 'kind_boolean()' ;;
        4) printf 'kind_integer()' ;;
        *) return 1 ;;
    esac
}

count=$(section history | sed -n 1p)
case $count in
    ''|*[!0-9]*) fail 'the history section does not open with a step count' ;;
esac
section plan | paste - - - - - - - - | awk -F'\t' '$1 != 0' >"$WORK/planned"

while IFS='	' read -r kind table key label column_kind nullable policy ref; do
    step_fn "$kind" >/dev/null || fail "migration kind $kind has no source name"
    table_fn "$table" >/dev/null || fail "table code $table has no source name"
    label_fn "$label" >/dev/null || fail "label code $label has no source name"
    kind_fn "$column_kind" >/dev/null || fail "column kind $column_kind has no source name"
    test "$policy" = 0 || fail "the planner supplied policy $policy; a policy is a person's decision"
done <"$WORK/planned"

OUT="$WORK/source"
if test ! -s "$WORK/planned"; then
    printf -- '# db-plan: nothing to plan; the history replays to the declaration\n' >"$OUT"
else
    {
        printf '# Planned by scripts/db-plan.sh from the plan the schema binary printed.\n'
        printf '# Append to history_step() in modules/schema/core/schema.kofun, raise\n'
        printf '# history_length() to %s, and write a policy wherever apply asks for one.\n' \
            "$((count + $(wc -l <"$WORK/planned")))"
        number=$count
        while IFS='	' read -r kind table key label column_kind nullable policy ref; do
            number=$((number + 1))
            case $kind in
                4) printf '    # apply refuses this as Destructive until the policy is policy_discard()\n' ;;
                5)
                    if test "$nullable" = 0; then
                        printf '    # apply refuses this as NeedsBackfill until the policy is policy_backfilled()\n'
                    fi
                    ;;
                6) printf '    # a narrowing is refused as Destructive until the policy is policy_discard()\n' ;;
                2)
                    if test "$nullable" = 0; then
                        printf '    # apply refuses this as NeedsBackfill until the policy is policy_backfilled()\n'
                    fi
                    ;;
            esac
            printf '    if number == %s {\n' "$number"
            if test "$ref" != 0; then
                printf '        return referencing(\n'
            else
                printf '        return migration(\n'
            fi
            printf '            %s, %s, %s, %s, %s, %s,\n' \
                "$(step_fn "$kind")" "$(table_fn "$table")" "$key" \
                "$(label_fn "$label")" "$(kind_fn "$column_kind")" "$nullable"
            if test "$ref" != 0; then
                printf '            policy_none(), %s\n' "$ref"
            else
                printf '            policy_none()\n'
            fi
            printf '        )\n'
            printf '    }\n'
        done <"$WORK/planned"
    } >"$OUT"
fi

cat "$OUT"
