# Names for the configuration's codes. Sourced, not run.
#
# scripts/boot-config.sh turns names into codes, and scripts/boot-explain.sh
# turns codes back into names. Both read this one table, so a field cannot
# have one name going in and another coming out. The core holds codes
# because a record cannot hold Text in the language slice (ADR 4).
#
# Every function fails (returns 1) on a code or name it does not know; the
# caller decides how to refuse.

BOOT_FIELD_NAMES='http.bind http.port http.body_limit http.drain_ms http.log_sink'
BOOT_PACK_NAMES='http_minimal http_public http_strict http_lenient'

boot_field_code() {
    case $1 in
        http.bind) printf 1 ;;
        http.port) printf 2 ;;
        http.body_limit) printf 3 ;;
        http.drain_ms) printf 4 ;;
        http.log_sink) printf 5 ;;
        *) return 1 ;;
    esac
}

boot_field_name() {
    case $1 in
        1) printf 'http.bind' ;;
        2) printf 'http.port' ;;
        3) printf 'http.body_limit' ;;
        4) printf 'http.drain_ms' ;;
        5) printf 'http.log_sink' ;;
        *) return 1 ;;
    esac
}

# The source function the core declares for a field, for generated source.
boot_field_fn() {
    case $1 in
        1) printf 'field_bind()' ;;
        2) printf 'field_port()' ;;
        3) printf 'field_body_limit()' ;;
        4) printf 'field_drain_ms()' ;;
        5) printf 'field_log_sink()' ;;
        *) return 1 ;;
    esac
}

boot_pack_bit() {
    case $1 in
        http_minimal) printf 1 ;;
        http_public) printf 2 ;;
        http_strict) printf 4 ;;
        http_lenient) printf 8 ;;
        *) return 1 ;;
    esac
}

boot_pack_name() {
    case $1 in
        1) printf 'http_minimal' ;;
        2) printf 'http_public' ;;
        4) printf 'http_strict' ;;
        8) printf 'http_lenient' ;;
        *) return 1 ;;
    esac
}

boot_pack_fn() {
    case $1 in
        1) printf 'pack_http_minimal()' ;;
        2) printf 'pack_http_public()' ;;
        4) printf 'pack_http_strict()' ;;
        8) printf 'pack_http_lenient()' ;;
        *) return 1 ;;
    esac
}

# A pack mask, as the pack names it holds, lowest bit first.
boot_pack_list() {
    mask=$1
    names=''
    for bit in 1 2 4 8; do
        if test $((mask / bit % 2)) = 1; then
            name=$(boot_pack_name "$bit") || return 1
            names=${names:+"$names "}$name
        fi
    done
    test $((mask / 16)) = 0 || return 1
    printf '%s' "$names"
}

# A field's value as text, and back. Enumerated fields have names; the rest
# are integers.
boot_value_name() {
    case $1 in
        1)
            case $2 in
                1) printf '127.0.0.1' ;;
                2) printf '0.0.0.0' ;;
                *) return 1 ;;
            esac
            ;;
        5)
            case $2 in
                1) printf 'stdout' ;;
                2) printf 'stderr' ;;
                *) return 1 ;;
            esac
            ;;
        *) printf '%s' "$2" ;;
    esac
}

# The value as source text for generated Kofun, or 1 when the text is not a
# value the field can be written as.
boot_value_code() {
    case $1 in
        1)
            case $2 in
                127.0.0.1) printf 'bind_loopback()' ;;
                0.0.0.0) printf 'bind_any()' ;;
                *) return 1 ;;
            esac
            ;;
        5)
            case $2 in
                stdout) printf 'sink_stdout()' ;;
                stderr) printf 'sink_stderr()' ;;
                *) return 1 ;;
            esac
            ;;
        *)
            case $2 in
                ''|*[!0-9]*) return 1 ;;
            esac
            printf '%s' "$2"
            ;;
    esac
}

boot_value_hint() {
    case $1 in
        1) printf '127.0.0.1 or 0.0.0.0' ;;
        5) printf 'stdout or stderr' ;;
        *) printf 'a non-negative integer' ;;
    esac
}

boot_source_name() {
    case $1 in
        1) printf 'default' ;;
        2) printf 'pack' ;;
        3) printf 'override' ;;
        *) return 1 ;;
    esac
}

# The candidate nearest to a word by edit distance; the first on a tie.
#
#   boot_nearest WORD CANDIDATE...
boot_nearest() {
    word=$1
    shift
    printf '%s\n' "$@" | awk -v word="$word" '
        function distance(a, b,    i, j, la, lb, cost, d, best) {
            la = length(a); lb = length(b)
            for (i = 0; i <= la; i++) d[i, 0] = i
            for (j = 0; j <= lb; j++) d[0, j] = j
            for (i = 1; i <= la; i++) {
                for (j = 1; j <= lb; j++) {
                    cost = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
                    best = d[i - 1, j] + 1
                    if (d[i, j - 1] + 1 < best) best = d[i, j - 1] + 1
                    if (d[i - 1, j - 1] + cost < best) best = d[i - 1, j - 1] + cost
                    d[i, j] = best
                }
            }
            return d[la, lb]
        }
        {
            score = distance(word, $0)
            if (NR == 1 || score < lowest) { lowest = score; nearest = $0 }
        }
        END { print nearest }
    '
}
