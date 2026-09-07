# shellcheck shell=bash
# How the last unattended run ended, and whether the next session has to be
# told about it.
#
# Sourced by host/session/run.sh, read by host/archive/status-collect.py and
# planted as a fixture by the verify probe. Never executed: the verdict is read
# into the shell that composes the next session's opening message.
#
# One record, and it is replaced only when a session actually starts.
# Everything that stands a wake-up down — the cooldown, a held lock, the
# budget, a window with nothing left — exits before the record is opened, so a
# stop stays unconsumed across as many refused wake-ups as it takes for one to
# run. That is the whole latch, and it is why there is no second file saying
# "recovery pending".
# see docs/sessions.md#recovering-a-session-that-was-stopped

# Required, never defaulted, like the stamps in session-lock.sh: a fallback
# would be two agents writing one record, and the symptom would be one agent
# told about the other's crash.
RUNNER_LAST_RUN="${RUNNER_LAST_RUN:?not set — run this through 'just', which derives it from the agent name}"

# The bounds a session's own request is held to, and the arithmetic over the
# two stamps. Sourced rather than inlined because three readers need it and
# only one of them is this file.
# shellcheck source=SCRIPTDIR/wake-request.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/wake-request.sh"


# --- what a record holds ---
# `key=value` lines, appended in the order the facts become true. Not JSON, so
# that ~/.cache/<agent>/last-run reads as itself with `cat` and so the fixture
# the verify probe plants is three lines of `printf`.
#
#   started    epoch, written immediately before the container starts
#   container  what it was named, so a record can be matched to a live session
#   ended      epoch, when it came back — ABSENT is the interesting case: the
#              process never reached its own exit, so nothing wrote this
#   status     what `docker compose run` exited
#   reason     the result envelope's terminal_reason. `completed` is the only
#              clean ending; `none` means there was no envelope to read, which
#              is a stop of a different kind and not a clean one
#   is_error, api_error_status, session
#              the rest of the envelope — evidence, and they decide nothing
#   wedged     the session start already reported as a wedge, so a hang toasts
#              once rather than once a minute
#   asked_wake_after
#              minutes the closing message asked to be woken in, ABSENT when it
#              asked for nothing. What was asked, never what was allowed, and
#              written whether or not the feature is armed: a run of records
#              saying 240 beside a `wake_after` of 120 is a ceiling set too low,
#              and nothing else here would ever say so
#   wake_after the minutes that govern the next wake-up — that ask, clamped, or
#              the default wait when there was no ask
#
# Why `reason` decides and `is_error` does not is in docs/budget.md, under
# "The limit stops the session".

# The last assignment wins, so a field written twice reads as the later one.
run_record_field() {
    sed -n "s/^$1=//p" "$RUNNER_LAST_RUN" 2>/dev/null | tail -1
}


# --- opening and closing ---
# Both are best-effort and neither can fail a run: a record that could not be
# written costs the next session its recovery context, and a run that died
# because its bookkeeping failed costs the session itself.

run_record_open() {
    mkdir -p "$(dirname "$RUNNER_LAST_RUN")" 2>/dev/null || return 0
    {
        printf 'started=%s\n' "$(date +%s)"
        printf 'container=%s\n' "$1"
    } 2>/dev/null > "$RUNNER_LAST_RUN" || true
}

# The third argument is this run's container name, and a record naming another
# is left alone. Under --force a second run opens its own record on top of the
# wedged one's; when the wedged one finally dies, its close would append an
# ending to a record that is not its own, and the next wake-up would read the
# forced session — still running — as stopped.
run_record_close() {
    local status="$1" envelope="${2:-}" name="${3:-}"
    [ -z "$name" ] || [ "$(run_record_field container)" = "$name" ] || return 0
    {
        printf 'ended=%s\n' "$(date +%s)"
        printf 'status=%s\n' "$status"
        run_envelope_fields "$envelope"
        run_wake_fields "$envelope"
    } 2>/dev/null >> "$RUNNER_LAST_RUN" || true
}


# --- what the next wake-up will read ---
# Decided here rather than where it is read, so the record holds the number
# that was in force rather than one recomputed later against bounds that have
# since moved. The default is the exception and stays live: it is read from
# .env at the moment it applies, so changing it takes effect on the next
# wake-up rather than on the one after.
#
# The one seam is arming the request: the record written by the last session
# before it was armed holds that session's default, so the first wake-up after
# arming waits that instead of the ask beside it. One session, at a number that
# was a legitimate wait.

