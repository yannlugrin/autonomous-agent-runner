#!/usr/bin/env bash
# Prove the session records are sufficient — that every command still to be
# normalised onto them can be rendered from them alone, byte for byte.
#
# Runs on the host, reads the archive and the store, writes nothing but a
# temporary directory. `just records --prove`.
#
# THIS IS THE ONE OBLIGATION OF THE STORE. The change that added the records
# moved no command onto them: `just sessions`, `just read`, `just tools` and
# `just cost` still read the transcripts, and each becomes a renderer over the
# store in a later, separate piece of work. What has to be true today is that
# the store will be enough when that happens — and a field missing from a record
# is not otherwise discovered until that later session is halfway through
# rewriting a command, by which time the store is published and its shape is
# awkward to change.
#
# So each command is run as it stands, host/monitor/records-render.py renders
# the same output from the records alone, and the two are diffed. A difference
# is a field the store does not carry, or carries differently.
#
# Every check says ok or FAIL for itself and the exit is non-zero if any failed:
# this is read by a person, not by a wrapper.
# see docs/monitor.md#the-sufficiency-proof
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/archive.sh

STORE="${RUNNER_RECORDS_DIR:?not set — run this through 'just', which derives it}"
render() { host/monitor/records-render.py "$@"; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

failed=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; failed=$((failed + 1)); }


# --- judge ---
# judge <name> <what the command printed> <what the records rendered>. On a
# difference it shows the head of it: a diff of 579 rows scrolled past is not a
# report.

judge() {
    if cmp -s "$2" "$3"; then
        ok "$1"
        return 0
    fi
    bad "$1 — $(diff "$2" "$3" | grep -c '^[<>]') line(s) differ"
    diff -u "$2" "$3" | sed -n '3,20p' | sed 's/^/          /'
    return 1
}


# --- what has to be true before any of this means anything ---
# The records are sealed against origin/sessions and the commands read the local
# `sessions` branch. While the two differ they are reading different archives,
# and every difference below would be that rather than a missing field.

need_archive
archive_ref

local_sha=$(git -C "$ARCHIVE" rev-parse "$ARCHIVE_REF" 2>/dev/null)
origin_sha=$(git -C "$ARCHIVE" rev-parse refs/remotes/origin/sessions 2>/dev/null)
if [ "$local_sha" != "$origin_sha" ]; then
    echo "'$ARCHIVE_REF' and origin/sessions are not the same commit." >&2
    echo "A record is sealed against origin and the commands read $ARCHIVE_REF, so a" >&2
    echo "difference here would be that and not a missing field. 'just collect --push'." >&2
    exit 1
fi

pending=$(host/monitor/session-records.py --pending)
if [ "$pending" != 0 ]; then
    echo "$pending session(s) on origin/sessions have no record yet." >&2
    echo "The proof covers the whole archive. 'just records' seals what it can;" >&2
    echo "a session seals once the mirror and the status branch have moved past it." >&2
    exit 1
fi

