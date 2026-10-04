#!/bin/sh
set -eu

# The schema identity printed by the schema binary and written into every
# database its SQL builds.
#
# It is a digest of the declared tables — the `declared_users` and
# `declared_posts` functions in the schema core — read with comments stripped,
# so rewording an explanation never reads as a change to the schema. It is the
# capability manifest's build identity applied to data: it changes exactly when
# what the application expects of its database changes.
#
# Prisma 8's `db sign` writes a contract hash into a marker table, so an
# application can tell it is pointed at a database migrated to something else.
# The same idea here: both SQL projections end by recording this digest in
# `kofun_schema_marker`, and scripts/db-marker.sh refuses a database whose
# marker is missing or names another digest.
#
# Seven hex digits printed as decimal, because the binary prints it with
# `print`, which takes an Int.
#
# usage: scripts/schema-digest.sh [CORE_SOURCE]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
core=${1:-"$ROOT/modules/schema/core/schema.kofun"}

test -f "$core" || {
    printf 'schema-digest: no such core source: %s\n' "$core" >&2
    exit 2
}

code=$(sed 's/[[:space:]]*#.*$//' "$core")
block=$(printf '%s\n' "$code" | sed -n '/^fn declared_users() -> Schema {$/,/^}$/p')
block="$block
$(printf '%s\n' "$code" | sed -n '/^fn declared_posts() -> Schema {$/,/^}$/p')"

case $block in
    *'fn declared_users'*'fn declared_posts'*) ;;
    *)
        printf 'schema-digest: %s does not declare both tables\n' "$core" >&2
        exit 1
        ;;
esac

hex=$(printf '%s\n' "$block" | sha256sum | cut -c1-7)
printf '%d\n' "$((0x$hex))"
