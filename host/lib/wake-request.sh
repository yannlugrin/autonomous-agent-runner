# shellcheck shell=bash
# When the next unattended session may start: the default wait, the bounds a
# session's own request is held to, and the arithmetic over the two stamps.
#
# This is the ONE place the cadence is decided. It used to be split — a
# `--cooldown` on the crontab line for the default, `.env` for the bounds — and
# the split had a trap in it: the expression this repository recommends is
# `* * * * *`, whose cadence is carried entirely by the flag, so a line written
# without one ran a session a minute. A default that lives in `.env` with a
# value in the code behind it cannot be forgotten.
#
# Sourced by host/lib/run-record.sh, which writes the decision into the record;
# by host/session/run.sh, which enforces it; and by host/lib/session-env.sh,
# which tells the container what is armed. Never executed.
#
# Nothing here reads a file. The record belongs to run-record.sh and the stamps
# to session-lock.sh, and both hand their numbers in — which is what lets the
# verify probe prove the sentence, the bounds and both clocks with strings and
# epochs rather than with planted files.
#
# This is the one mechanism where the agent's own output changes what the
# runner does with nobody reading it in between, so the two bounds are the
# whole of the containment: the floor guards the operator's account, the
# ceiling guards against an agent that goes quiet and is never missed.
# see docs/schedule.md#a-session-asks-for-its-own-next-wake-up


# --- what a session says ---
# One sentence of the closing message, and the number is the only part that
# varies. Prose rather than a marker because the closing message is prose: a
# token would be the agent writing for a parser, and the parser would then be
# the thing that had to be described to it.
#
# A request is a sentence, so it has to START one — the beginning of a line, or
# after a full stop — and the capital carries that distinction. `Done. Wake me
# up in 30 minutes.` is an ask; `I won't ask you to wake me up in 30 minutes` is
# not, and neither is a line quoting the sentence after a colon. That is not
# pedantry: the session most likely to write about this feature is the one that
# has just found it and is reasoning about whether to use it.
#
# Minutes only, and at most six digits: everything below clamps, but the
# arithmetic runs before the clamp does. The last sentence in the message wins,
# as the last assignment in the record does — it is the session's final word.

WAKE_SENTENCE='(^|[.!?] )Wake me up in [0-9]{1,6} minutes?'

wake_asked() {
    printf '%s\n' "${1:-}" \
        | grep -oE "$WAKE_SENTENCE" 2>/dev/null \
        | tail -1 \
        | grep -oE '[0-9]{1,6}' 2>/dev/null \
        || true
}


# --- what the operator allows ---
# Exactly `true` arms the REQUEST, nothing else including a plausible `yes` —
# the same vocabulary as ACCOUNT_BUDGET_GUARD and for the same reason: compose
# passes the raw value into the container and a session reads it back, so one
# comparison made the same way on both sides is the whole of it.
# see docs/budget.md#exactly-true-arms-the-guard
#
# Arming decides ONLY whether a session may move the number. The default below,
# the floor and the clock apply either way — a flag about who chooses must not
# also change what is chosen, or turning it on changes the cadence of an agent
# that never asks.

# The wait when a session asks for nothing, which is most sessions and every
# session on an installation that never arms the request. It has a value in the
# code because there is no safe way to have none: unset would mean the cron
# expression alone is the clock, and that expression is `* * * * *` here.
#
# An explicit `0` is somebody's decision and means the expression IS the clock.
# Anything that is not a number is a typo, and a typo must not silently become
# a session a minute — so it falls back to the default rather than to 0.
WAKE_DEFAULT_MINUTES=60

wake_default() {
    local n="${AGENT_WAKE_DEFAULT:-}"
    case "$n" in ''|*[!0-9]*) n="$WAKE_DEFAULT_MINUTES" ;; esac
    printf '%s\n' "$n"
}

# The floor, which does two jobs: the least a request may ask for, and how long
# after a conversation nothing starts. It applies whether or not the request is
# armed, because the second job has nothing to do with the first.
#
# Unset is the default wait, not zero. That makes an installation that sets
# only <NAME>_WAKE_DEFAULT behave exactly as a `--cooldown` of the same number
# always did, conversations included — which is the setting to start from.
wake_min() {
    local n="${AGENT_WAKE_MIN:-}"
    case "$n" in ''|*[!0-9]*) n="$(wake_default)" ;; esac
    printf '%s\n' "$n"
}

