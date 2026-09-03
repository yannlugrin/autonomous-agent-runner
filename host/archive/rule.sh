# shellcheck shell=bash
# shellcheck disable=SC2154  # the lowercase names here are collect.sh's, which
# sources this file; shellcheck reads a sourced fragment on its own and cannot
# see the caller that assigns them.
#
# The rulings: what `--approve` and `--redact` resolve to, and what is still
# waiting.
#
# Sourced by host/archive/collect.sh. It turns `$RULINGS` into `resolved`,
# splits everything the gate flagged into `cleared_count`, `to_redact` and
# `unreviewed`, answers `--held` and stops there, and carries out the
# redactions with the proof that they held.
# see docs/archive.md#rulings-and-the-ledger


# --- what is still waiting ---
# A ruling that names nothing is a refusal, not a no-op: writing no entry
# silently leaves the run printing the same held files again, one line longer
# than the reader was looking at. Ambiguity is refused rather than resolved to
# the first match, since the wrong transcript approved is a credential pushed
# to origin. A refusal lists only what is actually waiting — `flagged_at` holds
# every transcript the gate objects to, most of them settled long ago.
# see docs/archive.md#a-ruling-that-names-nothing-is-a-refusal

held_list() {
    printf '%s\n' "$flagged_at" | while IFS="$(printf '\t')" read -r h rel id; do
        [ -n "$h" ] || continue
        [ -n "$(ruling "$h")" ] || printf '    %s  %s\n' "$h" "$id"
    done
}


# --- what each ruling names ---

resolved=""
while IFS="$(printf '\t')" read -r verb what why; do
    [ -n "$verb" ] || continue
    hits=$(printf '%s\n' "$flagged_at" | awk -F'\t' -v w="$what" '
        $1 == w || (length(w) >= 8 && index($1, w) == 1)')
    count=$(printf '%s' "$hits" | grep -c . || true)

    # Already ruled on is a repeat, not a mistake — a command pasted twice, or
    # a second run of a script. Refusing here would stop a run that has nothing
    # wrong with it.
    if [ "$count" -eq 0 ]; then
        was=$(reviewed | awk -v w="$what" '
            $1 == w || (length(w) >= 8 && index($1, w) == 1) {
                print (($2 == "redact") ? "redact" : "clear"); exit }')
        if [ -n "$was" ]; then
            printf 'Already ruled on (%s): %s. The ledger settles it; nothing to record.\n' \
                "$was" "$what"
            continue
        fi
    fi

    if [ "$count" -eq 0 ]; then
        printf '\n%s\n' "NOTHING TO RULE ON: --$verb names '$what', which is not the hash of" >&2
        printf '%s\n' "any transcript held back. Nothing was recorded and nothing was committed." >&2
        printf '%s\n' "A ruling names the HASH — all of it, or its first eight characters or" >&2
        printf '%s\n' "more. A session id is not accepted: it would still name the file after" >&2
        printf '%s\n' "the session had grown, and rule on bytes nobody reviewed." >&2
        if [ -n "$(held_list | tr -d '[:space:]')" ]; then
            printf '%s\n' "Held now:" >&2
            held_list >&2
        else
            printf '%s\n' "Nothing is held back at all: every transcript is already settled." >&2
        fi
        exit 1
    fi

    if [ "$count" -gt 1 ]; then
        printf '\n%s\n' "AMBIGUOUS: --$verb names '$what', which is the start of $count of them:" >&2
        printf '%s\n' "$hits" | awk -F'\t' '{ printf "    %s  %s\n", $1, $3 }' >&2
        printf '%s\n' "Nothing was recorded. Name more of the hash." >&2
        exit 1
    fi

    h=$(printf '%s' "$hits" | cut -f1)
    case "$resolved" in
        *"$h	"*) printf '\n%s\n' "TWO RULINGS ON ONE TRANSCRIPT: '$what' resolves to $h, which is" >&2
                  printf '%s\n' "already ruled on in this run. Nothing was recorded." >&2
                  exit 1 ;;
    esac
    resolved="${resolved:+$resolved
}$(printf '%s\t%s\t%s' "$h" "$verb" "$why")"
done <<< "$(printf '%s\n' "$RULINGS" | sed '/^$/d')"


# --- what each flagged transcript's verdict is ---
# The ledger first, then a ruling made in this run. Recorded, not merely waved
# past: the entry goes into the same commit as the transcript, so the archive
# says why this one was allowed in.

