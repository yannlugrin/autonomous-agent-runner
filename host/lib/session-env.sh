# shellcheck shell=bash
# What a session is told about itself: SESSION_ENV, the `-e NAME=VALUE`
# arguments for `docker compose run`.
#
# Sourced by `just run`, `just chat` and `just shell`, never executed: an array
# does not survive a command substitution, and a cron expression is five words.
# A shell gets them because a session started by hand from that shell is one,
# and it must not see a different world than one started for it. `just listen`
# and the verify probes carry none of them, because nothing runs in those.
#
# Nothing here is direction, and that is a rule rather than an observation.
# These are facts about where the session is — the same class as the opening
# message's "you are running beside another session", and deliberately not the
# class of "do X". This channel reaches the agent without anyone reading it
# first, so a variable phrased as an instruction would be the runner telling
# the agent what to do through the one path nobody reviews.
#
# They are read once as the container starts and never updated, which is why
# the last session is an instant and not an age: an instant stays true while
# the session runs, "20 minutes ago" does not.

_env_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# For session_ended_at, which knows the format of the record it reads. Sourcing
# it twice is harmless: it defines functions and assigns defaults, and the lock
# is taken by `lock_open`, which nothing here calls.
# shellcheck source=SCRIPTDIR/session-lock.sh
source "$_env_here/session-lock.sh"


# --- the schedule ---
# Asked of `just schedule` rather than read out of the crontab here, for the
# reason `just status` asks it too: what counts as paused is a prefix that
# recipe writes, and a second reader would go on believing the old spelling.
# One call, because each one is a process.
#
# Underscored names throughout: this is sourced into a recipe that has its own
# `cooldown` and its own `state`, and a plain name here would quietly overwrite
# the one the caller is using.

_env_sched="$(just schedule --state 2>&1)"
_env_field() { printf '%s\n' "$_env_sched" | sed -n "s/^$1: //p"; }

# The vocabulary the container sees is what will happen, not what is written in
# the crontab: an entry no daemon will ever read is not enabled in any sense
# the agent can use, and it resumes by starting cron exactly as a paused one
# resumes by uncommenting. So `disabled` keeps its narrow meaning — there is no
# entry at all — and `unknown` is a real answer.
_env_state="$(_env_field state)"
case "$_env_state" in
    enabled) [ "$(_env_field daemon)" = stopped ] && _env_state=paused ;;
    paused)  ;;
    absent)  _env_state=disabled ;;
    *)       _env_state=unknown ;;
esac

# Read off the installed line even when it is paused, which is the point: "what
# is my cadence, when it runs" is a question a held schedule still has an
# answer to. Empty when there is no line to read one off.
_env_cron="$(_env_field cron)"
_env_cooldown="$(_env_field cooldown)"
case "$_env_cooldown" in ''|*[!0-9]*) _env_cooldown=0 ;; esac


# --- the budget guard ---
# Armed only when ACCOUNT_BUDGET_GUARD says so, and run here because reading
# usage needs a login with the `user:profile` scope that only the interactive
# `claude login` grants. It reads the same number the container would, since
# the endpoint reports the account rather than the credential — so arming this
# is honest only while one account is behind both.
#
# Its exit status is read by the caller, so a guard that is missing or broken
# is a session that does not start. The reading the container does for itself
# is advisory and deliberately cannot stand anything down. The same file run
# two ways rather than a host copy: a second copy of the arithmetic is the one
# that drifts, silently, because both answers look like numbers.
#
# One call serves both the numbers a session is told and the decision to start
# it, where two would be two answers a minute apart — the session told one and
# refused on the other. `chat` sources this too and ignores the verdict,
# because a conversation is the operator spending their own quota deliberately;
# the call is also what renews the container's access token on the days nothing
# is scheduled.
# see docs/budget.md#userprofile-and-why-the-guard-runs-on-the-host
# see docs/budget.md#the-expiry-check-comes-before-the-cache

BUDGET_VERDICT="the host budget guard is off"
BUDGET_STATUS=0
# The gated windows with nothing left at all, comma-separated, or empty. Empty
# covers two states deliberately — nothing is exhausted, and there was no
# reading at all — because neither is a reason to refuse: the tool prints no
# EXHAUSTED line on the path where it could not read, and a floor that stood
# sessions down on an unreadable account would stop every session on a host
# that cannot read usage.
BUDGET_EXHAUSTED=""
# Every ACCOUNT_USAGE_* the tool printed, already spelled as `-e NAME=value`.
BUDGET_ENV=()

# Exactly `true` arms it, nothing else including a plausible `yes`: compose
# passes the raw value into every container and the session reads it back, so
# one comparison made the same way on both sides is the whole vocabulary and
# there is nothing to keep in step. A value that is neither empty nor `true` is
# off — and `just verify` says so out loud, because that is the case that would
# otherwise be silent.  see docs/budget.md#exactly-true-arms-the-guard
BUDGET_GUARD_ARMED=false
[ "${ACCOUNT_BUDGET_GUARD:-}" = true ] && BUDGET_GUARD_ARMED=true

# Read here whether or not it is armed, because the numbers a session is told
# come from this reading: the container's own token can rarely read usage (a
# setup-token cannot), and a session without numbers cannot pace itself. Armed,
# the exit status gates; off, --advisory exits 0 whatever it finds and prints
# no numbers when it cannot tell, so the container then reads for itself —
# the case where this host has no login, or the agent runs on its own account.
_env_usage=(--env)
if [ "$BUDGET_GUARD_ARMED" = true ]; then
    BUDGET_VERDICT="the guard said nothing"
