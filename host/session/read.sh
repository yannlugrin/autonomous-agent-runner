#!/usr/bin/env bash
# Read one transcript whole — a session, or one of its subagents — from the
# archive or the volume. The only reader there is: `just sessions` lists, this
# opens, and two implementations of "show me a transcript" is one of them
# drifting out of date unread.
#
# Runs on the host. Every declared argument arrives as an environment variable:
# id, agent, full.
#
# `listen` follows the session that is running; this reads one that has
# finished, by name, and shows the subagent lines `listen` leaves out — a
# subagent's transcript is made of nothing else, so filtering them there and
# keeping them here is the same rule read from two sides.
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/deployed.sh
. host/lib/archive.sh

if [ "$RUNNER_IS_DEPLOYED" = no ]; then
    typed=("$id")
    [ -z "$subagent" ] || typed+=(--subagent "$subagent")
    typed_flag --full "$full"
    forward_to_deployed read "${typed[@]}"
fi


# --- a number or an id ---
# What tells them apart is the shape, and it has to be a rule a person can hold
# in their head: a listing position is one to three decimal digits, an id
# fragment is hex and at least four characters. Four decimal digits are
# therefore an id and not a position — a list long enough to need one is read
# with `--day` or `--all` and then by id, the durable handle anyway.
# see docs/sessions.md#opening-one-finished-transcript

case "$id" in
    [0-9]|[0-9][0-9]|[0-9][0-9][0-9]) want=position ;;
    *[!0-9a-f]*|?|??|???)
        echo "Usage: just read <number|session-id|agent-id> [--subagent K] [--full]" >&2
        echo "A number is a row of the last 'just sessions' — 1 to 3 digits." >&2
        echo "Anything else is an id, or enough of one: hex, four characters or more." >&2
        exit 2 ;;
    *) want=id ;;
esac


# --- which transcript ---
# A position is counted into the same table `just sessions` prints, from the
# same function, so the number on screen and the number taken here cannot mean
# two different sessions. An id is matched on the file name, never on the whole
# path: a subagent's transcript lives under a directory named for the session
# that spawned it, so a session id matches both.
#
# The archive first, the volume second. The archive holds every transcript ever
# collected, including those of a home that has since been rebuilt; the volume
# holds only what is there now. Where both have a file the bytes are the same,
# except a redacted one — and there the archive's copy is the rewritten one,
# which is the copy anybody should be reading.  see docs/archive.md

pick() {
    printf '%s\n' "$1" | sed '/^$/d' | while IFS= read -r p; do
        case "${p##*/}" in *"$id"*) printf '%s\n' "$p" ;; esac
    done
}

row=""
src=archive
ref=sessions

if [ "$want" = position ]; then
    archive_rows
    ref="$ARCHIVE_REF"
    row=$(printf '%s\n' "$ARCHIVE_ROWS" | sed -n "${id}p")
    [ -n "$row" ] && [ "$id" != 0 ] || {
        echo "No session $id in the archive. Run 'just sessions' for the list." >&2; exit 1; }
    path=$(printf '%s' "$row" | cut -f1)
    listing="$ARCHIVE_FILES"$'\n'"$ARCHIVE_SUBS"
else
    listing=$(git -C "$ARCHIVE" ls-tree -r sessions --name-only -- transcripts 2>/dev/null || true)
    hits=$(pick "$listing")

    # A hit in the archive settles it. No hit falls through to the volume,
    # which is where a session that has not been collected yet lives — the one
    # that just finished, most often.
    if [ -z "$hits" ]; then
        src=volume
        host/lib/docker-up.sh --image "${RUNNER_IMAGE:-$RUNNER_IMAGE_DEPLOYED}" || exit $?
        # Read as the agent: the transcripts are 0600 owned by that uid, so
        # this needs no privilege, and a root container is the one that leaves
        # root-owned files behind. --entrypoint overrides the bootstrap.
        listing=$(docker compose run --rm -T --entrypoint sh agent \
            -c 'find "$HOME/.claude/projects" -name "*.jsonl" 2>/dev/null' 2>/dev/null | tr -d '\r')
        hits=$(pick "$listing")
    fi

    # A session outranks its own subagents. They are filed beside it as
    # `<session-id>--agent-<id>.jsonl`, so the session's id is a prefix of every
    # one of their names. When exactly one hit is not a subagent, that is
    # plainly the thing asked for; ask for a subagent by its own id and this
    # never fires.
    if [ "$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l)" -gt 1 ]; then
        sessions=$(printf '%s\n' "$hits" | grep -v -- '--agent-' || true)
        [ "$(printf '%s\n' "$sessions" | sed '/^$/d' | wc -l)" -eq 1 ] && hits="$sessions"
    fi

    count=$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l)
    if [ "$count" -eq 0 ]; then
        echo "No transcript matching '$id' on sessions in $ARCHIVE, nor in the volume." >&2
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "'$id' matches $count transcripts:" >&2
        printf '%s\n' "$hits" | sed 's|.*/||; s|^|    |' >&2
        echo "Give more of the id." >&2
        exit 2
    fi
    path="$hits"
fi


# --- which subagent, if one was asked for ---
# They are filed beside their session, and nothing in the session's own
# transcript says where: the Agent call shows a prompt going out and one report
# coming back, and everything between is in a file of its own. K is the position
# in the list this prints.

base="${path##*/}"; base="${base%.jsonl}"
mine=$(printf '%s\n' "$listing" | grep -F "/$base--agent-" | sed '/^$/d' || true)
file="$path"

# A subagent read by its own id is already the file in hand and spawned
# nothing itself; the block below and the footer both stop there.
case "$base" in *--agent-*) mine="" ;; esac

