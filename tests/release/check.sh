#!/bin/sh
set -eu

# The release gate.
#
# A release is the largest claim this repository makes, so it gets the
# strictest gate. The rule it enforces is not "everything must be measured" —
# that would mean no release ever ships while the desktop lane is blocked on
# the language. It is:
#
#   a release may ship with unmeasured bars; it may not ship without saying
#   exactly which ones.
#
# So the README's pillar table is the source of truth for measurement status,
# and CHANGELOG.md must declare the identical set. Drift in either direction
# fails, naming the bar and the side it is missing from. At 1.0.0 the set must
# be empty.
#
# docs/RELEASING.md is the prose; this file is the enforcement.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
README="$ROOT/README.md"
CHANGELOG="$ROOT/CHANGELOG.md"
VERSION_FILE="$ROOT/VERSION"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-boot-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
    printf 'release: FAIL: %s\n' "$*" >&2
    exit 1
}

for f in "$README" "$CHANGELOG" "$VERSION_FILE"; do
    test -f "$f" || fail "missing required file: ${f#"$ROOT"/}"
done

# ------------------------------------------------------------- the version

version=$(tr -d ' \t\n\r' <"$VERSION_FILE")
test -n "$version" || fail 'VERSION is empty'

# Semver, deliberately without the prerelease/build grammar: this project has
# no use for one yet, and accepting syntax nothing consumes is how a format
# grows a case with no reader.
if ! printf '%s' "$version" | grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
then
    fail "VERSION is not a plain semver triple: '$version'"
fi

major=${version%%.*}

# ------------------------------------------- what the README says is unmeasured
#
# The pillar table's third column carries the bar. A bar that has not been
# measured says so in italics. Read the pillar name out of the first column.
#
# Comments are not a concern here the way they are in the Kofun gates — this
# is Markdown — but prose elsewhere in the README does mention the word, so
# the match is anchored to the table's row shape rather than to the file.

awk -F'|' '
    /^\| *[A-Z]/ && NF >= 4 && $4 ~ /\*unmeasured/ {
        name = $2
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        print name
    }
' "$README" | sort >"$WORK/readme.unmeasured"

# Every pillar row that claims to be true *now*, so the claim can be checked
# against a gate that exists.
#
# The marker is the word "today", not the phrase "holds today". The README
# says it four different ways — "holds today", "hold today", "holds for the
# document and the TypeScript client today" — and an earlier version of this
# gate matched only the first, so "A CLI worth living in" silently left the
# checked set and deleting its gate went unnoticed. Matching the word the
# claims actually share is both simpler and harder to drift away from.
#
# The rows that do *not* claim present-tense truth avoid the word entirely:
# the unmeasured bars say "unmeasured", and structured concurrency says
# "blocked on the language RFC". That is what makes this marker precise
# rather than merely convenient.
awk -F'|' '
    /^\| *[A-Z]/ && NF >= 4 {
        name = $2; bar = $4
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        if (bar ~ /today/) print name
    }
' "$README" | sort >"$WORK/readme.holds"

test -s "$WORK/readme.holds" ||
    fail 'no pillar claims to hold today; the marker this gate reads has moved, and it is now checking nothing'

if [ ! -s "$WORK/readme.unmeasured" ] && [ "$major" -lt 1 ]; then
    # Not an error — but it is the one transition worth announcing, because it
    # means 1.0.0 has become possible and nobody may notice from the diff.
    printf 'release: note: no unmeasured bars remain; 1.0.0 is now permitted\n'
fi

# ------------------------------------ what the CHANGELOG declares for this version

# The section runs from its own heading to the next release heading.
awk -v want="## [$version]" '
    index($0, want) == 1 { inside = 1; print; next }
    inside && /^## / { exit }
    inside { print }
' "$CHANGELOG" >"$WORK/section"

test -s "$WORK/section" ||
    fail "CHANGELOG.md has no section for version $version (expected a '## [$version]' heading)"

