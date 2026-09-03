# shellcheck shell=bash
# shellcheck disable=SC2154  # the lowercase names here are collect.sh's, which
# sources this file; shellcheck reads a sourced fragment on its own and cannot
# see the caller that assigns them.
#
# What is held back, why, and what the run actually read.
#
# Sourced by host/archive/collect.sh. It sets `held` and defines `held_note`
# for the archive stage, prints one report per held transcript on stderr, takes
# the held files out of the staging copy so the rest can be archived, and ends
# on what the run read.
# see docs/archive.md#the-held-back-report


# --- what a reader at the bottom of a log needs ---
# Said again at the end: the report scrolls off behind the archiving output,
# and an unattended log is read from the bottom.

held=0

held_note() {
    [ "$held" -gt 0 ] || return 0
    echo
    echo "$held transcript(s) held back and NOT archived — see above. They stay in"
    echo "the volume and will be offered again next time."
}


# --- the held-back report ---

if [ -n "$(printf '%s' "$unreviewed" | tr -d '[:space:]')" ]; then
    held=$(printf '%s\n' "$unreviewed" | sed '/^$/d' | wc -l)

    # Held back, not refusing. Prose describing a key trips the scan exactly
    # like a key does, and an archive that stops on every such session never
    # runs unattended — then the record it exists to keep is what goes missing.
    # The guarantee is unchanged: nothing credential-shaped reaches the archive
    # unreviewed.  see docs/archive.md#the-held-back-report
    printf '\n%s\n' "HELD BACK — credential-shaped content, not yet reviewed:" >&2
    printf '%s\n' "$unreviewed" | sed '/^$/d' | sed 's/^/    /' >&2

    # One report per held file, the credential comparison in particular: that
    # check is the whole difference between "a fixture" and "a leak", and a file
    # it never reaches is ruled on from its hash alone.
    # see docs/archive.md#one-report-per-held-file
    #
    # Whether anyone is watching. The whole report goes to stderr, so that is
    # the descriptor to ask about, and it is decided here rather than in
    # passages.py, whose own stdout is a command substitution whatever the
    # terminal is doing.
    if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then emphasis=ansi; else emphasis=plain; fi

    # Where the verbatim layer found something, for the passage display — the
    # third source of positions there, beside the floor's matches and gitleaks'
    # report, which passages.py reads off disk itself. Truncated by each write,
    # so one file serves every pass of the loop.
    spots=$(mktemp)
    # What the credential comparison concluded, for the ruling commands below.
    # Emptied before each call, so a check that died leaves no verdict rather
    # than the previous file's.
    why=$(mktemp)

    # Both fields, not just the path: the hash is what a ruling names, and
    # the report is the only place it is ever shown.
    printf '%s\n' "$unreviewed" | sed '/^$/d' \
    | while read -r hash rel; do
        held_file="$staging/$rel"
        printf '\n%s\n' "── $rel" >&2

        # ---- is it actually a credential ----
        # The shape says "this looks like a key" and cannot say whether it is
        # one, which is the entire question being put to the operator. Asking
        # someone to rule on that from a passage of base64 is asking them to be
        # a cryptanalyst; the machine can simply check, so it does — and it says
        # which credential, through the same needles.py the gate above used.
        # see docs/archive.md#one-definition-of-a-credentials-outward-shape
        printf '%s\n' "Checked against the real credentials:" >&2
        : > "$why"
        verdict=$(printf '%s' "$volume_secrets" \
            | python3 host/archive/check.py "$held_file" "$spots" "$why" 2>&1 || true)
        printf '%s\n' "${verdict:-    (the volume could not be read — nothing was compared)}" >&2

        # ---- what objected ----
        #
        # The run is described, not erased, by shapes.py: how long it is, and a
        # little from each end. Masking it outright hides exactly the evidence
        # being asked for, because "a body of gibberish" is a run of twenty-plus
        # base64 characters — the mask and the criterion are the same shape.
        # see docs/archive.md#describing-a-run-instead-of-erasing-it
        #
        # `|| true` is load-bearing here as in detect(): grep exits 1 when it
        # matches nothing, which happens whenever gitleaks is the only objector.
        printf '\n%s\n' "What matched:" >&2
        matched=$(grep -aoE "$patterns" "$held_file" 2>/dev/null \
            | python3 host/archive/shapes.py | sort | uniq -c | head -6 || true)
        objection="the verbatim comparison"
        if [ -n "$matched" ]; then
            printf '%s\n' "$matched" | sed 's/^/    /' >&2
            # The first shaped match, without uniq's count column. One line,
            # because this becomes a note in a one-line ledger.
            objection="the pattern floor matched $(printf '%s' "$matched" | head -1 | sed 's/^ *[0-9]* *//')"
        else
            # gitleaks reads shapes the floor does not, so it can be the only
            # objector — and then it is the only account there is.
            rules=$(python3 host/archive/findings.py "$report" "$held_file" 2>/dev/null || true)
            # And neither of them may have anything to say, because the
            # verbatim layer objects to shapes no rule describes — that is what
            # it is for. An empty heading here reads as "nothing was found",
            # which is the opposite of what has happened.
            if [ -n "$rules" ]; then
                printf '%s\n' "$rules" >&2
                # Its count dropped and the rest kept, exactly as the floor's
                # own line above: the rule id is what someone would look up
                # later and the field it named is what they ruled on.
                objection=$(printf '%s' "$rules" | head -1 | sed 's/^ *[0-9]* *//')
            else
                printf '%s\n' \
                    "    nothing shape-shaped — the verbatim comparison above is the objector" >&2
            fi
        fi

        # ---- and where it appears ----
        #
        # Telling the operator to read a JSONL file is not asking for a review,
        # it is asking them to be a parser. passages.py prints the sentence —
        # who said it, when, and what surrounds it — which is what makes "this
        # is prose about a key, not a key" a judgement anyone can make in a
        # glance.
        #
        # Positions come from all three objectors, and must: the verbatim layer
        # describes no shape at all, so when it is the only one objecting the
        # other two have nothing to report.
        # see docs/archive.md#one-passage-per-place
        printf '\n%s\n' "Where it appears, in words:" >&2
        context=$(EMPHASIS="$emphasis" python3 host/archive/passages.py \
            "$held_file" "$patterns" "$report" "$spots" 2>&1 || true)
        if [ -n "$context" ]; then
            printf '%s\n' "$context" >&2
        else
            printf '%s\n' "    (no objector left a position to quote)" >&2
        fi

        # ---- the ruling commands ----
        #
        # Prefilled, and under the transcript they rule on rather than once at
        # the bottom: a 64-character hash copied from the wrong paragraph rules
        # on a file nobody was looking at.
        #
        # The note is the record, so a default must not write a judgement nobody
        # made. It carries the evidence instead — what objected, and what the
        # comparison against the real credentials concluded — a sentence that
        # stays true whatever the operator decides.
        #
        # A default only where it is safe to have one: where a real credential
        # was found, --approve keeps its placeholder, because a ready excuse
        # under a line reading A REAL CREDENTIAL IS IN THIS FILE is the one
        # thing this must not offer. A check that did not run gets neither.
        # see docs/archive.md#the-default-note-carries-evidence-not-a-judgement
        verdict_kind=$(cut -f1 "$why" 2>/dev/null | head -1)
        verdict_names=$(cut -f2 "$why" 2>/dev/null | head -1)
        verdict_can=$(cut -f3 "$why" 2>/dev/null | head -1)

        # No quote can reach the command line: the note is printed inside
        # double quotes, and one in the middle of it is a line that pastes as
        # something else. Nor a `$`, a backtick or a backslash — the note can
        # carry gitleaks' `Match`, which is a piece of the transcript, and a
        # double-quoted string is not inert about those three. What the
        # operator pastes must be the ruling they read.
        objection=$(printf '%s' "$objection" | tr -d '"$\\`')
        verdict_names=$(printf '%s' "$verdict_names" | tr -d '"$\\`')
        clear_why="why it is nothing"
        redact_why="what was in it"
        case "$verdict_kind" in
            shape-only) clear_why="$objection; no secret from the volume appears in it" ;;
            alarm)      redact_why="$objection; it holds the $verdict_names" ;;
        esac

        # Twelve characters of the hash, not all sixty-four. It still names the
        # bytes that were reviewed — the resolver takes a prefix of eight or
        # more and refuses an ambiguous one — and it fits on the line beside the
        # note. The full hash is in the HELD BACK list above.
        printf '\n%s\n' "Ruling on this one — asked only once, and it may be pasted beside others:" >&2
        printf '    just collect --approve  %s "%s"\n' "${hash:0:12}" "$clear_why" >&2

        # Offered only when it can work. A file holding neither a whole
        # credential nor a shape match cannot be redacted, and asking anyway
        # rewrites nothing, fails the proof, drops the ruling and offers the
        # same transcript again next run — for ever. The shape half of the test
        # is `$matched`, which the shell knows and check.py does not; the
        # volume half is the third field of "$why".
        # see docs/archive.md#offering-redaction-only-when-it-can-work
        if [ -n "$matched" ] || [ "$verdict_can" = redactable ]; then
            printf '    just collect --redact %s "%s"\n' "${hash:0:12}" "$redact_why" >&2
        else
            printf '%s\n' "    --redact is NOT offered here: it has nothing to name in this file. It" >&2
            printf '%s\n' "    replaces whole credentials the volume holds and what the shape rules" >&2
            printf '%s\n' "    match, and neither is present — the objection is a fragment. Asking for" >&2
            printf '%s\n' "    it would rewrite nothing, fail the proof, and hold this file again." >&2
        fi
    done
    rm -f "$spots" "$why"

    cat >&2 <<GUIDANCE