# The ceiling a request is clamped to. Six hours unless set: longer than any
# legitimate "nothing worth doing right now", and short enough that an agent
# gone quiet is noticed inside a working day. Nothing anywhere reports a session
# that never ran — a wedge alarm needs one to have started — which is the reason
# there is a number here at all rather than an unbounded sleep.
#
# A typo falls back to it rather than disarming the request, as the default wait
# does and for the same reason: a mistyped number must not silently turn off the
# mechanism it was meant to configure. `0` is a typo here — a ceiling of zero
# says nothing anyone means — where `0` on the default wait is a real choice.
WAKE_MAX_MINUTES=360

wake_max() {
    local n="${AGENT_WAKE_MAX:-}"
    case "$n" in ''|*[!0-9]*) n="$WAKE_MAX_MINUTES" ;; esac
    [ "$n" -gt 0 ] || n="$WAKE_MAX_MINUTES"
    printf '%s\n' "$n"
}

# Off, a request is read and recorded and governs nothing: every wake-up waits
# the default. That is the direction this has to fail in — a misconfiguration
# that stops sessions is worse than one that goes on running them at the
# operator's own cadence.
# The bounds must contain the cadence: MIN <= DEFAULT <= MAX. Not arithmetic
# hygiene — it is what makes the mechanism describable to the agent in one
# sentence. Outside it, a session reads "I may ask for 15 to 360" and "silence
# gives me 600" and cannot express the wait it already gets; with the floor
# above the cadence, asking at all can only ever make it slower. Nobody is
# there to explain that, so it is refused rather than reported.
#
# The cost is that the conversation floor can no longer exceed the cadence,
# because the floor does both jobs. If that is ever wanted, the fix is to split
# the floor in two, not to loosen this.
# see docs/schedule.md#the-bounds-must-contain-the-cadence
wake_armed() {
    [ "${AGENT_WAKE_REQUEST:-}" = true ] || return 1
    [ "$(wake_min)" -le "$(wake_default)" ] || return 1
    [ "$(wake_default)" -le "$(wake_max)" ] || return 1
}

# Why it is not armed, in one clause, for `just verify` — which is where a
# misconfiguration has to be said, because a state that persists cannot be said
# on the running path without saying it 1440 times a day. Empty when armed.
wake_disarmed_why() {
    if [ -z "${AGENT_WAKE_REQUEST:-}" ]; then
        printf 'not set\n'
        return
    fi
    if [ "$AGENT_WAKE_REQUEST" != true ]; then
        printf '%s is not exactly true\n' "$AGENT_WAKE_REQUEST"
        return
    fi
    # Which end, and what to change. Both say the same thing about the agent,
    # because it is the same defect from either side: the wait it gets in
    # silence is one it could never ask for.
    if [ "$(wake_default)" -gt "$(wake_max)" ]; then
        printf 'the cadence (%sm) is above the ceiling (%sm), so a session could never ask for the wait it already gets — raise _WAKE_MAX to %s or more\n' \
            "$(wake_default)" "$(wake_max)" "$(wake_default)"
        return
    fi
    if [ "$(wake_min)" -gt "$(wake_default)" ]; then
        printf 'the floor (%sm) is above the cadence (%sm), so a session could never ask for the wait it already gets — lower _WAKE_MIN to %s or less\n' \
            "$(wake_min)" "$(wake_default)" "$(wake_default)"
    fi
}


# --- the clamp ---
# Both directions, and never a refusal. A request outside the bounds that was
# refused would fall back to starting now, and for the half of the range that
# asks for MORE time that is the wrong direction to fail in.

wake_clamp() {
    local n="${1:-}" lo hi
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    hi=$(wake_max)
    lo=$(wake_min)
    if [ "$n" -lt "$lo" ]; then n=$lo; fi
    if [ "$n" -gt "$hi" ]; then n=$hi; fi
    printf '%s\n' "$n"
}


