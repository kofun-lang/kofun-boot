# A throwaway PostgreSQL cluster, for the gates that need a real database.
#
# Sourced, not run. The caller sets PG_LABEL (the prefix for its messages)
# before sourcing, then:
#
#   pg_start [SETTING ...]         initdb, append postgresql.conf lines, start
#   pg_run CMD ...                 run a command as the cluster's user
#   pg_bin NAME                    the path of one PostgreSQL binary
#
# The cluster lives in a mktemp directory, listens only on a Unix socket in
# that directory, and is stopped on every exit path. Nothing on the host is
# touched. Both tests/schema/postgres.sh and tests/loader/postgres.sh use it,
# so the two cannot drift in how they start, stop, or skip.
#
# PostgreSQL is not a build dependency, so a machine without it reports SKIP.
# CI sets SCHEMA_REQUIRE_POSTGRES=1, which turns that SKIP into a failure: a
# gate that quietly degrades on the machine that matters is a gate that is not
# running.

pg_fail() {
    printf '%s: FAIL: %s\n' "$PG_LABEL" "$*" >&2
    exit 1
}

pg_skip() {
    if test "${SCHEMA_REQUIRE_POSTGRES:-0}" = 1; then
        pg_fail "$* (SCHEMA_REQUIRE_POSTGRES=1)"
    fi
    printf '%s: SKIP: %s\n' "$PG_LABEL" "$*"
    exit 0
}

PG_BINDIR=''
if command -v pg_config >/dev/null 2>&1; then
    pg_candidate=$(pg_config --bindir 2>/dev/null || true)
    test -x "$pg_candidate/initdb" && PG_BINDIR=$pg_candidate
fi
if test -z "$PG_BINDIR"; then
    for pg_candidate in /usr/lib/postgresql/*/bin; do
        test -x "$pg_candidate/initdb" && PG_BINDIR=$pg_candidate
    done
fi
test -n "$PG_BINDIR" || pg_skip 'no PostgreSQL server binaries (initdb) found'

# PostgreSQL refuses to run as root. A root shell — a container, usually —
# runs the cluster as the `postgres` account when it exists.
PG_USER=''
if test "$(id -u)" = 0; then
    id postgres >/dev/null 2>&1 || pg_skip 'running as root and there is no postgres account'
    PG_USER=postgres
fi

PG_WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-postgres.XXXXXX")
chmod 0755 "$PG_WORK"
PG_STARTED=0

pg_cleanup() {
    if test "$PG_STARTED" = 1; then
        pg_run "$PG_BINDIR/pg_ctl" -D "$PG_WORK/data" -m immediate -w stop >/dev/null 2>&1 || true
    fi
    rm -rf "$PG_WORK"
}
trap pg_cleanup 0 1 2 15

# Every command goes through one shell, as the cluster user when there is
# one, so quoting means the same thing either way. Arguments are fixed flags
# and paths under the mktemp directory.
pg_run() {
    if test -n "$PG_USER"; then
        su "$PG_USER" -s /bin/sh -c "$*"
    else
        /bin/sh -c "$*"
    fi
}

pg_bin() {
    printf '%s/%s' "$PG_BINDIR" "$1"
}

# Hand a file to the cluster's user.
pg_own() {
    test -z "$PG_USER" || chown -R "$PG_USER" "$@"
}

# Each argument is one postgresql.conf line, appended before the server
# starts. Settings go through the file rather than pg_ctl's -o string, which
# reaches the server through a second shell and would mangle a value such as
# a log_line_prefix.
pg_start() {
    pg_own "$PG_WORK"
    pg_run "$PG_BINDIR/initdb" -D "$PG_WORK/data" -A trust -U kofun --no-sync \
        >"$PG_WORK/initdb.log" 2>&1 ||
        pg_fail "initdb failed: $(tail -5 "$PG_WORK/initdb.log")"
    {
        printf "listen_addresses = ''\n"
        printf "unix_socket_directories = '%s'\n" "$PG_WORK"
        printf 'fsync = off\n'
        for pg_setting in "$@"; do
            printf '%s\n' "$pg_setting"
        done
    } >>"$PG_WORK/data/postgresql.conf"
    pg_run "$PG_BINDIR/pg_ctl" -D "$PG_WORK/data" -w -l "$PG_WORK/server.log" \
        start >/dev/null 2>&1 ||
        pg_fail "the cluster did not start: $(tail -5 "$PG_WORK/server.log" 2>/dev/null)"
    PG_STARTED=1
}

pg_version() {
    "$PG_BINDIR/postgres" --version
}
