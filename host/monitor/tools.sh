#!/usr/bin/env bash
# Count tool calls per day in the archived session transcripts.
#
# Runs on the host, reads the archive's `sessions` ref and nothing else. With no
# tool named: one line per tool, one column per day, the last 5 days that carry
# a call. Name tools and the table transposes: one line per day, one column per
# named tool, the last 10 days. `--days N` sets the window in either shape.
#
# Days are the last ones that carry a tool call, counted in UTC from the call's
# own timestamp, so a session running past midnight lands on both sides; one
# day's directory beyond the window is read because a session filed under D-1
# can still hold calls stamped D.  see docs/monitor.md#just-tools
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"
. host/lib/archive.sh
. host/lib/tty.sh

days="${days:?not set — run this through 'just', which declares the flags}"
names=("$@")
if [ "$days" = 0 ]; then
    if [ ${#names[@]} -eq 0 ]; then days=5; else days=10; fi
fi

need_archive
archive_ref


mapfile -t dirs < <(git -C "$ARCHIVE" ls-tree -r --name-only "$ARCHIVE_REF" -- transcripts \
    | sed 's|^transcripts/||; s|/[^/]*$||' | sort -u | tail -n "$((days + 1))")
[ ${#dirs[@]} -gt 0 ] || { echo "No transcripts under transcripts/ on $ARCHIVE_REF." >&2; exit 1; }

raw=$(mktemp) || exit 1
trap 'rm -f "$raw"' EXIT
for d in "${dirs[@]}"; do
    git -C "$ARCHIVE" ls-tree -r --name-only "$ARCHIVE_REF" -- "transcripts/$d/"
done | while read -r path; do
    git -C "$ARCHIVE" show "$ARCHIVE_REF:$path"
done | jq -r 'select(.type=="assistant") | .timestamp as $t
              | .message.content[]? | select(.type=="tool_use")
              | "\(.name)\t\($t[0:10])"' \
  | sort | uniq -c | sed 's/^ *//; s/ /\t/' > "$raw"

keep=$(cut -f3 "$raw" | sort -u | tail -n "$days" | paste -sd,)
[ -n "$keep" ] || { echo "No tool calls in the last $days day(s) the archive holds."; exit 0; }
nd=$(( $(tr -cd , <<< "$keep" | wc -c) + 1 ))

if [ ${#names[@]} -eq 0 ]; then
    # Tools down the side, days across the top, heaviest tool first.
    {
        awk -F'\t' -v keep="$keep" '
            BEGIN { nd = split(keep, D, ",")
                    for (i = 1; i <= nd; i++) K[D[i]] = 1
                    printf "tool"
                    for (i = 1; i <= nd; i++) printf "\t%s", substr(D[i], 6)
                    print "\ttotal" }
            ($3 in K) { c[$2 SUBSEP $3] += $1; t[$2] += $1 }
            END { for (k in t) {
                      printf "%s", k
                      for (i = 1; i <= nd; i++) printf "\t%d", c[k SUBSEP D[i]] + 0
                      printf "\t%d\n", t[k] } }' "$raw" \
        | { IFS= read -r header; printf '%s\n' "$header"
            sort -t$'\t' -k$((nd + 2)),$((nd + 2)) -rn; }
        awk -F'\t' -v keep="$keep" '
            BEGIN { nd = split(keep, D, ",")
                    for (i = 1; i <= nd; i++) K[D[i]] = 1 }
            ($3 in K) { col[$3] += $1; all += $1 }
            END { printf "total"
                  for (i = 1; i <= nd; i++) printf "\t%d", col[D[i]] + 0
                  printf "\t%d\n", all }' "$raw"
    } | column -t -s$'\t' | zebra
else
    # Days down the side, the named tools across the top, in the order given.
    want=$(printf '%s,' "${names[@]}"); want=${want%,}
    awk -F'\t' -v keep="$keep" -v want="$want" '
        BEGIN { nd = split(keep, D, ",")
                nt = split(want, T, ",")
                for (i = 1; i <= nd; i++) K[D[i]] = 1
                for (j = 1; j <= nt; j++) W[T[j]] = 1
                printf "day"
                for (j = 1; j <= nt; j++) printf "\t%s", T[j]
                print "\ttotal" }
        ($3 in K) && ($2 in W) { c[$3 SUBSEP $2] += $1; col[$2] += $1; all += $1 }
        END { for (i = 1; i <= nd; i++) {
                  printf "%s", substr(D[i], 6); row = 0
                  for (j = 1; j <= nt; j++) {
                      n = c[D[i] SUBSEP T[j]] + 0; row += n
                      printf "\t%d", n }
                  printf "\t%d\n", row }
              printf "total"
              for (j = 1; j <= nt; j++) printf "\t%d", col[T[j]] + 0
              printf "\t%d\n", all + 0 }' "$raw" \
    | column -t -s$'\t' | zebra

    for n in "${names[@]}"; do
        cut -f2 "$raw" | grep -qxF -- "$n" \
            || echo "note: no call to '$n' anywhere in the days read" >&2
    done
fi
