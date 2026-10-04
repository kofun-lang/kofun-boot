#!/bin/sh
set -eu

# The startup check: is this database at the schema this binary declares?
#
#   scripts/db-marker.sh DIGEST
#
# DIGEST is the `db.schema` value the schema binary printed in its identity
# section (scripts/schema-digest.sh computes the same number from source).
# The database is the one libpq's environment names — PGHOST, PGPORT,
# PGUSER, PGDATABASE — and PSQL names the client, `psql` by default.
#
# Both SQL projections end by recording the digest in kofun_schema_marker.
# This refuses two databases, by name, before anything else could touch them:
#
#   one with no marker  — it was not built by this history at all
#   one with another    — it was migrated to a different declaration, usually
#                         one step behind a deploy or one step ahead of it
#
# It belongs to the shell, because reading a database is a capability. Until
# the shell holds a database capability of its own, this script is that
# adapter, and tests/schema/postgres.sh runs it against a real cluster.

fail() {
    printf 'db-marker: FAIL: %s\n' "$*" >&2
    exit 1
}

expected=${1:-}
case $expected in
    ''|*[!0-9]*) printf 'usage: scripts/db-marker.sh DIGEST\n' >&2; exit 2 ;;
esac
PSQL=${PSQL:-psql}

present=$("$PSQL" -X -A -t -v ON_ERROR_STOP=1 \
    -c "select count(*) from pg_tables where tablename = 'kofun_schema_marker'") ||
    fail 'could not query the database'
test "$present" = 1 ||
    fail 'the database carries no schema marker; it was not built by this migration history'

held=$("$PSQL" -X -A -t -v ON_ERROR_STOP=1 -c 'select digest from kofun_schema_marker') ||
    fail 'could not read the schema marker'
test "$(printf '%s\n' "$held" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ||
    fail "the schema marker holds $(printf '%s\n' "$held" | sed '/^$/d' | wc -l | tr -d ' ') rows, not one"
test "$held" = "$expected" ||
    fail "the database was migrated to schema digest $held; this binary declares $expected"

printf 'db-marker: the database holds schema digest %s, the one this binary declares\n' "$expected"
