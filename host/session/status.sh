#!/usr/bin/env bash
# Is everything right — the live facts, and then the screen.
#
# Runs on the host. No arguments from `just status`; `just listen` passes
# `--part` and what goes with it, and they reach status.py untouched.
#
# This half answers only what a shell owns: whether a container is up, what the
# schedule says, when the next wake-up may start, how the last run ended. Every
# one of those already has an implementation in host/lib/ that `run`, `chat` and
# `listen` share, and a second spelling of any of them is two recipes describing
# different machines. They go to host/session/status.py as `key: value` lines,
# and it composes the screen and asks the remaining owners itself.
# see docs/sessions.md#where-just-status-gets-its-answers
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh

if [ "$RUNNER_IS_DEPLOYED" = no ]; then
    forward_to_deployed status
fi

host/lib/docker-up.sh || exit $?
source host/lib/session-lock.sh
source host/lib/run-record.sh


# --- is a session running ---
# The container is the evidence, and the lock deliberately is not: there is no
# way to test a flock without taking it, and a `just run` starting in that
# instant would find it held and stand down.
# see docs/sessions.md#where-just-status-gets-its-answers

facts() {
    local c started idle sched state daemon left from governs due why

    c=$(session_container)
    if [ -n "$c" ]; then
        printf 'running: yes\n'
        printf 'kind: %s\n' "$(session_kind)"
        printf 'container: %s\n' "${c%%$'\t'*}"
        started=$(session_started || echo "")
        [ -n "$started" ] && printf 'started: %s\n' "$started"
    else
        printf 'running: no\n'
        printf 'idle: %s\n' "$(session_idle_minutes)"
        # A shell or a probe is not a session and holds no lock, but "nothing
        # is running" while you are sitting in a container is misleading.
        printf 'other: %s\n' "$(service_container)"
        # The wait in force and the sentence that explains it, from the
        # function `run` stands a wake-up down on. Only when nothing is
        # running: while a session is up, the number that governs the next one
        # has not been written yet — it is decided when this one ends.
        { read -r left from governs due; read -r why; } <<<"$(wake_state \
            "$(run_record_field asked_wake_after)" "$(run_record_field wake_after)" \
            "$(run_record_field ended)" "$(chat_ended_epoch)")"
        printf 'wake_left: %s\nwake_from: %s\nwake_governs: %s\nwake_due: %s\nwake_why: %s\n' \
            "$left" "$from" "$governs" "$due" "$why"
    fi

    # The bounds, whether or not one is running: they are what a session may
    # ask for, and the screen says so beside the wait it would otherwise get.
    printf 'wake_default: %s\n' "$(wake_default)"
    printf 'wake_min: %s\n' "$(wake_min)"
    printf 'wake_max: %s\n' "$(wake_max)"
    if wake_armed; then printf 'wake_armed: yes\n'; else printf 'wake_armed: no\n'; fi

    # How the last unattended run ended, and when the last session of any kind
    # did — the second is what tells the mirror's judgement whether a run it
    # was owed had anything to dispatch it.
    printf 'last_run: %s\n' "$(run_record_verdict "$([ -n "$c" ] && echo yes || echo no)")"
    printf 'session_ended: %s\n' "$(session_ended_epoch || echo "")"

    # Asked of `just schedule --state` rather than read out of the crontab,
    # because what counts as paused is a prefix that recipe writes; a missing
    # answer is not "nothing scheduled".  see docs/schedule.md
    sched=$(just schedule --state 2>&1)
    state=$(printf '%s\n' "$sched" | sed -n 's/^state: //p')
    daemon=$(printf '%s\n' "$sched" | sed -n 's/^daemon: //p')
    printf 'scheduling: %s\n' "${state:-unknown}"
    printf 'daemon: %s\n' "${daemon:-unknown}"
    # How often the line fires, which is how long a wake-up that was due has to
    # have happened in. Derived by the recipe that owns the expression, and
    # `unknown` for a line this repository did not write.
    printf 'cron_every: %s\n' "$(printf '%s\n' "$sched" | sed -n 's/^every: //p')"

    # Read the way session-env.sh reads it: exactly `true` arms the guard, and
    # one comparison made the same way on both sides is the whole of it.
    if [ "${ACCOUNT_BUDGET_GUARD:-}" = true ]; then
        printf 'budget_guard: on\n'
    else
        printf 'budget_guard: off\n'
    fi
}

facts | host/session/status.py "$@"
