# shellcheck shell=bash
# Terminal-only rendering for the tables the monitor recipes print.
#
# On a terminal, the first line of each block is bold and underlined — a shape,
# so it is told from the first row by more than weight — and every second line
# after it sits on a background band, padded to the terminal's width so the band
# runs across every column. A band and not dim text, because the operator is
# colourblind and a change of text weight or intensity is not enough contrast
# to follow a row across ten columns; a band is a change of luminance behind the
# whole line, and hue carries nothing. The band's colour is a bet on a dark
# theme, so RUNNER_ZEBRA overrides it: an SGR parameter list such as `48;5;254`
# for a light theme, or `none`. A blank line starts a new block. Off when stdout
# is not a terminal, so a pipe or a file gets plain text.
# Sourced by host/monitor/tools.sh and host/monitor/cost.sh.

zebra() {
    local band="${RUNNER_ZEBRA-48;5;237}" width
    if [ -t 1 ] && [ "$band" != none ]; then
        width=$(tput cols 2>/dev/null || echo 120)
        awk -v w="$width" -v b="$(printf '\033[1;4m')" -v z="$(printf '\033[%sm' "$band")" -v o="$(printf '\033[0m')" '
            /^[[:space:]]*$/ { n = 0; print; next }
            { n++ }
            n == 1     { print b $0 o; next }
            n % 2 == 1 { printf "%s%-" w "s%s\n", z, $0, o; next }
            { print }'
    elif [ -t 1 ]; then
        awk -v b="$(printf '\033[1;4m')" -v o="$(printf '\033[0m')" '
            /^[[:space:]]*$/ { n = 0; print; next }
            { n++ }
            n == 1 { print b $0 o; next }
            { print }'
    else
        cat
    fi
}
