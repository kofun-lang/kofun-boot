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
# The cluster lives in a mktemp directory, listens only on a Unix socket in
# that directory, and is stopped on every exit path. Nothing on the host is
# touched.
#
# PostgreSQL is not a build dependency, so a machine without it reports SKIP.
# CI sets SCHEMA_REQUIRE_POSTGRES=1, which turns that SKIP into a failure: a
# gate that quietly degrades on the machine that matters is a gate that is not
# running.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

fail() {
    printf 'schema-postgres: FAIL: %s\n' "$*" >&2
    exit 1
}

skip() {
    if test "${SCHEMA_REQUIRE_POSTGRES:-0}" = 1; then
        fail "$* (SCHEMA_REQUIRE_POSTGRES=1)"
    fi
    printf 'schema-postgres: SKIP: %s\n' "$*"
    exit 0
}

bindir=''
if command -v pg_config >/dev/null 2>&1; then
    candidate=$(pg_config --bindir 2>/dev/null || true)
    test -x "$candidate/initdb" && bindir=$candidate
fi
if test -z "$bindir"; then
    for candidate in /usr/lib/postgresql/*/bin; do
        test -x "$candidate/initdb" && bindir=$candidate
    done
fi
test -n "$bindir" || skip 'no PostgreSQL server binaries (initdb) found'

# PostgreSQL refuses to run as root. A root shell — a container, usually —
# runs the cluster as the `postgres` account when it exists.
as_cluster_user=''
if test "$(id -u)" = 0; then
    id postgres >/dev/null 2>&1 || skip 'running as root and there is no postgres account'
    as_cluster_user=postgres
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-postgres.XXXXXX")
chmod 0755 "$WORK"
started=0
cleanup() {
    if test "$started" = 1; then
        run "$bindir/pg_ctl" -D "$WORK/data" -m immediate -w stop >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup 0 1 2 15

# Every command goes through one shell, as the cluster user when there is
# one, so the quoting of pg_ctl's -o string means the same thing either way.
# Arguments are fixed flags and paths under a mktemp directory.
run() {
    if test -n "$as_cluster_user"; then
        su "$as_cluster_user" -s /bin/sh -c "$*"
    else
        /bin/sh -c "$*"
    fi
}

for file in schema.sql migrations.sql; do
    test -f "$ROOT/contracts/$file" || fail "contracts/$file is missing"
    cp "$ROOT/contracts/$file" "$WORK/$file"
done
# The negative control: the declared DDL with one NOT NULL removed.
sed 's/^    email text not null, -- key 2$/    email text, -- key 2/' \
    "$WORK/schema.sql" >"$WORK/broken.sql"
cmp -s "$WORK/schema.sql" "$WORK/broken.sql" &&
    fail 'the negative control changed nothing; its sed no longer matches contracts/schema.sql'
test -z "$as_cluster_user" || chown -R "$as_cluster_user" "$WORK"

run "$bindir/initdb" -D "$WORK/data" -A trust -U kofun --no-sync \
    >"$WORK/initdb.log" 2>&1 || fail "initdb failed: $(tail -5 "$WORK/initdb.log")"
run "$bindir/pg_ctl" -D "$WORK/data" -w -l "$WORK/server.log" \
    -o "'-k $WORK -c listen_addresses= -F'" start >/dev/null 2>&1 ||
    fail "the cluster did not start: $(tail -5 "$WORK/server.log" 2>/dev/null)"
started=1

build() {
    database=$1
    script=$2
    run "$bindir/createdb" -h "$WORK" -U kofun "$database" ||
        fail "could not create database $database"
    run "$bindir/psql" -h "$WORK" -U kofun -d "$database" -X -q \
        -v ON_ERROR_STOP=1 -f "$WORK/$script" >"$WORK/$database.log" 2>&1 ||
        fail "$script did not apply cleanly: $(cat "$WORK/$database.log")"
    # pg_dump 16.10+ wraps the dump in \restrict lines carrying a random key.
    # They are a property of the dump run, not of the schema, so they are
    # removed before comparing; everything else is compared byte for byte.
    run "$bindir/pg_dump" -h "$WORK" -U kofun --schema-only --no-owner \
        -f "$WORK/$database.dump" "$database" ||
        fail "could not dump $database"
    grep -v '^\\restrict \|^\\unrestrict ' "$WORK/$database.dump" >"$WORK/$database.schema"
}

build from_history migrations.sql
build from_declaration schema.sql
build from_broken broken.sql

grep -q '^CREATE TABLE public.users' "$WORK/from_history.schema" ||
    fail 'the database built from the history has no users table; the comparison would be vacuous'
cmp -s "$WORK/from_history.schema" "$WORK/from_declaration.schema" ||
    fail "the history and the declared DDL build different databases:
$(diff "$WORK/from_history.schema" "$WORK/from_declaration.schema")"
if cmp -s "$WORK/from_history.schema" "$WORK/from_broken.schema"; then
    fail 'a declared DDL with a NOT NULL removed built the same database; the comparison cannot fail'
fi

version=$("$bindir/postgres" --version)
printf 'schema-postgres: %s\n' "$version"
printf 'schema-postgres: migrations.sql and schema.sql build the same database: PASS\n'
printf 'schema-postgres: a declared DDL missing one NOT NULL builds a different one: PASS\n'
