#!/usr/bin/env bash
# A conversation with the agent — an interactive session the operator sits in.
#
# Runs on the host. It parses its own flags rather than taking declared ones
# from the recipe: the message is free text that must survive verbatim,
# including a leading dash, and a declared option would have `just` refuse it
# as an unknown flag. `just chat [--force] [--continue] "your message"`.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh


# --- what was asked for ---
# A loop rather than one test, so the flags may come in either order and the
# message keeps whatever it contains — including a leading dash, once the flags
# have been taken off the front.

force=false
parallel=false
resume=false

while [ $# -gt 0 ]; do
    case "$1" in
        --force) force=true; shift ;;
        --continue) resume=true; shift ;;
        # Named so it cannot become the message: this loop stops at the first
        # non-flag and keeps the rest verbatim, so a message may begin with a
        # dash, and a flag removed without a case here is not an error but a
        # conversation seeded with its own spelling.
        # see docs/sessions.md#the-build-flag-left-run-and-chat
        --build)
            echo "--build is gone: a conversation runs the deployed image." >&2
            echo "'just shell --build' looks inside a candidate; 'just verify' proves it." >&2
            exit 2 ;;
        *) break ;;
    esac
done

prompt="$*"

# A message is required to start a conversation and optional to resume one:
# `just chat --continue` on its own is "put me back where we were", which is
# most of what it is for.
if [ "$resume" = false ] && [ -z "$prompt" ]; then
    echo 'Usage: just chat [--force] [--continue] "your message"' >&2
    exit 2
fi


# --- always the live runner ---
# As `run`, and for the reason recorded in host/lib/deployed.sh: a conversation
# happens on the deployed image. The flags and the message are rebuilt because
# `just` handed them over as one variadic list.

if [ "$RUNNER_IS_DEPLOYED" = no ]; then
    typed=()
    [ "$force" = true ] && typed+=(--force)
    [ "$resume" = true ] && typed+=(--continue)
    [ -z "$prompt" ] || typed+=("$prompt")
    forward_to_deployed chat ${typed[@]+"${typed[@]}"}
fi

host/lib/docker-up.sh --image "${RUNNER_IMAGE:-$RUNNER_IMAGE_DEPLOYED}" || exit $?
source host/lib/session-lock.sh


# --- which conversation this is ---
# `claude --continue` inside the container resumes the most recent session in
# the checkout, and most of the time that is the hourly unattended run — the
# wrong conversation, opened silently. So the id is decided here, out of the
# container, and written down; --continue asks for that one by name.
#
# python3 rather than uuidgen, which is not among the tools `just verify` says
# this repository needs — one required tool doing a second job is cheaper than a
# new line in that table.
# see docs/sessions.md#which-conversation---continue-resumes

if [ "$resume" = true ]; then
    # The record first, the volume second. The record is the exact answer — an
    # id `chat` chose itself — but it only knows the conversations started since
    # it began being written, and refusing to continue one that is plainly still
    # in the volume is the worse answer.
    chat_id=$(last_chat) || chat_id=$(host/session/last-chat.sh "$OPERATOR_SAYS")
    [ -n "$chat_id" ] || {
        echo "No conversation to continue: no transcript in the volume begins with" >&2
        echo "the operator speaking, and nothing has been started with 'just chat' since this" >&2
        echo "machine last forgot. Start one, and --continue will find it." >&2
        exit 1
    }
else
    chat_id=$(python3 -c 'import uuid; print(uuid.uuid4())') || exit $?
fi


# --- the lock ---
# Waiting rather than refusing, because a conversation is a thing the operator
# wants to happen, not a job to skip. `run` refuses by default — nobody is
# there to wait for it — and takes --wait to behave like this.

