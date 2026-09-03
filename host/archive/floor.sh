# shellcheck shell=bash
# shellcheck disable=SC2034  # `patterns` is read by whoever sources this.
#
# The pattern floor: what a credential looks like, as one extended regular
# expression, built in one place.
#
# Sourced by host/archive/scan.sh, which runs it over every transcript, and by
# host/verify/mechanical.sh, which asks the anchored rules whether they still
# catch what they were written for. One builder, because a probe that retypes
# the floor is the copy that goes stale while still passing.
#
# Sets `patterns` and runs nothing else. The working directory is the checkout:
# host/lib/root.sh has already cd'd there.
# see docs/archive.md#the-gate


# --- the shapes true of every installation ---
# A rule that fires on ordinary prose is a rule that gets switched off, and then
# it is not there on the day it matters. That is why public keys are absent —
# the bootstrap prints one on purpose — and why a key must be a header and a
# body.
#
# The body may sit behind a real newline or a JSON-escaped one, and here it is
# always the latter: a JSON string cannot hold a literal newline, so anything
# armoured inside one arrives on a single line where grep can see it whole.
#
# Written in the dialect both readers share: this string goes to `grep -E` and
# to python's `re` in redact.py and passages.py, and `[[:space:]]` is a POSIX
# class only the first understands — python reads it as the set of letters in
# "space" and quietly matches something else.

patterns='BEGIN [A-Z ]*PRIVATE KEY-----(\\n| )*[A-Za-z0-9+/]{32,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9-]{16,}|AKIA[0-9A-Z]{16}'


# --- and what this installation adds ---
# image/config/secret-shapes.txt holds the shapes of the secrets this agent holds
# because of what it does — a forum's key format, a feed token, a webhook URL.
# They are the operator's and not this repository's, so they are untracked;
# image/bash-guard.py adds the same lines to its own floor, from the copy baked
# into the image.
#
# Appended, never replacing. An absent file adds nothing, which is what a fresh
# installation has, and everything above still runs.
#
# One rule per line, the note after a `#` dropped with it. An `if` rather than a
# `&&` at the end of the body: under `set -e` a loop ending on a false test
# kills the script where it stands.
# see docs/archive.md#shell-traps-this-file-records

added=$(awk '{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "") print }' \
    image/config/secret-shapes.txt 2>/dev/null || true)

while IFS= read -r rule; do
    if [ -n "$rule" ]; then patterns="$patterns|$rule"; fi
done <<< "$added"