else
    _env_usage+=(--advisory)
fi
# --env so stdout is NAME=value lines and nothing else; the one line it
# writes when it cannot tell goes to stderr, where cron finds it.
_env_budget="$(python3 "$_env_here/../../image/claude-usage.py" "${_env_usage[@]}")"
# shellcheck disable=SC2034 # used by caller after sourcing
BUDGET_STATUS=$?
# Off, the status is not a verdict: the tool is advisory there, and a tool
# that is missing must not stand down a session nothing was gating.
# shellcheck disable=SC2034 # used by caller after sourcing
[ "$BUDGET_GUARD_ARMED" = true ] || BUDGET_STATUS=0
while IFS= read -r _env_line; do
    # Forwarded by prefix, not by name. What the variables are called and
    # what they hold is claude-usage.py's business, and it is the same file
    # the container runs for itself — so naming them here would be a second
    # place the shape lives.
    #
    # `unknown` is dropped rather than carried: the guard prints it when it
    # could not read, and passing it on would tell the container "the host
    # answered", suppressing the advisory read that might have succeeded
    # where the host did not.
    # see docs/budget.md#the-host-forwards-by-prefix-not-by-name
    # shellcheck disable=SC2034 # BUDGET_VERDICT used by caller after sourcing
    case "$_env_line" in
        ACCOUNT_USAGE_*=unknown)  ;;
        ACCOUNT_USAGE_*|ACCOUNT_BUDGET_*)
                                BUDGET_ENV+=(-e "$_env_line") ;;
        VERDICT=*)              [ "$BUDGET_GUARD_ARMED" = true ] && BUDGET_VERDICT="${_env_line#*=}" ;;
        EXHAUSTED=*)            BUDGET_EXHAUSTED="${_env_line#*=}" ;;
    esac
done <<<"$_env_budget"


# --- what the session is told ---

SESSION_ENV=(
    # enabled | paused | disabled | unknown
    -e "${AGENT_PREFIX:?set by just}_SCHEDULE=$_env_state"
    # The five cron fields, or empty when nothing is installed. Named for
    # cron on purpose: another scheduler would be another variable, not the
    # same one holding something that is not a cron expression.
    -e "${AGENT_PREFIX:?set by just}_SCHEDULE_CRON=$_env_cron"
    # Minutes that must have passed since the last session ended. 0 means
    # none, and then every wake-up starts one.
    -e "${AGENT_PREFIX:?set by just}_SCHEDULE_COOLDOWN=$_env_cooldown"
    # ISO-8601 UTC, or `unknown` — no record survives a cleared cache, and
    # the first session after one has nothing true to say here.
    -e "${AGENT_PREFIX:?set by just}_LAST_SESSION_ENDED=$(session_ended_at || echo unknown)"
    # When the operator last spoke, as distinct from when any session ran:
    # most sessions are the schedule's, so "nobody has talked to me in three
    # days" is not answerable from the line above.
    -e "${AGENT_PREFIX:?set by just}_LAST_CHAT_ENDED=$(chat_ended_at || echo unknown)"
)

# What the host read, passed on only when it actually read something. Absent
# is meaningful: the entrypoint takes an absent ACCOUNT_USAGE_SESSION as its
# cue to read the container's own usage instead, which is the case where this
# host could not read, or the agent runs on an account of its own.
#
# `ratio` is carried over allowance-as-a-percentage — it says how close the
# door is, where the raw utilisation says nothing without the allowance beside
# it. Above 100 is what an --ignore-budget session sees. A snapshot, like
# everything else here: the allowance climbs while the session runs and these
# do not move with it.
SESSION_ENV+=(${BUDGET_ENV[@]+"${BUDGET_ENV[@]}"})

# --- nothing left ---
# A separate refusal from the budget, and it does not ask whether the guard is
# armed. The guard shares out an allowance between the operator and the agent, and
# the percentages that describe it are theirs to set; a window at 100% is not
# an allowance question at all — the account cannot answer a request, so the
# session would start, hit the limit and stop, and with
# `autoContinueAtUsageLimit` off that stop is a recovery start the next session
# has to be told about for nothing.
#
# Overridable by --ignore-budget like the budget itself: the flag is the
# operator saying start anyway, and a refusal with no way past it is a decision this
# file should not be making on its own. What it costs is visible — the session
# stops on the limit almost at once — and `run.sh` says so before it starts.
# see docs/budget.md#nothing-left-is-not-a-budget

if [ -n "$BUDGET_EXHAUSTED" ]; then
    # shellcheck disable=SC2034 # both are read by the caller after sourcing
    BUDGET_VERDICT="nothing left in: ${BUDGET_EXHAUSTED//,/, }"
    # shellcheck disable=SC2034 # read by the caller after sourcing
    BUDGET_STATUS=75
fi


# Whether this host would refuse a session on budget — normalised to exactly
# `true` or `false`, never absent and never empty. Told even when it is armed
# and the run bypassed it: `--ignore-budget` does not disarm the guard, it
# ignores the answer, so a ratio over 100 beside `true` is a session that
# started because someone said so.
SESSION_ENV+=(-e "ACCOUNT_BUDGET_GUARD=$BUDGET_GUARD_ARMED")