lock_open
if ! lock_try; then
    lock_why
    if [ "$force" = true ]; then
        # Forcing runs a second session beside the first. With --continue it
        # would be the same conversation twice — two claude processes appending
        # one transcript. A running chat is the last chat, so there is no case
        # where this refusal is wrong.
        if [ "$resume" = true ] && [ "$(session_kind)" = chat ]; then
            echo
            echo "Refusing: --force --continue would resume the conversation that is"
            echo "running, so two sessions would write one transcript. Wait for it, or"
            echo "drop --continue to start a second conversation beside it."
            exit 1
        fi
        parallel=true
        echo
        echo "Going in anyway. A session is running beside this one, on the same"
        echo "checkout — expect the agent to find its own tree changing under it."
    else
        lock_wait
    fi
fi


# --- what the session is started with ---
# Not `-p`: that mode ends after one turn whoever is on the other side, so a
# conversation cannot happen in it.
#
# The bracket is ahead of their greeting: the operator is present here and could
# have said it themselves, but they did not — the runner did, and the line
# between the two is the thing rule 1 rests on. A session started beside a
# running one is told so in its system prompt — image/claude-session.py, when
# this variable is set — and not in front of the message: the sender line is the
# first thing read.
#
# The greeting is for a conversation that is beginning. Re-introducing
# themselves into a thread already underway would read as the operator having
# forgotten it. The bracket stays in both.

other=()
if [ "$parallel" = true ]; then
    other=(-e "${AGENT_PREFIX}_OTHER_SESSION_STARTED_AT=$(date -u -d "@$(session_started)" +%FT%TZ 2>/dev/null || echo unknown)")
fi

if [ "$resume" = true ]; then
    session_flags=(--resume "$chat_id")
    [ -z "$prompt" ] || message="$OPERATOR_SAYS $prompt"
else
    session_flags=(--session-id "$chat_id")
    message="$OPERATOR_SAYS Hey it's me, $OPERATOR_NAME. $prompt"
fi


# --- the budget gate, read and not enforced ---
# What the session is told about its own cadence — see `run` and docs/budget.md.
# Deliberately not enforced here: a conversation is the operator spending their
# own quota on purpose, and a gate that refused them would be protecting them
# from themselves. The call also renews the container's access token on the days
# nothing is scheduled.

source host/lib/session-env.sh


# --- the session ---
# The id is written here and not where it was decided: everything above this
# line can still end in a refusal or a Ctrl-C at the lock. Before the run rather
# than after it, though — a conversation that dies in its first minute is worth
# resuming.
#
# --name, so this is findable as a session. Without it compose calls it what it
# calls a shell and a verify probe, and nothing can tell them apart — see
# RUNNER_SESSION_NAME in host/lib/session-lock.sh.
#
# `${message+"$message"}` and not `"$message"`: an empty message is a --continue
# with nothing to say, and passing "" would hand claude an empty first turn.

chat_started "$chat_id"

started=$(date +%s)   # see `run`: the summary must not report the session before

docker compose run --rm --name "$RUNNER_SESSION_NAME-$$" \
    "${SESSION_ENV[@]}" ${other[@]+"${other[@]}"} -w "$AGENT_REPO_DIR" agent \
    claude-session "${session_flags[@]}" ${message+"$message"}
status=$?


# --- the bookkeeping that follows it ---
# The session end is recorded whatever the status, because a session that failed
# still ran; the conversation's end is a second fact — the moment the operator
# last spoke — told to the next session so it can tell silence from inactivity.
#
# --push, and the mirror, for the same reasons as in `run`: an archive that
# stops at this machine is not a backup of it, and GitHub's schedule is not to
# be relied on.

session_ended
chat_ended

just collect --push || echo "COLLECT_FAILED — the transcript may not have reached the archive. It is still in the volume; run 'just collect --push' by hand." >&2

host/archive/dispatch-mirror.sh || echo "MIRROR_NOT_DISPATCHED — the archive's mirror was not asked to run; its schedule is the only trigger left." >&2


# --- the last word ---
# --force on the publish, skipping the floor: the page saying a session is
# running ten minutes after it stopped is the staleness anybody would notice.
# The summary is last, so it is the line left on the screen — see `run`.

host/archive/publish-status.sh --now || true

echo
host/session/session-stats.py --since "$started" || true

exit $status
