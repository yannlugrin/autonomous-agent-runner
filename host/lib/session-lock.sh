# shellcheck shell=bash
# The session lock, and everything that answers "is a session running".
#
# Sourced by `just run` and `just chat`, never executed: the lock lives on an
# open file descriptor and a descriptor belongs to the process that opened it,
# so a child would release it the moment it exited.
#
# One session at a time. The hourly unattended run and a conversation the
# operator starts drive the same container against the same volume, and two at
# once means two Claude Code sessions writing one checkout and one transcript
# directory. It binds whoever starts a session, not merely whoever cron starts.
#
# There is no stale lock: flock holds on the inode through an open descriptor,
# so a held lock means a live holder. --force does not steal it — it runs a
# second session holding nothing — and deleting the lock file leaves two
# processes each holding "the" lock.
# see docs/sessions.md#there-is-no-stale-lock

# Required, never defaulted: a shared fallback would be two agents on one lock,
# or one agent whose recipes lock /tmp/<name>-session.lock while a script that
# missed the export locks the fallback — two locks, neither excluding the other.
RUNNER_LOCK="${RUNNER_LOCK:?not set — run this through 'just', which derives it from the agent name}"

# When a session last ended, which the lock cannot answer: it records attempts,
# not outcomes — `lock_open` opens the file before `lock_try` decides. Under
# ~/.cache/<agent> rather than beside the lock in /tmp, because a cooldown that
# does not survive a reboot lets a session start immediately after every
# restart.  see docs/sessions.md#the-lock-records-attempts-not-outcomes
RUNNER_LAST_SESSION_ENDED_AT="${RUNNER_LAST_SESSION_ENDED_AT:?not set — run this through 'just', which derives it from the agent name}"


# Descriptor 9 plainly rather than through a variable: `exec` cannot take the
# number from one without an eval, and an eval around the one line that
# establishes the boundary is not worth the flexibility.
lock_open() { exec 9>"$RUNNER_LOCK"; }

session_ended() {
    mkdir -p "$(dirname "$RUNNER_LAST_SESSION_ENDED_AT")" 2>/dev/null || return 0
    date +%s > "$RUNNER_LAST_SESSION_ENDED_AT" 2>/dev/null || true
}

# Minutes since that moment. No record reads as "long ago", because the first
# run after an install or a reboot has to be allowed to happen; a record in the
# future means the clock moved, and running once and saying so beats stalling
# every session until real time catches up.
session_idle_minutes() {
    local last now
    last=$(cat "$RUNNER_LAST_SESSION_ENDED_AT" 2>/dev/null) || last=""
    case "$last" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
    now=$(date +%s)
    if [ "$last" -gt "$now" ]; then
        echo "The record of the last session is in the future. Treating it as stale." >&2
        echo 999999
        return 0
    fi
    echo $(( (now - last) / 60 ))
}

# The same moment as an ISO-8601 UTC instant, for the container to be told.
# Here rather than beside its reader because this file is the one place that
# knows the format of that record. A future record reads as no record: there it
# means "run now", here "say nothing", and both decline to pretend.
session_ended_at() {
    local last
    last=$(cat "$RUNNER_LAST_SESSION_ENDED_AT" 2>/dev/null) || last=""
    case "$last" in ''|*[!0-9]*) return 1 ;; esac
    [ "$last" -le "$(date +%s)" ] || return 1
    date -u -d "@$last" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}


# Which session the last conversation was. `claude --continue` resumes the most
# recent session in the checkout, usually the hourly unattended run — so `chat`
# decides the id itself with --session-id, writes it here, and `--continue`
# asks for that one by name. Recorded when the session starts, not when it
# ends: a conversation that died in its first minute is one worth resuming.
# see docs/sessions.md#which-conversation---continue-resumes
RUNNER_LAST_CHAT_ID="${RUNNER_LAST_CHAT_ID:?not set — run this through 'just', which derives it from the agent name}"

chat_started() {
    mkdir -p "$(dirname "$RUNNER_LAST_CHAT_ID")" 2>/dev/null || return 0
    printf '%s\n' "$1" > "$RUNNER_LAST_CHAT_ID" 2>/dev/null || true
}