agents_list() {
    printf '%s\n' "$mine" | awk -v h="$id" '{ sub(/.*--agent-/, ""); sub(/\.jsonl$/, "")
        printf "  just read %s --subagent %d   (%s)\n", h, NR, $0 }'
}

if [ -n "$subagent" ]; then
    [ -n "$mine" ] || { echo "That session spawned no subagent." >&2; exit 1; }
    file=$(printf '%s\n' "$mine" | sed -n "${subagent}p")
    [ -n "$file" ] || {
        printf 'It spawned %s, and there is no %s:\n' "$(printf '%s\n' "$mine" | wc -l)" "$subagent" >&2
        agents_list >&2
        exit 1
    }
fi


# --- the bytes ---
# Materialised rather than streamed, because two things read them: the header's
# numbers and the render. From the archive that is a blob read twice for
# nothing; from the volume it would be a second container.

cat_transcript() {
    if [ "$src" = archive ]; then
        git -C "$ARCHIVE" show "$ref:$1"
    else
        docker compose run --rm -T -e P="$1" --entrypoint sh agent -c 'cat "$P"' 2>/dev/null
    fi
}

printf 'reading %s\n' "${file##*/}" >&2
printf 'from the %s\n' "$src" >&2

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
cat_transcript "$path" > "$tmp/session"
if [ "$file" = "$path" ]; then body="$tmp/session"
else cat_transcript "$file" > "$tmp/agent"; body="$tmp/agent"
fi

# The row `sessions` would have shown, when this read did not come from that
# table: the session and whatever it spawned in one pass, because their
# requests and their output belong to it.
if [ -z "$row" ]; then
    row=$path$'\t'$({ cat "$tmp/session"
                      for s in $mine; do cat_transcript "$s"; done
                    } | jq -rn -f host/archive/session-meta.jq)
fi


# --- the header ---
# The duration is not in the parenthetical: the second line states it to the
# second, and the same fact twice in two shapes is one of them going stale.
# see docs/sessions.md#opening-one-finished-transcript

header=$(printf '%s' "$row" | awk -F'\t' -v name="${file##*/}" -v blob="$ref:$path" -v src="$src" '
    function toks(n) {
        # + 0.5 because %d truncates and the other half of this pair rounds,
        # and two implementations disagreeing about one session is the bug.
        if (n < 1000) return sprintf("%d", n)
        if (n < 10000) return sprintf("%.1fk", n / 1000)
        if (n < 1000000) return sprintf("%dk", n / 1000 + 0.5)
        return sprintf("%.1fM", n / 1000000)
    }
    function dur(s,   t) {
        t = int(s + 0.5)
        if (t >= 3600) return sprintf("%dh%02dm", t / 3600, (t % 3600) / 60)
        if (t >= 60) return sprintf("%dm%02ds", t / 60, t % 60)
        return sprintf("%ds", t)
    }
    {
        printf "session %s %s  (%s msg, %s)\n  %s\n  %s\n", $2, $3, $5, $6, $15, name
        # Where it can be read again without this recipe. One still only in the
        # volume has no command, and saying so is the point.
        if (src == "archive") printf "  git show %s\n", blob
        else printf "  in the volume — not collected yet\n"
        across = ($9 > 0) ? sprintf(" (+%s across %s agent%s)", $8, $9, ($9 > 1 ? "s" : "")) : ""
        worked = ($14 != "") ? sprintf(", %s generating", dur($14)) : ""
        printf "\n%s requests%s · %s output, %s thinking\n%s end context · %s elapsed%s\n",
               $7, across, toks($10), toks($11), toks($12), dur($13), worked
    }')

# A subagent's header is not its session's: those numbers are the session's
# totals with this subagent's work cumulated into them, and printed over a
# subagent's transcript they would read as its own.
if [ "$file" != "$path" ]; then
    header=$(printf 'subagent %s\n  of session %s %s\n  %s\n' \
        "$(printf '%s' "${file##*/}" | sed 's/.*--agent-//; s/\.jsonl$//')" \
        "$(printf '%s' "$row" | cut -f2)" "$(printf '%s' "$row" | cut -f3)" \
        "${file##*/}")
fi

# What this one spawned, named at the end with the command for each. Only when
# a session was read: a subagent spawns nothing.
footer=""
if [ "$file" = "$path" ] && [ -n "$mine" ]; then
    footer=$(printf '\n'; agents_list)
fi


# --- on screen ---
# Rendered by host/session/transcript.jq, the file `just listen` also includes:
# two spellings of what a message looks like drift, and the one that drifts is
# the one nobody is reading at the moment it does.
#
# The escapes arrive as jq arguments rather than as literals in the program: a
# control character in a source file is invisible to whoever edits it next.
#
# Paged only when someone is watching: piping this into grep or a file must not
# hand the output to less.

dim=$(printf '\033[2m'); bold=$(printf '\033[1m'); off=$(printf '\033[0m')
render=(-L host/session -r --arg dim "$dim" --arg bold "$bold" --arg off "$off"
        --arg runner "$RUNNER_SAYS"
        --arg agent "${AGENT_NAME,,}"
        --arg operator "${OPERATOR_NAME,,}"
        --argjson full "$([ "$full" = yes ] && echo true || echo false)"
        'include "transcript"; select(.type == "assistant" or .type == "user") | render')

show() {
    printf '%s\n' "$header"
    jq "${render[@]}" < "$body"
    [ -n "$footer" ] && printf '%s\n' "$footer"
    return 0
}

if [ -t 1 ]; then show | less -R; else show; fi