# A sub-agent whose session is not on the branch. It happens: a sub-agent
# finishes and is collected while the conversation that spawned it runs on, and
# on 2026-09-03 one sat there for sixteen hours. `just cost` and `just tools`
# read every file in a day's directory and so count it; the store has no record
# for it, because it is not a session and its session has not landed yet.
orphans=$(git -C "$ARCHIVE" ls-tree -r --name-only "$ARCHIVE_REF" -- transcripts \
    | grep '\.jsonl$' | awk -F/ '
        { name = $NF; sub(/\.jsonl$/, "", name)
          if (name ~ /--agent-/) { split(name, p, "--agent-"); side[p[1]] = name }
          else main[name] = 1 }
        END { for (s in side) if (!(s in main)) print side[s] }')
if [ -n "$orphans" ]; then
    echo "Sub-agent transcript(s) on $ARCHIVE_REF whose session is not:" >&2
    printf '%s\n' "$orphans" | sed 's/^/    /' >&2
    echo >&2
    echo "'just cost' prices each of those as a session of its own and the store has" >&2
    echo "no record until the session lands — so the two cannot agree while one is" >&2
    echo "outstanding. Collect again once the session has ended." >&2
    exit 1
fi

# What the archive was when the checks began. This takes minutes, a session can
# end inside that, and `just collect --push` then moves the branch out from
# under the commands while the store stays where it was — which reads as four
# failures and is none. Compared again at the verdict.
began=$local_sha

printf 'Proving the store against %s — %s record(s).\n\n' \
    "$ARCHIVE_REF" "$(find "$STORE" -name '*.json' | wc -l)"


# --- the table both listings are a pure function of ---
# host/lib/archive.sh builds one row per session, and `just sessions` and
# `just read` are both rendered from it. Proved first because a difference here
# names the field, where a difference in the output below names a column.

printf '%s\n' "the session table (host/lib/archive.sh)"
archive_rows
printf '%s\n' "$ARCHIVE_ROWS" > "$work/rows.want"
render rows > "$work/rows.got"
judge "archive_rows, every session" "$work/rows.want" "$work/rows.got"


# --- just sessions --all ---

printf '\n%s\n' "just sessions --all"
all=yes day="" host/archive/sessions.sh > "$work/sessions.want" 2>/dev/null
render sessions --ref "$ARCHIVE_REF" > "$work/sessions.got"
judge "the listing, its footnotes and its numbering" "$work/sessions.want" "$work/sessions.got"


# --- just read <id> ---
# The header is printed before the transcript is rendered, so `head` closes the
# pipe on the render and each read costs the header alone. The footer sits after
# the transcript and is taken in full, from the sessions that have one.

printf '\n%s\n' "just read <id>"
heads=0; foots=0; subs=0; broke=""

reads() { id="$1" subagent="$2" full=no RUNNER_IS_DEPLOYED=yes \
          host/session/read.sh </dev/null 2>/dev/null; }

while IFS= read -r path; do
    [ -n "$path" ] || continue
    # `just read` takes a hex fragment of an id and a full uuid has dashes in
    # it, so the handle is the first segment — which is what anybody types.
    id=$(basename "$path" .jsonl); id=${id%%-*}

    render read "$id" --ref "$ARCHIVE_REF" > "$work/head.got"
    n=$(grep -c '' "$work/head.got")
    reads "$id" "" | head -n "$n" > "$work/head.want"
    if cmp -s "$work/head.want" "$work/head.got"; then heads=$((heads + 1))
    else broke="$broke $id"; fi

    render read "$id" --ref "$ARCHIVE_REF" --footer > "$work/foot.got"
    n=$(grep -c '' "$work/foot.got")
    [ "$n" -gt 0 ] || continue

    reads "$id" "" | tail -n "$n" > "$work/foot.want"
    if cmp -s "$work/foot.want" "$work/foot.got"; then foots=$((foots + 1))
    else broke="$broke $id/listing"; fi

    k=1
    while render read "$id" --ref "$ARCHIVE_REF" --subagent "$k" > "$work/sub.got" 2>/dev/null; do
        reads "$id" "$k" | head -n "$(grep -c '' "$work/sub.got")" > "$work/sub.want"
        if cmp -s "$work/sub.want" "$work/sub.got"; then subs=$((subs + 1))
        else broke="$broke $id/subagent-$k"; fi
        k=$((k + 1))
    done
done < <(printf '%s\n' "$ARCHIVE_FILES")

if [ -z "$broke" ]; then
    ok "$heads header(s), $foots sub-agent listing(s), $subs sub-agent header(s)"
else
    bad "these do not match:$broke"
fi


# --- just tools ---
# Both shapes, over every day the archive holds: the window is counted in day
# directories, so the number of them covers all.

printf '\n%s\n' "just tools"
window=$(printf '%s\n' "$ARCHIVE_FILES" | sed 's|^transcripts/||; s|/[^/]*$||' | sort -u | wc -l)

days="$window" host/monitor/tools.sh > "$work/tools.want" 2>/dev/null
render tools -d "$window" > "$work/tools.got"
judge "one line per tool, one column per day" "$work/tools.want" "$work/tools.got"

named=(Bash Read Edit Agent WebFetch)
days="$window" host/monitor/tools.sh "${named[@]}" > "$work/named.want" 2>/dev/null
render tools -d "$window" "${named[@]}" > "$work/named.got"
judge "one line per day, one column per named tool" "$work/named.want" "$work/named.got"


# --- just cost ---
# Rendered by feeding the records into image/session-cost.py's own printing, so
# what this proves is that the store carries everything that file needs.

printf '\n%s\n' "just cost"
by_day=no days="$window" host/monitor/cost.sh > "$work/cost.want" 2>/dev/null
render cost -d "$window" --ref "$ARCHIVE_REF" > "$work/cost.got"
judge "one line per session, where it went, who spent it" "$work/cost.want" "$work/cost.got"

by_day=yes days="$window" host/monitor/cost.sh > "$work/day.want" 2>/dev/null
render cost --by-day -d "$window" --ref "$ARCHIVE_REF" > "$work/day.got"
judge "one line per day" "$work/day.want" "$work/day.got"

# By id, on the two shapes that are wrong in different ways when they are wrong:
# a session that delegated, and one whose only model the price table refuses.
# A shape this archive does not hold is SAID rather than skipped: a check that
# quietly did not run reads exactly like one that passed.

by_id() {
    if [ -z "$2" ]; then
        printf '  --    %s — no such session in this archive\n' "$1"
        return 0
    fi
    by_day=no days=0 host/monitor/cost.sh "$2" > "$work/one.want" 2>/dev/null
    render cost --ref "$ARCHIVE_REF" "$2" > "$work/one.got" 2>/dev/null
    judge "$1 — ${2}" "$work/one.want" "$work/one.got"
}

by_id "a session that delegated" "$(render rows | awk -F'\t' -v most=0 '
    $9 > most { most = $9; who = $1 } END { print who }' | sed 's|.*/||; s|\.jsonl$||; s|-.*||')"
by_id "a model the price table refuses" "$(grep -rl '"<synthetic>"' "$STORE" \
    | head -1 | xargs -r basename | sed 's|\.json$||; s|-.*||')"


# --- the verdict ---

printf '\n'
if [ "$began" != "$(git -C "$ARCHIVE" rev-parse "$ARCHIVE_REF")" ]; then
    printf 'INCONCLUSIVE — %s moved while this ran: a session ended and was collected.\n' \
        "$ARCHIVE_REF"
    printf 'The commands read the new archive and the store is still the old one, so\n'
    printf 'any difference above is that. Run it again once the session has sealed.\n'
    exit 1
fi

if [ "$failed" -eq 0 ]; then
    printf 'The store is sufficient: every command above renders from the records alone.\n'
    exit 0
fi
printf '%d check(s) failed. Each difference above is a field the store does not carry,\n' "$failed"
printf 'or carries differently from the command that reads the transcript.\n'
exit 1
