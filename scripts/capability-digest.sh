#!/bin/sh
set -eu

# The build identity printed in the capability manifest.
#
# It is a digest of the `type Capabilities` declaration in the router core —
# not a git revision. A revision changes on every commit, so a byte-compared
# golden would churn for reasons unrelated to capabilities, and two manifests
# would differ whenever anything at all had been committed between them. The
# question an operator diffing last week's deploy against today's is asking is
# "did what this can reach change?", and this answers exactly that.
#
# The declaration is read with comments stripped, for the same reason the FCIS
# gate reads code that way: the paragraphs above the record explain what it
# refuses to carry, and rewording an explanation must not read as a change to
# the capability surface.
#
# Seven hex digits, the width of a short revision, so it reads as an identity
# rather than as a number that means something arithmetically.
#
# usage: scripts/capability-digest.sh [CORE_SOURCE]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
core=${1:-"$ROOT/modules/router/core/router.kofun"}

test -f "$core" || {
    printf 'capability-digest: no such core source: %s\n' "$core" >&2
    exit 2
}

block=$(sed 's/[[:space:]]*#.*$//' "$core" |
    sed -n '/^type Capabilities = {$/,/^}$/p')

test -n "$block" || {
    printf 'capability-digest: %s declares no Capabilities record\n' "$core" >&2
    exit 1
}

# Printed as decimal because the manifest is emitted by `print`, which takes an
# Int. Seven hex digits is 28 bits, so the value always fits.
hex=$(printf '%s\n' "$block" | sha256sum | cut -c1-7)
printf '%d\n' "$((0x$hex))"
