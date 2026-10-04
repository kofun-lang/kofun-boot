#!/bin/sh
set -eu

# The SQL projections, against a real database.
#
# tests/schema/check.sh proves the history replays to the declared schema as
# values. This proves the same thing about the SQL: a throwaway PostgreSQL
# cluster gets two databases, one built by running contracts/migrations.sql
# step by step and one built from contracts/schema.sql in one statement, and
# their schema-only dumps must be byte-identical. Prisma's shadow database
# answers this question during development; here it is a gate, and the value
# fold already answered it before any server started — this run checks that
# the projection did not lose anything on the way to SQL.
#
# Then it breaks the declared DDL in a copy — drops one NOT NULL — and requires
# the dumps to differ, so the comparison is shown to be able to fail.
#
# The cluster, and the SKIP rule for a machine without PostgreSQL, come from
# tests/lib/postgres.sh.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PG_LABEL=schema-postgres
. "$ROOT/tests/lib/postgres.sh"

fail() {
    pg_fail "$*"
}

for file in schema.sql migrations.sql; do
    test -f "$ROOT/contracts/$file" || fail "contracts/$file is missing"
    cp "$ROOT/contracts/$file" "$PG_WORK/$file"
done
# The negative control: the declared DDL with one NOT NULL removed.
sed 's/^    email text not null, -- key 2$/    email text, -- key 2/' \
    "$PG_WORK/schema.sql" >"$PG_WORK/broken.sql"
cmp -s "$PG_WORK/schema.sql" "$PG_WORK/broken.sql" &&
    fail 'the negative control changed nothing; its sed no longer matches contracts/schema.sql'
# And one with the reference removed: a foreign key the dump did not compare
# would be a reference the gate cannot see.
sed 's/^    author_id bigint not null references users (id), -- key 2$/    author_id bigint not null, -- key 2/' \
    "$PG_WORK/schema.sql" >"$PG_WORK/unreferenced.sql"
cmp -s "$PG_WORK/schema.sql" "$PG_WORK/unreferenced.sql" &&
    fail 'the reference control changed nothing; its sed no longer matches contracts/schema.sql'

pg_start

build() {
    database=$1
    script=$2
    pg_own "$PG_WORK/$script"
    pg_run "$(pg_bin createdb)" -h "$PG_WORK" -U kofun "$database" ||
        fail "could not create database $database"
    pg_run "$(pg_bin psql)" -h "$PG_WORK" -U kofun -d "$database" -X -q \
        -v ON_ERROR_STOP=1 -f "$PG_WORK/$script" >"$PG_WORK/$database.log" 2>&1 ||
        fail "$script did not apply cleanly: $(cat "$PG_WORK/$database.log")"
    # pg_dump 16.10+ wraps the dump in \restrict lines carrying a random key.
    # They are a property of the dump run, not of the schema, so they are
    # removed before comparing; everything else is compared byte for byte.
    pg_run "$(pg_bin pg_dump)" -h "$PG_WORK" -U kofun --schema-only --no-owner \
        -f "$PG_WORK/$database.dump" "$database" ||
        fail "could not dump $database"
    grep -v '^\\restrict \|^\\unrestrict ' "$PG_WORK/$database.dump" >"$PG_WORK/$database.schema"
}

build from_history migrations.sql
build from_declaration schema.sql
build from_broken broken.sql
build from_unreferenced unreferenced.sql

grep -q '^CREATE TABLE public.users' "$PG_WORK/from_history.schema" ||
    fail 'the database built from the history has no users table; the comparison would be vacuous'
grep -q 'FOREIGN KEY (author_id) REFERENCES public.users(id)' "$PG_WORK/from_history.schema" ||
    fail 'the database built from the history has no posts.author_id reference; the comparison would miss it'
cmp -s "$PG_WORK/from_history.schema" "$PG_WORK/from_declaration.schema" ||
    fail "the history and the declared DDL build different databases:
$(diff "$PG_WORK/from_history.schema" "$PG_WORK/from_declaration.schema")"
if cmp -s "$PG_WORK/from_history.schema" "$PG_WORK/from_broken.schema"; then
    fail 'a declared DDL with a NOT NULL removed built the same database; the comparison cannot fail'
fi
if cmp -s "$PG_WORK/from_history.schema" "$PG_WORK/from_unreferenced.schema"; then
    fail 'a declared DDL with its reference removed built the same database; the comparison cannot see references'
fi

printf 'schema-postgres: %s\n' "$(pg_version)"
printf 'schema-postgres: migrations.sql and schema.sql build the same database: PASS\n'
printf 'schema-postgres: a declared DDL missing one NOT NULL, or its reference, builds a different one: PASS\n'
