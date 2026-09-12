# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # a sourced fragment is read on its own, with
# neither the caller that assigns the lowercase names here nor the later stages
# that read what this one leaves behind.
#
# The gate: what a credential looks like, and which transcripts trip it.
#
# Sourced by host/archive/collect.sh. It sets `patterns`, defines `detect`,
# skips whatever the archive already holds the answer for, runs the scan, and
# leaves `flagged_at` — one `<sha256>\t<path>\t<session id>` line per transcript
# the gate objects to.
#
# A transcript carries every command's output verbatim, so it is the likeliest
# place here for a credential to appear. A hit stops the run: silent redaction
# would hide the incident that matters more than the file does.
# see docs/archive.md#the-gate


# --- the shape rules ---
# The floor is built in host/archive/floor.sh, sourced here and by the verify
# probes that ask whether its anchored rules still catch what they were written
# for: two readers of one floor, and only one copy of it. It sets `patterns` —
# the shapes true of every installation, plus whatever image/config/secret-shapes.txt
# adds for this one.
# see docs/archive.md#the-gate

# shellcheck source=SCRIPTDIR/floor.sh
. host/archive/floor.sh


# --- what the scan accumulates ---
# The explicit `return 0` is not decoration: ending on `[ -n "$1" ] &&` makes
# the function return 1 when there is nothing to add, and under `set -e` that
# kills the script where it stands, silently.
# see docs/archive.md#shell-traps-this-file-records

cleared_count=0
pending=""
flagged=""
to_redact=""

note_flagged() {
    [ -n "$1" ] && flagged=$(printf '%s\n%s' "$flagged" "$1")
    return 0
}


# --- the gate, as one function ---
# The three layers together: the pattern floor, the verbatim comparison that
# needles.py builds out of the volume's own secrets, and gitleaks, the second
# opinion, which reads shapes the floor does not. Its findings carry the file
# they are in, which is what lets one ruling answer all three. --config because
# the default private-key rule fires on an armour pair with no body at all; the
# path is relative because root.sh has already cd'd to the repository root.
# see docs/archive.md#what-gitleaks-is-told
#
# Run twice: once over the staging copy as it came out of the volume, and again
# over whatever a `--redact` has just rewritten, since a redaction that missed
# a second occurrence must not read as success.
#
# Prints one path per line. The gitleaks report goes to $2 because the held-back
# report reads it back for rules and positions.

