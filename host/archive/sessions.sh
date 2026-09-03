#!/usr/bin/env bash
# Archived sessions, newest first — the listing, and nothing else. `just read`
# is what opens one, by its number here or by its own id.
#
# Runs on the host, against the archive checkout. Every declared argument
# arrives as an environment variable: the flags all and day.
#
# It only reads. `sessions` is written by `just collect --push` and by nothing
# else; the branch is read with `git show`, never checked out, so the archive
# clone stays on whatever branch it is on.  see docs/archive.md#the-listing
#
# shellcheck disable=SC2154  # the recipe's declared arguments reach this
# script as exported environment variables, which shellcheck cannot see; a
# name that is not among them is caught by `set -u` on the first read.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/archive.sh


# --- what was asked for ---
# A day is matched as a substring, so `--day 08-26` and `--day 2026-08-26` both
# work — one of the two is what anybody types and guessing which would be wrong
# half the time. It is the local day the session started, which is what a person
# means by "yesterday"; the archive files under the UTC day, so the two part
# company either side of midnight and the footnote below says so.
#
# `page` is a screenful: what fits above the prompt on an ordinary terminal with
# the header and the footnotes.

page=20

case "$day" in
    ''|2[0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]|[01][0-9]-[0-3][0-9]) ;;
    *) echo "--day wants a local day: --day 08-26, or --day 2026-08-26." >&2; exit 2 ;;
esac

archive_rows
total=$(printf '%s\n' "$ARCHIVE_ROWS" | wc -l)


# --- the footnotes ---
# Every one of them is a thing you would otherwise go on not knowing: a
# transcript nothing could date, a collection that never left this machine, and
# a day on screen that is not the day in the path.

printf '%s\n' "$ARCHIVE_REF — $total session(s), newest first"

# Counted rather than dropped in silence: an undated transcript would otherwise
# sit at the top of the list with no day against it.
elsewhere=$(printf '%s\n' "$ARCHIVE_FILES" | grep -c '^transcripts/undated/' || true)
[ "$elsewhere" -gt 0 ] && printf '%s\n' \
    "  $elsewhere transcript(s) carry no timestamp and are filed under undated/"

# `just collect` commits without pushing unless told to, so a transcript that is
# only on this machine is the normal way they pile up.
if [ "$ARCHIVE_REF" = sessions ] && git -C "$ARCHIVE" rev-parse --verify --quiet origin/sessions >/dev/null; then
    behind=$(git -C "$ARCHIVE" rev-list --count origin/sessions..sessions)
    [ "$behind" -gt 0 ] && printf '%s\n' \
        "  $behind collection(s) not pushed — 'just collect --push'"
fi

# The row is the local day the session started, the path is the UTC day the
# archive filed it under, and either side of midnight those differ. Read off the
# path rather than carried as a second field: the path is the archive's own
# answer, and the one printed beside a session when you read it.
#   see docs/archive.md#where-the-clock-and-the-path-part-company
shifted=$(printf '%s\n' "$ARCHIVE_ROWS" | awk -F'\t' '
    { split($1, p, "/"); if (p[2] "-" p[3] != $2) c++ }
    END { print c + 0 }')
[ "$shifted" -gt 0 ] && printf '%s\n' \
    "  $shifted started on a different UTC day than the local one shown — the path beside a read says which"


# --- the table ---
# Numbered before anything is dropped: the number is a handle into the whole
# list, so `just read 137` means the same thing whether or not 137 was on
# screen. The date is carried in the first field so a day can be picked out
# afterwards without re-deriving it.
#
# +N marks a session that spawned subagents. Nothing else on the row says they
# exist — their messages and tokens are cumulated into the session's — and it
# has its own column rather than being appended to the ragged title.
#   see docs/archive.md#a-subagent-is-not-a-session

lines=$(printf '%s\n' "$ARCHIVE_ROWS" | awk -F'\t' '{
    mark = ($9 > 0) ? "+" $9 : ""
    printf "%s\t  %3d  %s %s  %5s  %4s msg  %-3s %-4s  %s\n",
           $2, NR, $2, $3, $4, $5, mark, $6, $15 }')

note=""
if [ -n "$day" ]; then
    shown=$(printf '%s\n' "$lines" | awk -F'\t' -v d="$day" 'index($1, d)')
    [ -n "$shown" ] || { echo "No session started on $day, local. 'just sessions' lists them." >&2; exit 1; }
    note="$(printf '%s\n' "$shown" | wc -l) on $day, of $total"
elif [ "$all" = yes ]; then
    shown="$lines"
else
    shown=$(printf '%s\n' "$lines" | head -n "$page")
    older=$((total - $(printf '%s\n' "$shown" | wc -l)))
    [ "$older" -gt 0 ] && note="$older older not shown — --all, or --day 08-26"
fi

[ -n "$note" ] && printf '  %s\n' "$note"

# Said only when one is on screen: a legend for a column that is empty on every
# row explains nothing, and this list has no column headings for it to sit under.
printf '%s\n' "$shown" | grep -q 'msg  +' && printf '  %s\n' \
    "+N marks subagents — 'just read <number> --agent K' reads one"


# --- on screen ---
# Paged only when someone is watching, and only when there is more than a
# screenful: piping this into grep or a file must not hand the output to less,
# and neither must a list of six.

out=$(printf '%s\n' "$shown" | cut -f2-
      printf '\n%s\n' "Read one:  just read <number>   or  just read <id>")

echo
if [ -t 1 ] && [ "$(printf '%s\n' "$out" | wc -l)" -gt "$page" ]; then
    printf '%s\n' "$out" | less -R
else
    printf '%s\n' "$out"
fi
