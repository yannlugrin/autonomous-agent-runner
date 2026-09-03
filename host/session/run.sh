#!/usr/bin/env bash
# One unattended session — what cron runs, and what `just run` starts by hand.
#
# Runs on the host. The flags are declared on the recipe in the justfile and
# arrive as environment variables: force, listen, wait, ignore_budget,
# cooldown.
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh


# --- what was asked for ---
# `parallel` is set only where the lock was actually held and stepped past:
# --force on a free lock starts nothing in parallel, so it must not claim to.
# --ignore-budget stays separate from --force because they answer different
# refusals, and one flag meaning both would override the one you were not
# thinking about.

parallel=false

if [ "$force" = yes ] && [ "$wait" = yes ]; then
    echo "--wait and --force contradict each other: one queues behind the running" >&2
    echo "session, the other starts a second one beside it." >&2
    exit 2
fi


# --- what wakes the operator ---
# Nobody is in an unattended run, so a failure that only reaches the log is a
# failure nobody hears about. notify.sh is silent on a terminal, so a run typed
# by hand is unchanged.
#
# 0 worked, 2 is a usage error only a terminal can produce, and 75 is the
# routine stand-down — cooldown, held lock, over budget — dozens of times a day,
# so toasting it would teach anyone to dismiss the toast. Everything else is
# worth being pulled away for.  see docs/sessions.md#what-wakes-the-operator

alert() { host/schedule/notify.sh "$@" || true; }

trap 'rc=$?; case $rc in 0|2|75) ;; *) alert "the unattended session exited $rc — see $RUNNER_RUN_LOG" ;; esac' EXIT


# --- always the live runner ---
# And the live runner is the deployed checkout: see host/lib/deployed.sh. There
# is no `--build` here — an unattended session on an unproven image is a risk
# taken for nothing. `just shell --build` looks inside a candidate, `just
# verify` proves it.  see docs/sessions.md#the-build-flag-left-run-and-chat

if [ "$RUNNER_IS_DEPLOYED" = no ]; then
    typed=()
    typed_flag --force "$force"
    typed_flag --listen "$listen"
    typed_flag --wait "$wait"
    typed_flag --ignore-budget "$ignore_budget"
    [ "$cooldown" -gt 0 ] && typed+=(--cooldown "$cooldown")
    forward_to_deployed run ${typed[@]+"${typed[@]}"}
fi


# --- the cooldown ---
# First, because it is the one check that is pure arithmetic on this side: under
# `* * * * * just run --cooldown 15` most invocations are this and nothing else,
# and they should cost a file read. Silent when nothing is watching — a log that
# is all skips is one nobody reads on the day it holds something.

if [ "$cooldown" -gt 0 ]; then
    source host/lib/session-lock.sh
    idle=$(session_idle_minutes)
    if [ "$idle" -lt "$cooldown" ]; then
        [ -t 1 ] && echo "The last session ended ${idle}m ago; --cooldown ${cooldown} asks for ${cooldown}m."
        exit 75
    fi
fi


# --- the page's heartbeat ---
# The only one there is, and here rather than further down because everything
# below can exit — and a cooldown minute, a dead daemon and a held lock are
# exactly the states worth seeing from a phone. Its own floor makes all but one
# call in ten cost a file read, which is what makes `just run` the publisher
# rather than a second crontab line.  see docs/archive.md

host/archive/publish-status.sh || true




# --- the lock ---

host/lib/docker-up.sh --image "${RUNNER_IMAGE:-$RUNNER_IMAGE_DEPLOYED}" || exit $?
source host/lib/session-lock.sh
lock_open

