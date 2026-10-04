#!/bin/sh
set -eu

# N+1, measured by a real database.
#
# tests/loader/check.sh proves in values that the shipped strategy's statement
# count does not move with N. This asks PostgreSQL itself. The throwaway
# cluster runs with `log_statement = 'all'` and an application-name prefix, so
# every statement a client sends is logged under the name of the run that sent
# it, and the count is read from the server's log, not from this script.
#
# For N = 1, 2, 3, 4 authors, seeded from the data the loader binary printed,
# the same question — every author with the ids of their posts — is asked
# three ways:
#
#   join     contracts/shapes.sql's joined shape: one LATERAL statement
#   split    contracts/shapes.sql's split shape: the roots, then every
#            child of every root in one `= any($1)` statement
#   per-row  the control: the roots, then one statement per author
#
# The answers must be identical at every N, and identical to the seed. The
# statement counts must be 1, 2, and N + 1. The control is what makes the
# measurement trustworthy: if it ever stops growing, the log is no longer
# counting what the clients sent.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PG_LABEL=loader-postgres
. "$ROOT/tests/lib/postgres.sh"

fail() {
    pg_fail "$*"
}

shapes="$ROOT/contracts/shapes.sql"
test -f "$shapes" || fail 'contracts/shapes.sql is missing; run scripts/shape-sql.sh shapes'

binary=$(SEED=loader sh "$ROOT/scripts/build-seed.sh" "$PG_WORK/loader") ||
    fail 'the loader seed did not build'

# One file per shape block, by its load: the statements under a
# `-- shape: ... load <load>:` header, up to the next header.
awk -v dir="$PG_WORK" '
    /^-- shape: .* load [a-z]+:/ {
        load = $0
        sub(/^.* load /, "", load)
        sub(/:.*$/, "", load)
        file = dir "/shape." load ".sql"
        printf "" > file
        next
    }
    load == "" { next }
    /^--/ { next }
    { print >> file }
' "$shapes"
for load in join split; do
    test -s "$PG_WORK/shape.$load.sql" || fail "contracts/shapes.sql has no '$load' shape"
done
# The split shape is two statements; they run as two requests, the second
# bound to the ids the first returned, the way an application would run them.
awk -v dir="$PG_WORK" '
    { print > (dir "/split." (n + 1) ".sql") }
    /;$/ { n++ }
' "$PG_WORK/shape.split.sql"
test -s "$PG_WORK/split.2.sql" || fail 'the split shape is not two statements'

pg_start "log_statement = 'all'" "log_line_prefix = '%a|'"

psql_as() {
    app=$1
    database=$2
    file=$3
    pg_own "$file"
    pg_run "PGAPPNAME=$app" "$(pg_bin psql)" -h "$PG_WORK" -U kofun -d "$database" \
        -X -q -A -t -v ON_ERROR_STOP=1 -f "$file"
}

statements_of() {
    grep -c "^$1|LOG:  statement: " "$PG_WORK/server.log" || true
}

# "author:[ids]" per line, ids without spaces, in author order.
normalize_pairs() {
    tr -d ' ' | sed 's/|/:/'
}

