# shellcheck shell=bash
# shellcheck disable=SC2154  # the lowercase names here are collect.sh's, which
# sources this file; shellcheck reads a sourced fragment on its own and cannot
# see the caller that assigns them.
#
# The ledger of what has already been ruled on, for reading.
#
# Sourced by host/archive/collect.sh. It sets `LEDGER` and `archive_ref` and
# defines `reviewed` (the whole ledger) and `ruling <hash>` (one verdict, or
# nothing). The writing half is in host/archive/archive.sh, because an entry
# goes into the same commit as the transcript it rules on.
# see docs/archive.md#the-ledger-and-where-it-lives


# --- what the ledger is ---
# It sits on `sessions`, beside the transcripts it describes, and is written by
# `just collect` and nothing else — so that branch keeps the single writer its
# README claims for it. Read with `git show`, because `sessions` is an orphan
# branch nobody checks out.
#
# A ruling is per file, and the hash is of the transcript's contents: one that
# grows is offered for review again, and one whose session has ended hashes the
# same for ever, so the ledger answers for it without asking.
#
# Two verbs, and the reader has to tell them apart. Entries are
#
#     <sha256>  approve  <path>  # why      archive it as it stands
#     <sha256>  redact  <path>  # why      rewrite the credential out, then archive
#
# and an entry with no verb at all is an old one, which reads as `clear`. A
# reader that looked at the hash alone would read a redaction as a clearance
# and archive the file whole, key and all, silently.
# see docs/archive.md#two-verbs-and-telling-them-apart

LEDGER=reviewed-transcripts.txt


# --- where `sessions` is, for reading ---
# The local branch, or the remote's when this clone has never checked it out: a
# fresh clone has only `origin/sessions`, and `git show sessions:...` fails
# there because git's DWIM looks under `refs/remotes/sessions`. The ledger then
# comes back empty, and an empty ledger is not "nothing has ever been ruled on".
# Empty when the branch exists nowhere yet, which is the first collection into
# a fresh archive and reads as "no ledger, nothing archived" — both true.
# see docs/archive.md#where-sessions-is-for-reading
#
# host/archive/archive.sh resolves the same three cases separately, because it
# checks the branch out with a different flag for each.

archive_ref=""
if git -C "$ARCHIVE" show-ref --quiet --verify "refs/heads/$BRANCH"; then
    archive_ref="$BRANCH"
elif git -C "$ARCHIVE" show-ref --quiet --verify "refs/remotes/origin/$BRANCH"; then
    archive_ref="origin/$BRANCH"
fi


# --- reading it ---

reviewed() {
    [ -n "$archive_ref" ] || return 0
    git -C "$ARCHIVE" show "$archive_ref:$LEDGER" 2>/dev/null || true
}

ruling() {
    reviewed | awk -v h="$1" '$1 == h { print ($2 == "redact") ? "redact" : "clear"; exit }'
}