detect() {
    local where="$1" report_at="$2" found="" rc=0

    # `|| true` on each: grep exits 1 when it matches nothing, which is the
    # normal case, and under `set -o pipefail` that would kill the run here.
    # see docs/archive.md#shell-traps-this-file-records
    found=$(grep -rEl --binary-files=text "$patterns" "$where" 2>/dev/null || true)

    # `-F`, so one pass over every transcript reads all the needles at once
    # rather than one pass per secret.
    found="$found
$(printf '%s' "$volume_secrets" | python3 host/archive/needles.py \
    | grep -rlFf - --binary-files=text "$where" 2>/dev/null || true)"

    if [ "$GITLEAKS" = true ]; then
        set +e
        gitleaks detect --config host/archive/gitleaks.toml \
            --source "$where" --no-git --redact --exit-code 1 \
            --report-format json --report-path "$report_at" >/dev/null 2>&1
        rc=$?
        set -e
        # 0 clean, 1 findings. Anything else is gitleaks failing to run,
        # which must not read as "found nothing".
        [ "$rc" -le 1 ] || die "gitleaks could not run (exit $rc). Nothing was committed."
        # The report is kept until the held-back report has read it: when the
        # pattern floor matches nothing, which is most of the time, gitleaks'
        # rule and line are the only account of what was found.
        found="$found
$(python3 -c '
import json, sys
try:
    print("\n".join(sorted({f["File"] for f in json.load(open(sys.argv[1]))})))
except Exception:
    pass' "$report_at" 2>/dev/null || true)"
    fi

    printf '%s\n' "$found" | sed '/^$/d' | sort -u
}


# --- whether the second opinion is installed ---
# Asked once and remembered, so the hint is printed once however many times the
# gate runs. No version numbers in the message: a number written into one ages
# silently and then misinforms.

GITLEAKS=false
if command -v gitleaks >/dev/null 2>&1; then
    GITLEAKS=true
else
    cat <<'HINT'
gitleaks not installed — the pattern floor ran alone. To add its second
opinion, either:

    sudo apt install gitleaks         # easy; Ubuntu's build lags upstream

or take the current release, which is usually several minor versions ahead:

    https://github.com/gitleaks/gitleaks/releases   (gitleaks_*_linux_x64.tar.gz)
    tar xzf gitleaks_*_linux_x64.tar.gz gitleaks && mv gitleaks ~/.local/bin/

HINT
fi


# --- what has already been through this gate ---
# A transcript already on `sessions` byte for byte has reached origin, so
# reading it again cannot hold anything back — only cost, and that cost grows
# with the volume's retention rather than with the session that just ended. A
# redacted transcript settles on its ledger entry instead, its bytes never
# matching.
# see docs/archive.md#it-agrees-with-gits-own-object-id
#
# That holds whatever the gate has become since. A rule added later meets the
# archived transcripts through `just collect --scan-archive`, which reads the
# archive itself and can only report: what is there is already published.
# see docs/archive.md#what-is-on-origin-is-not-read-again
#
# A ruling does not force a full read. The skip removes transcripts already in
# the archive byte for byte, and a transcript waiting to be ruled on is by
# definition not in it — it was held back — so the one file a ruling can name
# is the one file the skip can never take. What catches the case a full read
# was guarding: a ruling that resolves to nothing refuses and lists what is
# actually held, and one naming a settled transcript says so.
# see docs/archive.md#a-ruling-does-not-force-a-full-read

pruned=0
# Not when the archive is what is being read: every file in it is already archived.
if [ "$SCAN_ARCHIVE" = false ]; then
    # Listed and removed in two steps, never in one: archived.py removing files
    # as it walked would leave a half-pruned staging directory if it died
    # partway, and those files would be neither read nor archived.
    already=""
    if [ -n "$archive_ref" ]; then
        # The `redact` rulings, so a transcript whose rewrite is already
        # archived settles like one whose bytes are — its bytes can never
        # match, since the volume keeps the original on purpose.
        rulings=$(mktemp)
        # Path first, hash second — the opposite of the ledger's own order:
        # two transcripts with identical bytes is not far-fetched here, and a
        # map keyed on the hash drops one of their rulings without a word.
        reviewed | awk -F'  +' '$2 == "redact" { print $3 "\t" $1 }' > "$rulings"
        already=$(git -C "$ARCHIVE" ls-tree -r "$archive_ref" -- transcripts 2>/dev/null \
            | sed 's/^[0-7]* blob //' \
            | python3 host/archive/archived.py "$staging" "$layout" "$rulings") || already=""
        rm -f "$rulings"
    fi
    if [ -n "$already" ]; then
        pruned=$(printf '%s\n' "$already" | wc -l)
        printf '%s\n' "$already" | while IFS= read -r rel; do rm -f "$staging/$rel"; done
    fi
fi


# --- what is being read, and the reading ---
# "as this run would archive them" and not "unchanged": a settled redaction is
# archived rewritten, so its bytes are deliberately not what the volume holds.
# What is true of both is that reading them again would produce what is there.
#
# Nothing left to read is its own sentence, and the scanning heading is not
# printed above it: a run that says "scanning", then "reading 0", then "clean"
# has described three things that did not happen.
# see docs/archive.md#what-the-run-says-about-it

left=$((found - pruned))
if [ "$left" -eq 0 ]; then
    printf 'All %s are already archived as this run would archive them. Nothing to read.\n' "$found"
elif [ "$pruned" -gt 0 ]; then
    printf '%s of them are already archived as this run would archive them — reading %s.\n' \
        "$pruned" "$left"
fi
if [ "$left" -gt 0 ]; then
    echo "Scanning for credentials ..."
fi

report=$(mktemp)
note_flagged "$(detect "$staging" "$report")"


# --- what is flagged ---
# The sha256 a ruling is keyed on, the path the ledger records, and the session
# id, the last only so a refusal can name the file the way the report's heading
# does.
#
# A ruling names the hash, or an unambiguous start of it, and deliberately not
# the session id: a transcript that grew between the report and the ruling
# matches nothing and is offered again, while a session id would go on naming
# the file and rule on content nobody read.
# see docs/archive.md#a-ruling-names-the-hash

flagged_at=""
for f in $(printf '%s\n' "$flagged" | sed '/^$/d' | sort -u); do
    [ -f "$f" ] || continue
    h=$(sha256sum "$f" | cut -d' ' -f1)
    rel=${f#"$staging"/}
    id=${rel##*/}; id=${id%.jsonl}
    flagged_at="${flagged_at:+$flagged_at
}$(printf '%s\t%s\t%s' "$h" "$rel" "$id")"
done
