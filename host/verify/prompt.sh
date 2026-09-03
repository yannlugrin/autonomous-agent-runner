# shellcheck shell=bash
# What every session is told about its situation, rendered in the twin and
# read from outside. Sourced by host/verify/verify.sh.
#
# A placeholder the renderer cannot fill is invisible from inside a session —
# the model reads a literal placeholder name and has no way to know what it
# should have said — so this is proved from outside. Under --entrypoint,
# because the twin's entrypoint stops at bootstrap with an empty home and
# rendering needs neither a credential nor a checkout.
# see docs/verify.md#the-system-prompt-render

echo
echo "== system prompt render (no session) =="


# --- prompt render ---
# --render fills the template and prints it, and refuses on a placeholder it
# could not fill. Its exit status is what this reads; the three checks below
# only run on a render that succeeded.

rendered=$(docker compose run --rm -T --entrypoint /usr/local/bin/claude-session agent-test --render 2>&1)
rc=$?

if [ $rc -ne 0 ]; then
    verdict FAIL "prompt render" "REFUSED — $(printf '%s' "$rendered" | tail -1)"
else

    # --- prompt model ---
    # The model line the session is told, against the key managed settings
    # ask for. Template drift is invisible from inside a session.

    line=$(printf '%s\n' "$rendered" | grep -m1 '^Model requested by configuration: ')

    # shellcheck disable=SC2154  # $want is read once, in host/verify/verify.sh
    case "$line" in
        *": $want") verdict ok "prompt model" "the session is told '$want', which is the key in managed settings" ;;
        "")         verdict FAIL "prompt model" "NO MODEL LINE — the template lost it; managed settings ask for '$want'" ;;
        *)          verdict FAIL "prompt model" "the session is told '${line##*: }' while managed settings ask for '$want'" ;;
    esac


    # --- prompt commit ---
    # That the template still carries the commit line, and nothing about its
    # value: this render goes through --entrypoint, so the renamed variable is
    # not there to read and the line renders "the image does not say" whatever
    # the image holds. What it was built from is proved in image-commit.sh. A
    # line dropped from the template leaves no symptom at all — the renderer
    # refuses on a placeholder it cannot fill, never on one nobody wrote.

    if printf '%s' "$rendered" | grep -q '^Container built from runner commit: '; then
        verdict ok "prompt commit" "the template still tells a session which commit built its image"
    else
        verdict FAIL "prompt commit" "NO COMMIT LINE — the template lost it, and a session is told nothing about which version it runs"
    fi


    # --- retention ---
    # How long transcripts survive, asked of the image rather than of the tree:
    # the committed managed-settings.json carries a placeholder and a number
    # only after the build renders it. Reported and not only compared, because
    # the number is a ruling — an .env that lost the variable builds clean on
    # Claude Code's own default of 30 and nothing else would say so.
    #
    # What it cannot prove is that Claude Code still honours the key, which
    # wants re-measuring after an upgrade: a sweep that stopped reading managed
    # settings is silent until the day the files are gone. see docs/boundary.md

    days=$(docker compose run --rm -T --entrypoint jq agent-test \
               -r '.cleanupPeriodDays // "absent"' \
               /etc/claude-code/managed-settings.json 2>/dev/null | tr -d '\r')
    line=$(printf '%s\n' "$rendered" | grep -m1 '^Transcripts kept for (days): ')

    case "$line" in
        *": $days") verdict ok "retention" "managed settings keep transcripts ${days} day(s) and the session is told the same number" ;;
        "")         verdict FAIL "retention" "the template lost the retention line; managed settings say ${days:-UNREADABLE} day(s) and a session is told nothing" ;;
        *)          verdict FAIL "retention" "managed settings say ${days:-UNREADABLE} day(s), the session is told '${line##*: }'" ;;
    esac
fi
