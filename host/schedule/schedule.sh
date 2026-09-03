#!/usr/bin/env bash
# What is scheduled, and the four verbs that change it. Runs on the host; the
# declared flags arrive as environment variables.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

usage='Usage: just schedule [--enable [--cron "M H D M W"] [--cooldown MINUTES]] | --pause | --disable | --relocate | --state'


# --- which verb ---
# One verb per state — absent, live, held — and no two combine: the last one
# typed would do one of the two things asked for and not the other.
#
# `--state` is the parseable first line, for `just status` to quote. What counts
# as paused is this script's `#PAUSED ` prefix, so a second reader of the
# crontab would answer differently the first time that spelling changed.
# see docs/schedule.md#why-state-is-a-verb

mode=report
for verb in enable pause disable relocate state; do
    [ "${!verb}" = yes ] || continue
    [ "$mode" = report ] || { echo "$usage" >&2; exit 2; }
    mode="$verb"
done

# Not a `just` pattern on the recipe: a pattern is checked against the empty
# DEFAULT too, which is how a value that was not said is told from one that was.
case "$cooldown" in
    ''|*[!0-9]*) [ -z "$cooldown" ] || { echo "--cooldown wants a number of minutes." >&2; exit 2; } ;;
esac

# Both describe an entry rather than install one. A flag that quietly turned the
# report into an install is how a schedule nobody meant to touch gets replaced.
if [ "$mode" != enable ] && { [ -n "$cron" ] || [ -n "$cooldown" ]; }; then
    echo "--cron and --cooldown describe the entry; --enable is what installs it." >&2
    echo "$usage" >&2
    exit 2
fi


# --- the entry this repository writes ---
# The deployed checkout, not this one: cron reads whatever tree the line names,
# committed or not. The path is the same sibling from either checkout, so the
# deployed one's own `schedule --state` recognises the line too — session-env.sh
# asks it. see docs/schedule.md#the-deployed-checkout-in-the-line

here="$RUNNER_DEPLOYED"
marker="# $COMPOSE_PROJECT_NAME: the unattended session — installed by just schedule"

# What cron reads as "not a line". It must not itself look like the marker, or
# the scan below would drop the unrelated entry that followed.
held='#PAUSED '

# cron's PATH is /usr/bin:/bin and nothing else, and `just run` calls `just
# collect` by name — from cron without this every scheduled session would end in
# COLLECT_FAILED. Set on the command, not as a crontab PATH= line that would
# apply to every entry added below ours. Rebuilt on every write and never copied
# forward, because a `just` upgraded into another directory is one an installed
# line goes on not finding. see docs/schedule.md#the-path-the-entry-carries
cron_path() { printf '%s:/usr/local/bin:/usr/bin:/bin' "$(dirname "$(command -v just)")"; }

# The same entry with a current PATH and nothing else touched.
with_current_path() {
    local line="$1" rest
    case "$line" in
        *' && PATH='*)
            rest="${line#* && PATH=}"
            printf '%s && PATH=%s %s' "${line%% && PATH=*}" "$(cron_path)" "${rest#* }" ;;
        *)  printf '%s' "$line" ;;
    esac
}


# --- reading the crontab ---
# `rest` is the crontab without our pair and `entry` is the command line out of
# it — one awk rather than two, so what counts as our marker is written down
# exactly once. Matched on the marker's shape and not its exact text: a wording
# change must not be able to orphan a line that runs the agent.
# see docs/schedule.md#the-entry-and-its-marker

scan() {
    printf '%s\n' "$current" | awk -v want="$1" -v project="$COMPOSE_PROJECT_NAME" '
        index($0, "# " project ":") == 1 && index($0, "installed by just schedule") > 0 {
            pair = 1; next
        }
        pair { pair = 0; if (want == "entry") print; next }
        want == "rest" { print }'
}