run_wake_fields() {
    local asked wake=""
    asked=$(wake_asked "$(run_envelope_result "${1:-}")")
    if [ -n "$asked" ]; then
        printf 'asked_wake_after=%s\n' "$asked"
        if wake_armed; then wake=$(wake_clamp "$asked") || wake=""; fi
    fi
    printf 'wake_after=%s\n' "${wake:-$(wake_default)}"
}


# --- the envelope ---
# `claude -p --output-format json` prints one JSON object. The entrypoint
# prints prose before it, so the object is found as the last line beginning
# with a brace rather than by parsing the whole stream — a rule a person can
# check against the file by eye.
#
# Anything unreadable comes out as `reason=none`, which is not `completed` and
# therefore routes to recovery. That is the direction this must fail in: an
# envelope we could not parse is a run we cannot vouch for.
#
# The values are scrubbed to the characters they are allowed to hold. They
# reach a shell that composes a message, and an envelope is the one input here
# that a session's own output could reach.

run_envelope_fields() {
    local line=""
    [ -n "${1:-}" ] && [ -f "$1" ] && line=$(grep -a '^{' "$1" 2>/dev/null | tail -1)
    if [ -z "$line" ]; then
        printf 'reason=none\n'
        return
    fi
    printf '%s' "$line" | jq -r '
        "reason=\((.terminal_reason // "none") | tostring | gsub("[^A-Za-z0-9_-]"; ""))",
        (.is_error         | select(. != null) | "is_error=\(. | tostring | gsub("[^A-Za-z0-9]"; ""))"),
        (.api_error_status | select(. != null) | "api_error_status=\(. | tostring | gsub("[^0-9]"; ""))"),
        (.session_id       | select(. != null and . != "") | "session=\(. | gsub("[^A-Za-z0-9-]"; ""))")
    ' 2>/dev/null || printf 'reason=none\n'
}

# What the session actually said, so the run log keeps reading as prose after
# the output format changed under it. Empty when there is nothing to print.
run_envelope_result() {
    local line=""
    [ -n "${1:-}" ] && [ -f "$1" ] && line=$(grep -a '^{' "$1" 2>/dev/null | tail -1)
    [ -n "$line" ] || return 0
    printf '%s' "$line" | jq -r '.result // empty' 2>/dev/null || true
}


# --- the verdict ---
# `run_record_verdict yes|no`, where the argument says whether a session
# container is running right now. Asked of the caller rather than of docker
# here: `run.sh` has the answer already, and a second `docker ps` would be a
# second process on a path that runs every minute.
#
# The running case is why the argument exists at all. A record left open by a
# session that is still going — a wedge, or a `--force` run beside it — must
# not read as a stop, or the forced session would be told the wedged one
# crashed. An open record is a stop only once nothing is running on it.
#
#   none            no record: a fresh install, a cleared cache, the first run
#   running         open, and a session is running — not a verdict yet
#   clean           ended, and the envelope said `completed`
#   stopped <why>   everything else, `killed` when nothing closed the record

run_record_verdict() {
    local running="${1:-no}" ended reason
    [ -f "$RUNNER_LAST_RUN" ] || { printf 'none\n'; return; }
    [ -n "$(run_record_field started)" ] || { printf 'none\n'; return; }

    ended=$(run_record_field ended)
    if [ -z "$ended" ]; then
        [ "$running" = yes ] && { printf 'running\n'; return; }
        printf 'stopped killed\n'
        return
    fi

    reason=$(run_record_field reason)
    [ "$reason" = completed ] && { printf 'clean\n'; return; }
    printf 'stopped %s\n' "${reason:-unknown}"
}


# --- when the last unattended session ended ---
# As an ISO-8601 UTC instant, for the container to be told. It lives here
# because the record is the only thing that knows it: the stamp session-lock.sh
# keeps counts conversations too, so `<NAME>_LAST_SESSION_ENDED` cannot answer
# "when did the last UNATTENDED one end", and neither can it be derived from
# that variable and the chat one together.
#
# Nothing when the record has no ending — a session still running, one that was
# killed, or no record at all — and a future instant reads as nothing for the
# reason session-lock.sh gives: both readings decline to pretend.

run_record_ended_at() {
    local last
    last=$(run_record_field ended)
    case "$last" in ''|*[!0-9]*) return 1 ;; esac
    [ "$last" -le "$(date +%s)" ] || return 1
    date -u -d "@$last" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}


# --- the wedge mark ---
# Which session start has already been toasted, so a hang reports once rather
# than once a minute. It lives here because the record already belongs to that
# run and already holds its start.  see docs/schedule.md#the-wedge-alarm

run_record_wedge_seen() { [ "$(run_record_field wedged)" = "$1" ]; }

run_record_wedge_mark() {
    printf 'wedged=%s\n' "$1" 2>/dev/null >> "$RUNNER_LAST_RUN" || true
}