# --- when the next one may start ---
# wake_due <minutes> <last unattended end> <last conversation end>, the two
# stamps as epochs, printing the minutes still to wait and which of the two
# decided — `0 none` when a session may start now. Which one is said as well as
# how long because the line a person reads is otherwise a wait attributed to
# the number that did not produce it.
#
# The clock is the last UNATTENDED session's end and not the last session's. A
# conversation is the operator spending their own time, and letting one push
# the schedule back by a whole cycle is how an afternoon of talking silently
# costs the agent its day. What a conversation moves is the FLOOR —
# nothing starts on top of one that has just ended — and only the floor, so a
# request for three hours still lands three hours after the session that made
# it however many conversations fall inside them.
#
# No stamp reads as "long ago", like the record session-lock.sh keeps and for
# the same reason: the first wake-up after an install or a cleared cache has to
# be allowed to happen. A stamp in the FUTURE means the clock moved, and the
# answer there is to run rather than to stall every session until real time
# catches up.

wake_due() {
    local minutes="${1:-0}" auto="${2:-}" chat="${3:-}" now due=0 floor from=none
    now=$(date +%s)
    case "$minutes" in ''|*[!0-9]*) minutes=0 ;; esac

    case "$auto" in ''|*[!0-9]*) auto="" ;; esac
    if [ -n "$auto" ] && [ "$auto" -le "$now" ] && [ "$minutes" -gt 0 ]; then
        due=$(( auto + minutes * 60 ))
        from=session
    fi

    case "$chat" in ''|*[!0-9]*) chat="" ;; esac
    if [ -n "$chat" ] && [ "$chat" -le "$now" ]; then
        floor=$(( chat + $(wake_min) * 60 ))
        if [ "$floor" -gt "$due" ]; then due=$floor; from=chat; fi
    fi

    if [ "$due" -le "$now" ]; then
        printf '0 none\n'
    else
        # Rounded up, so a wake-up 30 seconds early says 1 rather than 0 and
        # then refuses.
        printf '%s %s\n' "$(( (due - now + 59) / 60 ))" "$from"
    fi
}


# --- what the container is told ---
# wake_report <asked_wake_after> <wake_after>, the record's two fields, printing
# the six unprefixed `KEY=VALUE` lines a session sees. Here rather than in
# session-env.sh so that a probe can prove them with two strings, and so that
# what is reported and what is enforced read the same numbers.
#
# **Every one is always printed, and `none` is a value.** A variable that is
# absent, or present and empty, leaves a session unable to tell an intended
# state from a line that broke — and the whole point of this channel is that a
# session never has to interpret a sentinel. So `none` means there is genuinely
# no such number, empty means something here failed, and the two can be told
# apart. `unknown` is deliberately NOT reused for this: the instants use it for
# "could not tell", and this is "there is nothing to tell".
#
# Only MAX and ASKED can say `none` — MAX because an unarmed installation has
# no ceiling, ASKED because a session may genuinely have asked for nothing.
# DEFAULT, MIN and GRANTED are always numbers, because a wake-up always waits
# something: asking for nothing is accepting the default, not declining to be
# woken. GRANTED mirrors what run.sh enforces — the RECORDED wake where there
# was an honoured ask, since that is the number in force, and the live default
# where there was not.

wake_report() {
    local asked="${1:-}" wake="${2:-}" granted
    case "$asked" in ''|*[!0-9]*) asked=none ;; esac
    case "$wake"  in ''|*[!0-9]*) wake="" ;; esac

    printf 'WAKE_DEFAULT=%s\n' "$(wake_default)"
    printf 'WAKE_MIN=%s\n' "$(wake_min)"
    if wake_armed; then
        printf 'WAKE_REQUEST=true\n'
        printf 'WAKE_MAX=%s\n' "$(wake_max)"
    else
        # `none` rather than the number: there is no ceiling on something that
        # is not read, and a session told one would be reading the setting
        # rather than the mechanism.
        printf 'WAKE_REQUEST=false\n'
        printf 'WAKE_MAX=none\n'
    fi

    granted="$(wake_default)"
    if wake_armed && [ "$asked" != none ] && [ -n "$wake" ]; then granted="$wake"; fi

    printf 'WAKE_ASKED=%s\n' "$asked"
    printf 'WAKE_GRANTED=%s\n' "$granted"
}