# Read afresh rather than remembered, so what is reported after a change is the
# crontab as it stands and not as this script meant to leave it. No crontab yet
# is not an error.
load() {
    # No crontab command is not an empty crontab — an entry may be installed on
    # a machine this cannot ask — so neither the report nor --state calls it
    # absent.
    have_crontab=yes
    command -v crontab >/dev/null 2>&1 || have_crontab=no
    current="$(crontab -l 2>/dev/null)"
    filtered="$(scan rest)"
    installed="$(scan entry)"
    had=no
    [ "$(printf '%s' "$current" | wc -c)" != "$(printf '%s' "$filtered" | wc -c)" ] && had=yes
    paused=no
    case "$installed" in "$held"*) paused=yes ;; esac
    entry="${installed#"$held"}"
    # Read out of the installed line, never rebuilt from this invocation's
    # defaults: a hand-edited hour or log path is what a report must tell.
    entry_cron="$(printf '%s' "$entry" | awk '{print $1, $2, $3, $4, $5}')"
    entry_cooldown=0
    case "$entry" in
        *' --cooldown '*) t="${entry##* --cooldown }"; entry_cooldown="${t%% *}" ;;
    esac
    case "$entry_cooldown" in ''|*[!0-9]*) entry_cooldown=0 ;; esac
    entry_log=''
    case "$entry" in *'>> '*) t="${entry##*>> }"; entry_log="${t%% *}" ;; esac
    # Whether this is a line this script would build here — what --enable may
    # take apart and reuse. A line naming another checkout still runs, and runs
    # that one; the report says so.
    ours=no
    case "$entry" in *"cd $here && PATH="*) ours=yes ;; esac
}

# Only our own two lines are ever removed; everything else in the crontab
# belongs to someone else. With no argument it writes the crontab without them,
# which is --disable. The `if` keeps an empty crontab from holding a blank line.
replace() {
    { if [ -n "$filtered" ]; then printf '%s\n' "$filtered"; fi
      if [ $# -gt 0 ]; then printf '%s\n%s\n' "$marker" "$1"; fi; } | crontab -
}

# running, stopped, or unknown — and unknown where there is no systemctl to
# ask, which is not stopped and must not be reported as it.
cron_daemon() {
    if ! command -v systemctl >/dev/null 2>&1; then echo unknown
    elif systemctl is-active --quiet cron; then echo running
    else echo stopped
    fi
}


# --- the report ---
# `report brief` drops the opening line, for callers that have just said what
# they did: "Paused." then "Paused — ..." reads as a stutter.

report() {
    if [ "$have_crontab" = no ]; then
        echo "There is no crontab command on this machine, so what is scheduled"
        echo "cannot be read — which is not the same as nothing being scheduled."
        echo
        echo "    sudo apt install cron"
        return
    fi
    if [ "$had" = no ]; then
        echo "Nothing is scheduled. Sessions happen only when you start one."
        echo
        echo "    just schedule --enable [--cron \"M H D M W\"] [--cooldown MINUTES]"
        return
    fi
    if [ "${1:-}" != brief ]; then
        if [ "$paused" = yes ]; then
            echo "Paused — the entry is installed and cron will not fire it."
        else
            echo "Enabled."
        fi
    fi
    echo
    printf '  when      %s\n' "$entry_cron"
    if [ "$entry_cooldown" -gt 0 ]; then
        printf '  cooldown  %s minutes since the last session ended\n' "$entry_cooldown"
    else
        printf '  cooldown  none — every wake-up starts a session unless one is running\n'
    fi
    printf '  log       %s\n' "$entry_log"
    if [ "$ours" = no ]; then
        echo
        echo "  This is not the line this recipe builds here — edited by hand, or"
        echo "  installed from another checkout. The fields above are read off it"
        echo "  as it stands, and it is that line cron runs."
    fi
    echo
    crontab -l | grep -A1 -F "$marker"
    echo
    if [ "$entry_cooldown" -gt 0 ]; then
        echo "A wake-up that declines exits 75 and writes nothing, so the log stays a"
        echo "record of sessions rather than of ticks. Nothing rotates it."
    else
        echo "A wake-up that stands down for a session already running is exit 75,"
        echo "and says in the log which one. Nothing rotates that log."
    fi
    # An entry cron never reads is the failure this report is for: the crontab
    # looks the same either way, and so does a machine with nothing to do.
    case "$(cron_daemon)" in
        running) echo "cron is running." ;;
        stopped) echo "cron is NOT running, so none of this fires: sudo systemctl enable --now cron" ;;
    esac
    echo
    if [ "$paused" = yes ]; then
        echo "Put it back as it stands:  just schedule --enable"
    else
        echo "Hold it without losing it: just schedule --pause"
    fi
    echo "Remove it altogether:      just schedule --disable"
}