Those are not archived. Everything else is.

The passage above usually settles it: a key has a body of gibberish after
the header, and prose about a key reads like a sentence. Each ruling is
recorded in the same commit as the transcript it rules on, and each is asked
once — the volume's copy never changes, so later collections apply it on
their own without asking again.

IT IS NOTHING — the guard's own fixtures, a test key of the agent's, an issue
quoting a header, an identifier the vault happens to hold. --approve archives
it as it stands.

IT IS REAL, and the session is still worth keeping. --redact archives it with
the credential rewritten out, leaving a marker where it was.

Both commands are printed under the transcript they rule on, with its hash
already in them. The note is not optional in either: a record nobody can
account for later is worse than none.

REDACTING IS NOT ROTATING. It rewrites what reaches the archive from here;
it does nothing about a copy already pushed to origin, and nothing about a
credential that is still valid. Rotate first, then rule on the transcript.
GUIDANCE

    # Out of the staging copy, so the rest can go. The originals are
    # untouched in the volume and will be offered again next time.
    printf '%s\n' "$unreviewed" | sed '/^$/d' | awk '{print $2}' \
        | while read -r rel; do rm -f "$staging/$rel"; done
fi

rm -f "$report" 2>/dev/null || true


# --- what the run read ---
# Whenever that is not what was found. "Clean" over every transcript and
# "Clean" over the three anything looked at are different sentences, and only
# one is true after a skip; a run that read nothing does not make the claim.
#
# An `if` and not `[ ... ] && read_note=...`: a test that fails is a non-zero
# status, and under `set -e` at the end of a statement that is the end of the
# run.  see docs/archive.md#what-the-run-says-about-it

read_note=""
if [ "$pruned" -gt 0 ]; then
    read_note=" ($left read, $pruned already settled)"
fi

if [ "$left" -eq 0 ]; then
    :
elif [ "$cleared_count" -gt 0 ]; then
    echo "Clean$read_note — $cleared_count transcript(s) matched but are recorded as reviewed."
else
    echo "Clean$read_note."
fi