if ! lock_try; then
    lock_why

    # A session that hangs is the one failure nothing else reports: it never
    # reaches the end of this script, so it never trips the trap above, and
    # every wake-up afterwards lands here and exits 75 in silence — exactly what
    # a healthy cooldown looks like.
    #
    # `auto` only, because a conversation legitimately runs for hours and the
    # operator is sitting in it. An explicit 0 turns the alarm off, which is
    # somebody's decision; anything else that is not a number is a typo, and a
    # typo must not silently disable the only report a wedge ever produces.
    # see docs/sessions.md#the-wedge-alarm-and-its-threshold
    wedge="${RUNNER_WEDGE_MINUTES:-120}"
    case "$wedge" in *[!0-9]*) wedge=120 ;; esac
    if [ "$wedge" -gt 0 ] && [ "$(session_kind 2>/dev/null)" = auto ]; then
        began=$(session_started 2>/dev/null || echo "")
        case "$began" in ''|*[!0-9]*) began="" ;; esac
        if [ -n "$began" ]; then
            up=$(( ( $(date +%s) - began ) / 60 ))
            if [ "$up" -ge "$wedge" ] \
               && [ "$(cat "$RUNNER_WEDGE_NOTIFIED" 2>/dev/null)" != "$began" ]; then
                # Stamped before the alert rather than after, so a notifier
                # that hangs cannot become a toast a minute for as long as the
                # wedge lasts.
                mkdir -p "$(dirname "$RUNNER_WEDGE_NOTIFIED")" 2>/dev/null || true
                printf '%s\n' "$began" > "$RUNNER_WEDGE_NOTIFIED" 2>/dev/null || true
                alert "the unattended session has been running ${up}m — longer than any that ever finished. 'just run --force' starts one beside it."
            fi
        fi
    fi

    if [ "$wait" = yes ]; then
        lock_wait
    elif [ "$force" = no ]; then
        # 75, because that is what cron has always read as "skipped an hour"
        # rather than "the session failed". Refusing is the default precisely
        # because cron is the usual caller: an hour that queued behind a long
        # session would still be running when the next hour came round.
        echo
        echo "Nothing was started. --wait queues behind it; --force starts one beside it."
        exit 75
    else
        # A prompt is the whole point of the flag, so no terminal means no
        # forcing: a --force wired into a script would quietly become the
        # normal path and the lock would be decoration.
        if [ ! -t 0 ]; then
            echo "--force asks before overriding the lock, and there is no terminal to ask on." >&2
            exit 2
        fi
        echo
        echo "Forcing does not take the lock — a flock cannot be stolen. It starts a"
        echo "SECOND session beside the first, both writing one checkout and one"
        echo "transcript directory. Worth it only when the first is wedged."
        printf 'Start one anyway? [y/N] '
        read -r reply
        case "$reply" in
            [yY]*) parallel=true
                   echo "Running unlocked. This session holds nothing and blocks nothing." ;;
            *) echo "Nothing was started."; exit 75 ;;
        esac
    fi
fi


# --- the budget gate ---
# What the session is told about its own cadence, and what the gate sees — one
# reading, both in host/lib/session-env.sh; see docs/budget.md. After the lock
# and the cooldown, so a wake-up that stands down on either never pays for it;
# before --listen and the timestamp, so a run refused here has started no viewer
# and stamped nothing.
#
# 75 whichever way it went, because both are an hour that started no session.
# Over budget is routine and says so only on a terminal; a gate that could not
# tell has already written its one line to stderr, where cron finds it.

source host/lib/session-env.sh

if [ "$ignore_budget" = yes ]; then
    [ -t 1 ] && echo "Ignoring the budget: $BUDGET_VERDICT"
elif [ "$BUDGET_STATUS" -ne 0 ]; then
    if [ -t 1 ]; then
        echo "$BUDGET_VERDICT"
        echo "Nothing was started. --ignore-budget starts one anyway."
    fi
    exit 75
fi


# --- what the session is started with ---
# `-p`, deliberately. Nobody is here, so an interactive session would orient
# itself and then sit at a prompt forever: the container never exits,
# SessionEnd never fires, nothing is backed up or collected.
#
# The opening message says plainly that it is not the operator. It arrives
# through the same channel their messages do, and that channel is the one the
# agent treats as direction, so the sender comes first — rule 1 rests on it. A
# forced session is told it is not alone in its system prompt rather than here:
# see image/claude-session.py.

other=()
if [ "$parallel" = true ]; then
    other=(-e "${AGENT_PREFIX}_OTHER_SESSION_STARTED_AT=$(date -u -d "@$(session_started)" +%FT%TZ 2>/dev/null || echo unknown)")