# --- the verbs that only read ---

load

case "$mode" in
report)
    report
    exit 0 ;;
state)
    # One field per line, prefixed, so a reader takes what it knows and ignores
    # the rest. `state:` is always there; `unknown` is a real answer. `cron:` is
    # the expression and `daemon:` is what would fire it — different facts, and
    # confusing them reports a schedule that cannot run as one that will.
    # see docs/schedule.md#why-state-is-a-verb
    if [ "$have_crontab" = no ]; then
        echo "state: unknown"
    elif [ "$had" = no ]; then
        echo "state: absent"
    else
        [ "$paused" = yes ] && echo "state: paused" || echo "state: enabled"
        echo "daemon: $(cron_daemon)"
        echo "cron: $entry_cron"
        echo "cooldown: $entry_cooldown"
    fi
    exit 0 ;;
disable)
    if [ "$had" = no ]; then
        echo "Nothing scheduled — the crontab is unchanged."
        exit 0
    fi
    replace || exit 1
    echo "Removed. Nothing is scheduled now."
    exit 0 ;;
pause)
    if [ "$had" = no ]; then
        echo "Nothing scheduled — there is nothing to pause."
        exit 0
    fi
    if [ "$paused" = no ]; then
        # Commented out where it stands rather than remembered elsewhere: the
        # crontab is the only copy, so there is nothing to fall out of step.
        replace "$held$installed" || exit 1
        echo "Paused — the entry stays where it is and cron will not fire it."
    else
        echo "Already paused."
    fi
    load
    report brief
    exit 0 ;;
relocate)
    # Called by `just deploy` once the deployed checkout exists. Only the
    # directory and the PATH move — the expression, the cooldown, the log and
    # whether it is paused all stay, because a deploy is not a decision about
    # any of those, and relocating must never be the way a pause ends.
    # see docs/release.md
    if [ "$had" = no ]; then
        echo "Nothing scheduled — nothing to relocate."
        exit 0
    fi
    if [ "$ours" = yes ]; then
        # Already here, so only the PATH can be out of date — and it is what a
        # `just` upgrade moves out from under an installed line.
        fresh=$(with_current_path "$entry")
        if [ "$fresh" != "$entry" ]; then
            [ "$paused" = yes ] && fresh="$held$fresh"
            replace "$fresh" || exit 1
            echo "The schedule already runs from $here; its PATH was refreshed to $(cron_path)."
        elif [ "$paused" = yes ]; then
            echo "The schedule is already installed on $here — paused, so nothing fires until 'just schedule --enable'."
        else
            echo "The schedule already runs from $here."
        fi
        exit 0
    fi
    case "$entry" in
        *' cd '*' && PATH='*) ;;
        *)  echo "The installed entry is not one this recipe wrote, so its directory cannot be moved safely:" >&2
            echo "  $entry" >&2
            echo "Reinstall it: just schedule --enable [--cron …] [--cooldown N]" >&2
            exit 1 ;;
    esac
    moved="${entry%% cd *} cd $here && PATH=${entry#* && PATH=}"
    moved=$(with_current_path "$moved")
    [ "$paused" = yes ] && moved="$held$moved"
    replace "$moved" || exit 1
    if [ "$paused" = yes ]; then
        echo "Relocated — the schedule now runs from $here, and it is still paused."
    else
        echo "Relocated — the schedule now runs from $here."
    fi
    load
    report brief
    exit 0 ;;
esac


# --- --enable, from here down ---
# With neither --cron nor --cooldown it means "on" and nothing more, both paths
# with a current PATH. Rebuilding the line from this invocation's defaults would
# turn an `--enable` a fortnight after `--cron "*/20 * * * *"` into a silent
# move back to the hour.