# When the operator last spoke, written at the end of a conversation rather
# than at its start: the id above is for resuming something that may have died
# in its first minute, this is for "how long since anyone talked to me", which
# only a finished conversation answers.
RUNNER_LAST_CHAT_ENDED_AT="${RUNNER_LAST_CHAT_ENDED_AT:?not set — run this through 'just', which derives it from the agent name}"

chat_ended() {
    mkdir -p "$(dirname "$RUNNER_LAST_CHAT_ENDED_AT")" 2>/dev/null || return 0
    date +%s > "$RUNNER_LAST_CHAT_ENDED_AT" 2>/dev/null || true
}

# The same instant as ISO-8601 UTC, for the container to be told. A record in
# the future is treated as no record, as with the session stamp above.
chat_ended_at() {
    local last
    last=$(cat "$RUNNER_LAST_CHAT_ENDED_AT" 2>/dev/null) || last=""
    case "$last" in ''|*[!0-9]*) return 1 ;; esac
    [ "$last" -le "$(date +%s)" ] || return 1
    date -u -d "@$last" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# The id, or nothing. Shape-checked rather than trusted: it is handed to claude
# as the session to resume, so anything malformed has to read as "no record" —
# which starts a fresh conversation and says so — rather than as an id that
# fails in claude's words instead of ours.
last_chat() {
    local id
    id=$(cat "$RUNNER_LAST_CHAT_ID" 2>/dev/null) || return 1
    [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || return 1
    printf '%s\n' "$id"
}

lock_try() { flock -n 9; }


# What a session's container is called, and everything asking whether a session
# is running filters on it. The name is the whole mechanism, because compose
# calls every one-off container <project>-<service>-run-<hash> whatever command
# it was given. $$ is added by the caller, so two sessions under --force do not
# collide.  see docs/sessions.md#naming-a-sessions-container
RUNNER_SESSION_NAME="${RUNNER_SESSION_NAME:-${COMPOSE_PROJECT_NAME:?not set — run this through 'just', which derives it from the agent name}-session}"

# The container a session runs in, if one is up.
session_container() {
    docker ps --filter "name=$RUNNER_SESSION_NAME" \
        --format '{{.Names}}\t{{.Status}}' 2>/dev/null | head -1
}

# The same container by id. Its own function because the filter is one string
# three callers must spell the same: a typo in a copy of it does not fail, it
# answers "nothing is running".
session_id() {
    docker ps --filter "name=$RUNNER_SESSION_NAME" \
        --format '{{.ID}}' 2>/dev/null | head -1
}

# Anything else compose is running on the service: a shell, a verify probe, a
# container started by hand. None takes the lock, but "nothing is running"
# while you are sitting in a container is a misleading answer.
service_container() {
    docker ps --filter "name=${COMPOSE_PROJECT_NAME:?not set — run this through 'just', which derives it from the agent name}-agent-run" \
        --format '{{.Names}}' 2>/dev/null | head -1
}

# Headless or interactive — `run` passes -p and `chat` does not, the only
# difference visible from outside. Read from the container rather than inferred
# from which recipe is running: by the time anyone asks, no recipe is.
session_kind() {
    local id what
    id=$(session_id)
    [ -n "$id" ] || return 1
    # Element 1 exactly, not a search of the whole command line: the message
    # `chat` passes is the operator's own prose and could contain -p.
    what=$(docker inspect -f '{{index .Config.Cmd 1}}' "$id" 2>/dev/null) || what=""
    if [ "$what" = "-p" ]; then echo auto; else echo chat; fi
}

# When that container started, as an epoch. Read from docker rather than from
# our own clock, so the age shown is the session's and not the age of our
# waiting.
session_started() {
    local id started
    id=$(session_id)
    [ -n "$id" ] || return 1
    started=$(docker inspect -f '{{.State.StartedAt}}' "$id" 2>/dev/null) || return 1
    date -u -d "$started" +%s 2>/dev/null
}

elapsed() {
    local s=${1:-0}
    if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
    else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}


# Wait for the holder to finish. The trap is here rather than at the call sites
# so that giving up says the same thing wherever it is waited from. Live only
# when someone is watching: from cron a redrawn line is a file full of carriage
# returns, so with no terminal it says one sentence and blocks on flock.
lock_wait() {
    local waited=0 since
    # Ahead of the split, so giving up reads the same whether or not anyone
    # is watching: without it here the blocking branch dies on Ctrl-C with a
    # bare failure.  see docs/sessions.md#waiting-for-the-lock
    trap 'printf "\n"; echo "Gave up waiting. Nothing was started."; exit 130' INT
    if [ ! -t 1 ]; then
        echo "Waiting for the running session to finish."
        flock 9
        echo "It finished. Starting."
        trap - INT
        return
    fi
    since=$(session_started || echo "")
    echo
    until lock_try; do
        # docker every fifth pass only: the clock is arithmetic and costs
        # nothing, `docker inspect` is a process each time.
        [ $((waited % 5)) -eq 0 ] && since=$(session_started || echo "")
        if [ -n "$since" ]; then
            printf '\r  session up %s, waiting %s   (Ctrl-C to give up, or --force)   ' \
                "$(elapsed $(( $(date +%s) - since )))" "$(elapsed $waited)"
        else
            printf '\r  waiting %s   nothing running — the holder may be wedged   ' \
                "$(elapsed $waited)"
        fi
        sleep 1
        waited=$((waited + 1))
    done
    # Clear the line rather than leave half of it under what follows.
    printf '\r%*s\r' 78 ''
    echo "The session finished after $(elapsed $waited). Starting yours."
    trap - INT
}

# Why the lock is held, in the words of whatever evidence there is. The absence
# of a container line is the interesting case: that is what a wedge looks like
# from outside.
lock_why() {
    local c
    c=$(session_container)
    if [ -n "$c" ]; then
        printf 'A session is already running: %s\n' "$(printf '%s' "$c" | tr '\t' ' ')"
    else
        printf 'The session lock is held, but no session container is running.\n'
        printf 'Something holds it with nothing to show for it — a run between\n'
        printf 'starting and stopping, or one that died oddly. What holds it:\n'
        printf '    fuser -v %s\n' "$RUNNER_LOCK"
    fi
}


# Whether a session will start on its own, in one clause: "No session is
# running" reads the same on a machine that runs one every hour and on one
# paused a fortnight ago. Asked of `just schedule --state` rather than read out
# of the crontab, because what counts as paused is a prefix that recipe writes;
# a missing answer is not "nothing scheduled".  see docs/schedule.md
scheduling_phrase() {
    local sched state daemon
    sched=$(just schedule --state 2>&1)
    state=$(printf '%s\n' "$sched" | sed -n 's/^state: //p')
    daemon=$(printf '%s\n' "$sched" | sed -n 's/^daemon: //p')
    case "$state" in
        # Enabled and nothing to fire it is the failure this is worth a
        # clause for: the crontab reads the same either way.
        enabled) if [ "$daemon" = stopped ]; then
                     echo 'Scheduling enabled, but cron is not running.'
                 else
                     echo 'Scheduling enabled.'
                 fi ;;
        paused)  echo 'Scheduling paused.' ;;
        absent)  echo 'Scheduling disabled.' ;;
        *)       echo "Scheduling unknown — 'just schedule' says why." ;;
    esac
}

# The whole sentence for "nothing is running", said by `just status` and by the
# end of a `just listen`. One spelling, so the second reader of it cannot start
# describing a different machine than the first.
session_absent_line() {
    local idle sched
    idle=$(session_idle_minutes)
    sched=$(scheduling_phrase)
    if [ "$idle" -ge 999999 ]; then
        printf 'No session is running, and none has ended since this machine last forgot. %s\n' \
            "$sched"
    elif [ "$idle" -ge 60 ]; then
        printf 'No session is running. The last one ended %dh%02dm ago. %s\n' \
            $((idle / 60)) $((idle % 60)) "$sched"
    else
        printf 'No session is running. The last one ended %dm ago. %s\n' "$idle" "$sched"
    fi
}