fi

prompt="$RUNNER_SAYS Run the session-start routine in CLAUDE.md. Then do whatever you judge worth doing, write it down, commit, and finish. Deciding that nothing is worth doing and closing is a good session. Nobody is here to answer: if you need the operator, open an issue rather than waiting."


# --- the viewer ---
# --listen starts the viewer itself, listen.sh with its flags as variables, rather than growing a second copy of the
# renderer — with --wait, which waits for a transcript newer than this moment,
# since the newest one right now belongs to the previous session.
#
# --force is the one case this gets wrong: --wait prefers a session already
# running, and under --force there is one, so the viewer follows the session
# this run starts beside. Only the view is wrong.
#
# A job in its own process group, so stopping it at the end signals the viewer
# and not this shell. --quiet because stopping it means SIGINT, and `just`
# prints its own interrupt line over the last of the transcript otherwise.
# </dev/null for two reasons at once: a background process that reads the
# terminal is stopped by SIGTTIN, and it is also what tells `listen` there is no
# keyboard to offer `q` on.
# see docs/sessions.md#the-viewer-run---listen-starts

view=""
if [ "$listen" = yes ]; then
    set -m
    all=no wait=yes live=no summary=no n=20 host/session/listen.sh </dev/null &
    view=$(jobs -p %%)
    set +m
fi


# --- the session ---
# Stamped before the session, because the summary afterwards takes the newest
# transcript in the volume: a container that died during bootstrap writes none
# and leaves the previous session's as the newest.

started=$(date +%s)

if [ -n "$view" ]; then
    # The view already shows everything the session says, so its own output is
    # held back — and printed after all if it failed, which is the case where
    # it is the only place the reason appears.
    session_log=$(mktemp)
    docker compose run --rm --name "$RUNNER_SESSION_NAME-$$" \
        "${SESSION_ENV[@]}" ${other[@]+"${other[@]}"} -w "$AGENT_REPO_DIR" agent claude-session -p "$prompt" >"$session_log" 2>&1
else
    docker compose run --rm --name "$RUNNER_SESSION_NAME-$$" \
        "${SESSION_ENV[@]}" ${other[@]+"${other[@]}"} -w "$AGENT_REPO_DIR" agent claude-session -p "$prompt"
fi
status=$?

if [ -n "$view" ]; then
    # A moment before stopping it: the session writes its closing message
    # immediately before exiting, and killing the tail in the same instant
    # loses the end of what you asked to watch.
    sleep 2
    kill -INT -"$view" 2>/dev/null
    wait "$view" 2>/dev/null
    if [ "$status" -ne 0 ]; then
        echo
        echo "The session exited $status. Its own output:"
        cat "$session_log"
    fi
    rm -f "$session_log"
fi


# --- the bookkeeping that follows it ---
# The end is recorded before the archiving, because what --cooldown counts from
# is the session ending — and whatever the status, because a session that failed
# still ran.
#
# --push, not a bare collect: a commit that only ever lands in the local archive
# checkout is a second copy on the same disk as the volume it copies. The mirror
# is asked for straight afterwards because GitHub keeps its schedule badly.
# see docs/archive.md

session_ended

just collect --push || {
    echo "COLLECT_FAILED — the transcript may not have reached the archive. It is still in the volume; run 'just collect --push' by hand." >&2
    alert "COLLECT_FAILED — the transcript is still only in the volume. Run 'just collect --push'."
}

host/archive/dispatch-mirror.sh || {
    echo "MIRROR_NOT_DISPATCHED — the archive's mirror was not asked to run; its schedule is the only trigger left." >&2
    alert "MIRROR_NOT_DISPATCHED — the archive's mirror was not asked to run."
}


# --- the last word ---
# --force on the publish, skipping the floor: the page saying a session is
# running ten minutes after it stopped is the staleness anybody would notice.
# After the collection, so the count held back for review is this session's.
#
# The summary is last, after the archiving it describes, and never allowed to
# reach the exit status — a summary that could not be produced is not a session
# that failed.

host/archive/publish-status.sh --now || true

echo
host/session/session-stats.py --since "$started" || true

exit $status
