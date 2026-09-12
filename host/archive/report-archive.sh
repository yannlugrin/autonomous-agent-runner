# shellcheck shell=bash
# shellcheck disable=SC2154  # the lowercase names here are collect.sh's and
# scan.sh's; shellcheck reads a sourced fragment on its own and cannot see them.
#
# The last stage of `just collect --scan-archive`: what matched, among what is
# already published.
#
# Sourced by host/archive/collect.sh after scan.sh, and it ends the run: 0 when
# nothing unreviewed matched, 1 when something did. Nothing is held back and
# nothing is rewritten — every file here is already on origin, so a match is a
# credential to rotate, not a transcript to rule on. One the ledger approved
# matches again by design, and is counted rather than reported.
# see docs/archive.md#what-is-on-origin-is-not-read-again

to_rotate=0
approved=0

while IFS=$'\t' read -r hash rel id; do
    [ -n "$hash" ] || continue
    if [ "$(ruling "$hash")" = clear ]; then
        approved=$((approved + 1))
        continue
    fi
    to_rotate=$((to_rotate + 1))
    printf '\n%s\n' "── $rel"

    # Which credential, when it is one, named and never printed: the verbatim
    # layer describes no shape, so without this a match it alone found says
    # nothing at all. Positions and the ruling verdict are not wanted here.
    # see docs/archive.md#one-report-per-held-file
    printf '%s\n' "Checked against the vault's secrets:"
    printf '%s' "$volume_secrets" \
        | python3 host/archive/check.py "$staging/$rel" /dev/null /dev/null 2>&1 || true

    # What objected, the way the held-back report says it: the floor's matches
    # described rather than printed, then gitleaks' rules.
    # see docs/archive.md#describing-a-run-instead-of-erasing-it
    matched=$(grep -aoE "$patterns" "$staging/$rel" 2>/dev/null \
        | python3 host/archive/shapes.py | sort | uniq -c | head -6 || true)
    if [ -n "$matched" ]; then printf '%s\n' "$matched" | sed 's/^/    /'; fi
    rules=$(python3 host/archive/findings.py "$report" "$staging/$rel" 2>/dev/null || true)
    if [ -n "$rules" ]; then printf '%s\n' "$rules"; fi
    printf '    just read %s\n' "${id:0:8}"
done <<< "$flagged_at"

rm -f "$report" 2>/dev/null || true

echo
if [ "$to_rotate" -eq 0 ]; then
    echo "Clean — $found archived transcript(s) read, $approved matched and are recorded as reviewed."
    exit 0
fi

cat <<ROTATE
$to_rotate archived transcript(s) match the gate as it stands, and they are already
on origin. Nothing here can take a pushed copy back, and --redact rewrites only
what reaches the archive from now on: rotate what each one carries.
ROTATE
exit 1