unreviewed=""
while IFS="$(printf '\t')" read -r h rel id; do
    [ -n "$h" ] || continue
    verb=$(ruling "$h")

    if [ -z "$verb" ]; then
        given=$(printf '%s\n' "$resolved" | awk -F'\t' -v h="$h" '$1 == h { print $2 "\t" $3; exit }')
        if [ -n "$given" ]; then
            verb=$(printf '%s' "$given" | cut -f1)
            why=$(printf '%s' "$given" | cut -f2)
            case "$verb" in
                approve) pending="${pending:+$pending
}$(printf '%s  approve  %s  # %s' "$h" "$rel" "$why")" ;;
                redact) pending="${pending:+$pending
}$(printf '%s  redact  %s  # %s' "$h" "$rel" "$why")" ;;
            esac
        fi
    fi

    case "$verb" in
        clear)  cleared_count=$((cleared_count + 1)) ;;
        redact) to_redact=$(printf '%s\n%s  %s' "$to_redact" "$h" "$rel") ;;
        *)      unreviewed=$(printf '%s\n%s  %s' "$unreviewed" "$h" "$rel") ;;
    esac
done <<< "$(printf '%s\n' "$flagged_at" | sed '/^$/d')"


# --- the count, without the collection ---
# `just status` asks the gate for this rather than carrying its own copy of the
# scan. It stops here — nothing staged, no worktree, no commit — so it is safe
# to run beside a live session, and it prints one machine-shaped line rather
# than leaving a caller to take the tail, which would be the gitleaks hint.
# see docs/archive.md#the-count-without-the-collection

if [ "$HELD" = true ]; then
    printf 'waiting-on-review: %s\n' \
        "$(printf '%s\n' "$unreviewed" | sed '/^$/d' | wc -l)"
    exit 0
fi


# --- redaction ---
# The third ending, for a transcript that carries a real credential and is
# still worth keeping. The objection stated at the gate is to redacting
# silently, and it says nothing against a redaction asked for by name, with a
# note, written into the record.  see docs/archive.md#the-third-ending
#
# redact.py runs from the same two definitions detect does: the whole forms of
# what the volume holds, and what the shape rules match. Not from gitleaks,
# which under --redact reports `Secret: REDACTED` — a finding only gitleaks can
# see is not redactable from the report, and the proof below says so out loud
# rather than archiving a file it could not rewrite.
#
# A redaction by position is possible and is deliberately not done here: the
# operator's ruling to make, not a gap to close quietly.
# see docs/archive.md#redaction-by-position-deliberately-not-done
#
# The ruling is remembered, so this is asked once and never again. The entry is
# keyed on the hash of the transcript as it sits in the volume, and that copy is
# never touched — so every later collection recognises it, redacts it again on
# its own and archives it without a word.

if [ -n "$(printf '%s' "$to_redact" | tr -d '[:space:]')" ]; then
    while read -r h rel; do
        [ -n "$rel" ] || continue
        n=$(printf '%s' "$volume_secrets" | python3 host/archive/redact.py \
            "$staging/$rel" "$patterns" || echo 0)
        # Only for a ruling made in this run, which `$resolved` holds. A
        # remembered one is re-applied on every collection for as long as the
        # transcript exists, and announcing that for ever reads as something
        # happening when nothing is. Nothing is lost by the silence: a
        # redaction that removed too little is caught by the proof below.
        # see docs/archive.md#the-ruling-is-remembered-and-re-applied-in-silence
        if printf '%s\n' "$resolved" | grep -q "^$h	"; then
            printf 'Redacted %s occurrence(s) in %s\n' "$n" "$rel"
        fi
    done <<< "$(printf '%s\n' "$to_redact" | sed '/^$/d')"

    # The proof, and the part that is not optional: the same gate runs again
    # over the rewritten copies, since a redaction that missed a second
    # occurrence must not read as success.
    #
    # A file that still trips it goes back to being held and the ledger entry
    # this run would have written is dropped, so a ruling that cannot be carried
    # out is not recorded as though it had been. With an entry from an earlier
    # run there is nothing to drop and the file stays held, loudly: the gate
    # sees something the redactor cannot name, and that is the operator's
    # decision rather than a state to paper over.
    # see docs/archive.md#the-proof
    after=$(detect "$staging" "$report")
    while read -r h rel; do
        [ -n "$rel" ] || continue
        printf '%s\n' "$after" | grep -qxF "$staging/$rel" || continue
        printf '\n%s\n' "REDACTION DID NOT HOLD — $rel is still flagged after rewriting." >&2
        printf '%s\n' "It stays out of the archive. Either the gate sees a shape the redactor" >&2
        printf '%s\n' "cannot name — a gitleaks-only finding has no bytes to replace — or the" >&2
        printf '%s\n' "credential is in a form the volume no longer holds. Rule on it with" >&2
        printf '%s\n' "--approve if it is nothing, and widen the rule if it is not." >&2
        unreviewed=$(printf '%s\n%s  %s' "$unreviewed" "$h" "$rel")
        # Its own line, not the whole list: a run may carry several rulings,
        # and dropping all of them because one redaction did not hold would
        # silently discard rulings that did.
        pending=$(printf '%s\n' "$pending" | grep -v "^$h" || true)
    done <<< "$(printf '%s\n' "$to_redact" | sed '/^$/d')"
fi