for n in 1 2 3 4; do
    database=shape_$n
    pg_run "$(pg_bin createdb)" -h "$PG_WORK" -U kofun "$database" ||
        fail "could not create database $database"
    sh "$ROOT/scripts/shape-sql.sh" fixture "$n" "$binary" >"$PG_WORK/fixture.$n.sql"
    psql_as fixture "$database" "$PG_WORK/fixture.$n.sql" >/dev/null ||
        fail "the fixture for N=$n did not load"

    # The seed's own answer, from the fixture: author k owns the posts the
    # fixture inserted under it, in id order.
    awk '
        /^insert into authors/ { gsub(/[^0-9]/, "", $0); order[++a] = $0; ids[$0] = ""; next }
        /^insert into posts/ {
            line = $0
            sub(/^.*values \(/, "", line); sub(/\);$/, "", line)
            split(line, f, ", ")
            ids[f[2]] = ids[f[2]] (ids[f[2]] == "" ? "" : ",") f[1]
        }
        END { for (i = 1; i <= a; i++) print order[i] ":[" ids[order[i]] "]" }
    ' "$PG_WORK/fixture.$n.sql" >"$PG_WORK/expected.$n"

    # join: one statement.
    psql_as "join_$n" "$database" "$PG_WORK/shape.join.sql" |
        normalize_pairs >"$PG_WORK/join.$n" || fail "the joined shape failed at N=$n"

    # split: the roots, then the children of all of them, bound to their ids.
    psql_as "split_$n" "$database" "$PG_WORK/split.1.sql" >"$PG_WORK/split.roots.$n" ||
        fail "the split shape's root statement failed at N=$n"
    roots=$(paste -sd, "$PG_WORK/split.roots.$n")
    sed "s/any(\$1)/any('{$roots}'::bigint[])/" "$PG_WORK/split.2.sql" >"$PG_WORK/split.2.$n.sql"
    psql_as "split_$n" "$database" "$PG_WORK/split.2.$n.sql" |
        normalize_pairs >"$PG_WORK/split.children.$n" ||
        fail "the split shape's child statement failed at N=$n"
    # An author with no posts has no group; the application fills it in.
    while IFS= read -r author; do
        found=$(grep "^$author:" "$PG_WORK/split.children.$n" || true)
        printf '%s\n' "${found:-$author:[]}"
    done <"$PG_WORK/split.roots.$n" >"$PG_WORK/split.$n"

    # per-row: the control. The roots, then one statement per author.
    psql_as "perrow_$n" "$database" "$PG_WORK/split.1.sql" >"$PG_WORK/perrow.roots.$n" ||
        fail "the per-row control's root statement failed at N=$n"
    : >"$PG_WORK/perrow.$n"
    while IFS= read -r author; do
        printf "select coalesce(json_agg(p.id order by p.id), '[]'::json) from posts p where p.author_id = %s;\n" \
            "$author" >"$PG_WORK/perrow.one.sql"
        ids=$(psql_as "perrow_$n" "$database" "$PG_WORK/perrow.one.sql" | tr -d ' ') ||
            fail "the per-row control failed for author $author at N=$n"
        printf '%s:%s\n' "$author" "$ids" >>"$PG_WORK/perrow.$n"
    done <"$PG_WORK/perrow.roots.$n"

    test -s "$PG_WORK/expected.$n" || fail "the fixture for N=$n holds no authors"
    for run in join split perrow; do
        cmp -s "$PG_WORK/expected.$n" "$PG_WORK/$run.$n" ||
            fail "the $run answer at N=$n differs from the seed:
$(diff "$PG_WORK/expected.$n" "$PG_WORK/$run.$n")"
    done
done

counts() {
    for n in 1 2 3 4; do
        printf '%s ' "$(statements_of "$1_$n")"
    done | sed 's/ $//'
}

join=$(counts join)
split=$(counts split)
perrow=$(counts perrow)

test "$perrow" = '2 3 4 5' ||
    fail "the per-row control sent '$perrow' statements for N = 1 2 3 4, not N + 1; the log is not counting what clients send"
test "$join" = '1 1 1 1' ||
    fail "N+1: the joined shape sent '$join' statements for N = 1 2 3 4"
test "$split" = '2 2 2 2' ||
    fail "N+1: the split shape sent '$split' statements for N = 1 2 3 4"

printf 'loader-postgres: %s\n' "$(pg_version)"
printf 'loader-postgres: statements counted by the server for N = 1 2 3 4: join %s; split %s; per-row %s\n' \
    "$join" "$split" "$perrow"
printf 'loader-postgres: all three answer the same as the seed at every N: PASS\n'
printf 'loader-postgres: the shapes cost the same at every N, and the per-row control costs N + 1: PASS\n'
