#!/bin/sh
set -eu

# boot dev — the inner loop.
#
# One command, three modes, no daemon and no state directory:
#
#   scripts/dev.sh            build, run the seed, run the unit suite, once
#   scripts/dev.sh --watch    re-run the unit suite on every save
#   scripts/dev.sh --test     the unit suite only (fastest useful loop)
#   scripts/dev.sh --serve    the integration test: a real server, real sockets
#   scripts/dev.sh --check    everything CI runs, in CI's order
#   scripts/dev.sh --openapi  print the document the route table projects
#   scripts/dev.sh --research build the deterministic research ZIP
#   scripts/dev.sh --client   print the typed client the route table projects
#   scripts/dev.sh --schema   print the DDL and migration SQL the schema projects
#   scripts/dev.sh --db-sql   the same: boot db sql
#   scripts/dev.sh --db-plan  print the next history steps as source: boot db plan
#   scripts/dev.sh --db-check drift, refusals, and projections: boot db check
#   scripts/dev.sh --shapes   print the SQL the loader's declared shapes compile to
#   scripts/dev.sh --scaffold generate a project and run its gate
#   scripts/dev.sh --replay   replay the recorded session trace
#   scripts/dev.sh --bench    measure, or refuse if the machine is busy
#   scripts/dev.sh --release  verify the release is coherent; tag nothing
#
# The design rule is that the loop a developer runs and the loop CI runs are
# the same commands, so a green terminal and a green pipeline mean the same
# thing. `scripts/dev.sh --check` is exactly what CI calls.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
    # Delimited by the header block itself rather than by line numbers: the
    # hardcoded '3,18p' silently dropped --release the moment a mode was added
    # below line 18, which is the failure where help text quietly stops
    # describing the tool. Print from the title to the blank comment line that
    # ends the mode list.
    awk '
        /^# boot dev/ { inside = 1 }
        inside && !/^#/ { exit }
        inside { sub(/^# ?/, ""); print }
    ' "$0"
}

banner() {
    printf '\033[1m%s\033[0m\n' "$*" 2>/dev/null || printf '%s\n' "$*"
}

elapsed() {
    # Whole seconds is enough resolution to notice a loop getting slow, and
    # it needs no dependency beyond the shell.
    printf '%ss' "$(( $(date +%s) - $1 ))"
}

run_tests() {
    banner "unit"
    sh "$ROOT/scripts/test-modules.sh" "$@"
}

run_seed() {
    banner "seed"
    started=$(date +%s)
    binary=$(sh "$ROOT/scripts/build-seed.sh" "$ROOT/build/router")
    printf 'built in %s\n' "$(elapsed "$started")"
    "$binary" >"$ROOT/build/router.out"
    if cmp -s "$ROOT/modules/router/tests/router.stdout" "$ROOT/build/router.out"; then
        printf 'golden matches (%s lines)\n' \
            "$(wc -l <"$ROOT/build/router.out" | tr -d ' ')"
    else
        printf 'golden DIFFERS — review, then re-record if intended:\n'
        diff "$ROOT/modules/router/tests/router.stdout" "$ROOT/build/router.out" |
            head -20
        return 1
    fi
}

once() {
    started=$(date +%s)
    run_tests "$@" || return 1
    run_seed || return 1
    banner "ok in $(elapsed "$started")"
}

case "${1:-}" in
    --help|-h)
        usage
        ;;
    --test)
        shift
        run_tests "$@"
        ;;
    --openapi)
        sh "$ROOT/scripts/openapi.sh"
        ;;
    --research)
        sh "$ROOT/scripts/build-research-pack.sh" "$ROOT/dist"
        ;;
    --client)
        sh "$ROOT/scripts/client-ts.sh"
        ;;
    --schema|--db-sql)
        binary=$(SEED=schema sh "$ROOT/scripts/build-seed.sh" "$ROOT/build/schema")
        sh "$ROOT/scripts/ddl.sh" schema "$binary"
        printf '\n'
        sh "$ROOT/scripts/ddl.sh" migrations "$binary"
        ;;
    --db-plan)
        sh "$ROOT/scripts/db-plan.sh"
        ;;
    --db-check)
        # The schema gate's own checks, without the break tests that prove the
        # gate can fail: the question a developer asks before committing is
        # "is my schema change complete", not "does the gate still work".
        SCHEMA_SKIP_BREAK_TEST=1 sh "$ROOT/tests/schema/check.sh"
        ;;
    --shapes)
        binary=$(SEED=loader sh "$ROOT/scripts/build-seed.sh" "$ROOT/build/loader")
        sh "$ROOT/scripts/shape-sql.sh" shapes "$binary"
        ;;
    --bench)
        shift
        sh "$ROOT/scripts/bench.sh" "${1:-record}"
        ;;
    --replay)
        sh "$ROOT/scripts/trace.sh" replay "$ROOT/contracts/session.trace"
        ;;
    --scaffold)
        sh "$ROOT/tests/scaffold/check.sh"
        ;;
    --release)
        # Verification only. Tagging and publishing are deliberately manual
        # and live in docs/RELEASING.md, because they are the two steps that
        # reach outside the repository.
        sh "$ROOT/tests/release/check.sh"
        ;;
    --serve)
        banner "serve"
        sh "$ROOT/tests/integration/serve.sh"
        ;;
    --check)
        # What CI runs, in CI's order. Kept here so a developer's green and a
        # pipeline's green cannot come to mean different things.
        run_tests
        sh "$ROOT/tests/architecture/check.sh"
        sh "$ROOT/tests/boot/check.sh"
        sh "$ROOT/tests/schema/check.sh"
        sh "$ROOT/tests/schema/postgres.sh"
        sh "$ROOT/tests/loader/check.sh"
        sh "$ROOT/tests/loader/postgres.sh"
        sh "$ROOT/tests/research/check.sh"
        sh "$ROOT/tests/integration/serve.sh"
        sh "$ROOT/tests/scaffold/check.sh"
        sh "$ROOT/tests/release/check.sh"
        ;;
    --watch)
        shift
        banner "watching modules/ — save to re-run"
        sh "$ROOT/scripts/test-modules.sh" --watch "$@"
        ;;
    "")
        once
        ;;
    *)
        usage
        exit 2
        ;;
esac