if [ -z "$cron" ] && [ -z "$cooldown" ] && [ "$had" = yes ]; then
    fresh=$(with_current_path "$entry")
    if [ "$paused" = yes ]; then
        replace "$fresh" || exit 1
        echo "Enabled — the line that was paused, its PATH current."
    elif [ "$fresh" != "$entry" ]; then
        replace "$fresh" || exit 1
        echo "Already enabled; its PATH was refreshed to $(cron_path)."
    else
        echo "Already enabled."
    fi
    load
    report brief
    exit 0
fi


# --- --enable with an entry to build ---
# What was not said is inherited from the entry that is there, so `--enable
# --cooldown 15` moves the cooldown and leaves the hour where it was. The
# defaults apply only when there is nothing to inherit.
#
# Only from a line this recipe built, though: five fields cut off the front of
# an arbitrary line are five fields whatever that line says. Refused rather than
# guessed, and the refusal names the flag that settles it.
# see docs/schedule.md#what-enable-inherits

if [ -z "$cron" ] && [ "$had" = yes ] && [ "$ours" = no ]; then
    echo "The installed line is not the one this recipe builds here — edited by" >&2
    echo "hand, or installed from another checkout — so its hour cannot be reused." >&2
    echo "Say it: just schedule --enable --cron \"M H D M W\"" >&2
    exit 2
fi
if [ -z "$cron" ]; then
    [ "$ours" = yes ] && cron="$entry_cron" || cron='17 * * * *'
fi
if [ -z "$cooldown" ]; then
    [ "$ours" = yes ] && cooldown="$entry_cooldown" || cooldown=0
fi

# Checked here rather than discovered by cron at the next tick: a wrong field
# count lands as a valid line meaning something else entirely, and the symptom
# is sessions at times nobody chose. Inherited values are checked too.
if [ "$(printf '%s' "$cron" | wc -w)" -ne 5 ]; then
    echo "--cron wants five fields: minute hour day month weekday." >&2
    echo "Got: $cron" >&2
    exit 2
fi

# A % in a crontab command means a newline unless escaped, so one here would cut
# the line in half and feed the remainder to a command that asked for none.
case "$cron$cooldown" in
    *%*) echo "A % means a newline to cron. Escape it or leave it out." >&2; exit 2 ;;
esac


# --- the line ---
# The log lives in a directory, and cron's `>>` will not create one: a missing
# parent is the whole line failing before `just` is reached, every minute, with
# the reason going to cron's mail where nobody reads it.
#
# No flock here, and that is the point: `just run` takes the lock itself, so it
# binds a run typed by hand too, and wrapping this line as well would deadlock.
# No timeout either — a session takes as long as it takes, and the price is that
# a wedged one holds the lock until `just run --force`. see docs/sessions.md
#
# --cooldown makes the schedule a floor rather than a clock: cron wakes on the
# expression and `run` decides whether the last session ended long enough ago.
# see docs/schedule.md#the-cooldown-is-a-floor

log="$RUNNER_RUN_LOG"
mkdir -p "$(dirname "$log")" 2>/dev/null || true

# A line naming a directory that is not there fails every minute into the log,
# which is the shape nobody reads.
if [ ! -e "$here/justfile" ]; then
    echo "No deployed checkout at $here — nothing to schedule. 'just deploy' says how to create it." >&2
    exit 1
fi

runcmd='just run'
[ "$cooldown" -gt 0 ] && runcmd="just run --cooldown $cooldown"
line="$cron cd $here && PATH=$(cron_path) $runcmd >> $log 2>&1"

mkdir -p "$(dirname "$log")"
replace "$line" || exit 1

if [ "$had" = no ]; then
    echo "Installed."
elif [ "$paused" = yes ]; then
    # Installing over a paused entry is how a pause ends by accident, so it is
    # reported as the resumption it is rather than as a replacement.
    echo "Replaced the paused entry — it is live again."
else
    echo "Replaced the previous entry."
fi

load
report brief
echo
echo "It only fires while WSL is up. For hours when no terminal is open,"
echo "drive it from Windows Task Scheduler instead, running:"
echo "    wsl.exe -d <distro> -u $USER -- bash -lc 'cd $here && just run'"
echo "and remove this entry with: just schedule --disable"
