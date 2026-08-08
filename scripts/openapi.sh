#!/bin/sh
set -eu

# Project the compiled route table into an OpenAPI document.
#
# The input is not a second declaration of the routes: it is the first twenty
# lines the router itself prints, which the gate pins as the compiled table —
# four per slot, the fourth being whether the route captures. A document
# generated from those bytes cannot describe a route the dispatcher does not
# serve, and cannot miss one it does.
#
# usage: scripts/openapi.sh [BUILT_ROUTER]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
    printf 'openapi: %s\n' "$*" >&2
    exit 1
}

router=${1:-}
if test -z "$router"; then
    router=$(sh "$ROOT/scripts/build-seed.sh" "$ROOT/build/router")
fi
test -x "$router" || fail "no built router at $router"

table=$("$router" | sed -n '1,20p')
test "$(printf '%s\n' "$table" | wc -l)" -eq 20 ||
    fail 'the router did not print a twenty-line table'

# The one seam the slice forces: the table carries path codes because a record
# cannot hold Text. Names live here, and every code must have one — a route
# added without a name fails rather than appearing as a number.
#
# The names are resolved *before* anything is emitted, in this shell rather
# than inside a command substitution. A `fail` inside `$( )` exits only the
# subshell: the first version of this script called `path_name` from inside
# `printf '%s' "$(path_name "$code")"`, so an unnamed route produced an empty
# path and a clean exit status — a document that silently described a route
# that does not exist. Resolving up front is what makes the refusal reachable.
#
# A capturing slot names a template rather than a path: the code is the base
# the slot matches, and the document has to show the parameter the dispatcher
# will capture, or it describes a route nobody can call.
path_name() {
    case $1 in
        101) printf '/hello' ;;
        102) printf '/sum' ;;
        103) printf '/bench' ;;
        104) printf '/things/{id}' ;;
        *) return 1 ;;
    esac
}

method_name() {
    case $1 in
        1) printf 'get' ;;
        2) printf 'post' ;;
        *) return 1 ;;
    esac
}

# Group by path so each path object carries all its methods, which is what
# makes the document say the same thing the Allow set says.
codes=$(printf '%s\n' "$table" | paste - - - - | awk '{print $2}' | sort -un)

# Resolve every name first, so an unknown code stops the run instead of
# producing a document with a hole in it.
for code in $codes; do
    path_name "$code" >/dev/null ||
        fail "route code $code has no path name; add it to scripts/openapi.sh"
done
for method in $(printf '%s\n' "$table" | paste - - - - | awk '{print $1}' | sort -un); do
    method_name "$method" >/dev/null ||
        fail "method code $method is not in the contract"
done

printf 'openapi: 3.1.0\n'
printf 'info:\n'
printf '  title: kofun-boot seed\n'
printf '  version: 0.1.0\n'
printf 'paths:\n'
for code in $codes; do
    printf '  %s:\n' "$(path_name "$code")"
    printf '%s\n' "$table" | paste - - - - |
    while IFS='	' read -r method path handler capture; do
        test "$path" = "$code" || continue
        printf '    %s:\n' "$(method_name "$method")"
        printf '      operationId: handler%s\n' "$handler"
        # A captured segment is a path parameter, and a document that omits it
        # describes a URL template with an undeclared hole in it.
        if test "$capture" = 1; then
            printf '      parameters:\n'
            printf '        - name: id\n'
            printf '          in: path\n'
            printf '          required: true\n'
            printf '          schema: { type: integer }\n'
        fi
        printf '      responses:\n'
        printf '        "200": { description: ok }\n'
        printf '        "404": { description: no route matched }\n'
        printf '        "405": { description: method not allowed }\n'
        printf '        "413": { description: body over the limit }\n'
    done
done