grep -qE "^## \[$(printf '%s' "$version" | sed 's/\./\\./g')\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" \
    "$WORK/section" ||
    fail "the CHANGELOG section for $version is not dated as '## [$version] - YYYY-MM-DD'"

grep -q '^### Unmeasured at this release$' "$WORK/section" ||
    fail "the CHANGELOG section for $version has no '### Unmeasured at this release' block"

# The declared bars: list items under that heading, up to the next heading.
# A bar may carry an explanation after an em dash; the bar is what precedes it.
awk '
    /^### Unmeasured at this release$/ { inside = 1; next }
    inside && /^### / { exit }
    inside && /^- / {
        line = substr($0, 3)
        split(line, parts, / — /)
        name = parts[1]
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        print name
    }
' "$WORK/section" | sort >"$WORK/changelog.unmeasured"

# ------------------------------------------------------------ the comparison

if ! cmp -s "$WORK/readme.unmeasured" "$WORK/changelog.unmeasured"; then
    printf 'release: FAIL: the unmeasured set drifted between README.md and CHANGELOG.md\n' >&2
    comm -23 "$WORK/readme.unmeasured" "$WORK/changelog.unmeasured" |
        while IFS= read -r bar; do
            [ -n "$bar" ] &&
                printf '  README says unmeasured, CHANGELOG does not declare it: %s\n' "$bar" >&2
        done
    comm -13 "$WORK/readme.unmeasured" "$WORK/changelog.unmeasured" |
        while IFS= read -r bar; do
            [ -n "$bar" ] &&
                printf '  CHANGELOG declares it unmeasured, README does not: %s\n' "$bar" >&2
        done
    printf '  the README pillar table is the source of truth; fix the CHANGELOG to match it\n' >&2
    exit 1
fi

# --------------------------------------------------------- the 1.0.0 rule

if [ "$major" -ge 1 ] && [ -s "$WORK/readme.unmeasured" ]; then
    printf 'release: FAIL: %s is a 1.x release, which may not ship an unmeasured bar\n' \
        "$version" >&2
    sed 's/^/  still unmeasured: /' "$WORK/readme.unmeasured" >&2
    exit 1
fi

# ------------------------------- a "holds today" claim needs a gate that exists

# The pillars that claim to hold, and the gate each one rests on. A claim
# whose gate was deleted is a claim with nothing behind it, and that is
# exactly the drift this repository gates against everywhere else.
while IFS= read -r pillar; do
    [ -n "$pillar" ] || continue
    case "$pillar" in
        'Contract-first APIs'|'Functional core, imperative shell'|\
        'Deterministic replay'|'Capabilities, not containers')
            gate="tests/boot/check.sh" ;;
        'A CLI worth living in')
            gate="tests/scaffold/check.sh" ;;
        'Schema as a contract')
            gate="tests/schema/check.sh" ;;
        'No N+1 by construction')
            gate="tests/loader/check.sh" ;;
        *)
            fail "README claims '$pillar' holds today, but the release gate does not know which gate proves it; add it here or soften the claim" ;;
    esac
    test -f "$ROOT/$gate" ||
        fail "README claims '$pillar' holds today, but its gate $gate does not exist"
done <"$WORK/readme.holds"

# ------------------------------------------------------------ the tag

tag="v$version"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
    fail "tag $tag already exists; bump VERSION before releasing again"
fi

# ------------------------------------------------------------- the report

printf 'release: version %s, tag %s (not yet created)\n' "$version" "$tag"
if [ -s "$WORK/readme.unmeasured" ]; then
    printf 'release: unmeasured bars, declared in both places:\n'
    sed 's/^/  - /' "$WORK/readme.unmeasured"
else
    printf 'release: every bar is measured\n'
fi
printf 'release: PASS: version, dated section, declared unmeasured set matches README, gates exist\n'
