# shellcheck shell=bash
# The verdict vocabulary every section of `just verify` speaks, in one file
# because two copies of `verdict` is two counters and a summary that reports
# one of them. Sourced by host/verify/verify.sh, which sources the sections after
# it: nothing here runs a probe. see docs/verify.md#the-verdict-vocabulary


# --- how a verdict reads ---
# Each check says which branch it took rather than printing what it saw and
# leaving a reader to match it against a legend — a `WRONG` on line 60 of 80
# scrolls past under the build output, and cron cannot read one at all.
#
#   [ ok ]  proved; nothing to do
#   [FAIL]  a mechanism is not doing its job — the line says which
#   [LOOK]  a state, not a defect: only the operator can rule on it
#
# The word and the column carry the meaning and the summary counts them;
# colour only repeats what is already there, which is why no check is
# distinguished by hue and why there is no green/red pair anywhere.

verdict_ok=0; verdict_fail=0; verdict_look=0
fail_lines=""; look_lines=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_fail=$(printf '\033[1;31m'); c_look=$(printf '\033[1;34m'); c_off=$(printf '\033[0m')
else c_fail=""; c_look=""; c_off=""; fi

# What each label last answered, so a section can skip a probe whose
# precondition another section already reported on — session.sh asks whether
# `session login` failed. Keyed on the label, which the summary repeats and
# which is therefore the stable name.

declare -A verdict_state


# --- verdict ---
# verdict <state> <label> <detail...>. The label is what the summary
# repeats, so it stays short and stable; the detail is the sentence someone
# acts on. Anything that is not `ok` or `LOOK` counts as a failure, so a
# typo in a state cannot silently become a pass.

verdict() {
    local st="$1" label="$2" line; shift 2
    # shellcheck disable=SC2034  # read by session.sh, sourced after this
    verdict_state["$label"]="$st"

    case "$st" in
        ok)   verdict_ok=$((verdict_ok + 1))
              printf '  [ ok ] %-15s %s\n' "$label" "$*" ;;
        LOOK) verdict_look=$((verdict_look + 1))
              line=$(printf '  [LOOK] %-15s %s' "$label" "$*")
              look_lines="$look_lines$line"$'\n'
              tinted "$line" ;;
        *)    verdict_fail=$((verdict_fail + 1))
              line=$(printf '  [FAIL] %-15s %s' "$label" "$*")
              fail_lines="$fail_lines$line"$'\n'
              tinted "$line" ;;
    esac
}


# --- tinted ---
# Prints a verdict line with only its tag coloured — the tag is the signal,
# the rest is prose — so the summary can repeat the same stored line and
# colour it the same way. Lines are stored plain.

tinted() {
    case "$1" in
        "  [LOOK]"*) printf '  %s[LOOK]%s%s\n' "$c_look" "$c_off" "${1#  \[LOOK\]}" ;;
        "  [FAIL]"*) printf '  %s[FAIL]%s%s\n' "$c_fail" "$c_off" "${1#  \[FAIL\]}" ;;
        *)           printf '%s\n' "$1" ;;
    esac
}


# --- verdicts_from ---
# Checks that run inside the container print `state|label|detail` and come
# back through this, so a verdict from the image is counted exactly like a
# host one. Fed by redirection and never by a pipe: a pipe puts the loop in a
# subshell, where the counters increment and nothing reads them.
# see docs/verify.md#verdicts-from-inside-the-container

verdicts_from() {
    local st label detail
    while IFS='|' read -r st label detail; do
        [ -n "$st" ] || continue
        verdict "$st" "$label" "$(printf '%s' "$detail" | tr -d '\r')"
    done
}


# --- sees ---
# The one thing a human must judge that no probe can: a session's own prose
# answer. `sees <text> <pattern>` is the grep those checks agree on —
# case-insensitive, so "Refused" and "refused" are one answer.

sees() { printf '%s' "$1" | grep -qi -- "$2"; }


# --- need, spare ---
# Host tool present → ok, absent → FAIL with the sentence naming what stops
# working. `spare` is the same question where absence is not a failure: those
# tools are optional by design, and the line says what stops working without
# them so the operator can decide whether it matters here.

need() {
    if command -v "$1" >/dev/null 2>&1; then verdict ok "$1" "present"
    else verdict FAIL "$1" "MISSING — $2"; fi
}

spare() {
    if command -v "$1" >/dev/null 2>&1; then verdict ok "$1" "present"
    else verdict LOOK "$1" "absent — $2"; fi
}
