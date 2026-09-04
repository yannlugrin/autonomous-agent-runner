# shellcheck shell=bash
# The budget guard as this host has it configured. Its arithmetic is proved
# offline by --selftest, which `just build` runs; what is asked here is the
# setting and whether the thresholds are read at all.
#
# No live verdict, deliberately: the endpoint is read by `just run` and `just
# chat` at the moment a session would begin, and by nothing that merely checks.
# What that costs, said rather than discovered: nothing here proves the gate can
# reach the endpoint, or that the renewal path works. The first failed run says
# both, loudly, on stderr where cron finds it.
# see docs/verify.md#the-budget-guard-on-this-host

echo "== budget guard, on this host =="


# --- budget guard ---
# What it is set to, and what a session would therefore be told — different
# questions, since the vocabulary is tolerant: `yes` arms the guard and a
# session is told `true`, and a value neither empty nor recognised is off,
# silently. LOOK when it is off, never FAIL: whether the operator's week is
# rationed is their ruling. see docs/budget.md

case "${ACCOUNT_BUDGET_GUARD:-}" in
    true) verdict ok   "budget guard" "[true] — armed; a session is told true" ;;
    '')   verdict LOOK "budget guard" "[] — OFF; a session is told false, and nothing here refuses one" ;;
    *)    verdict LOOK "budget guard" "[${ACCOUNT_BUDGET_GUARD}] — only exactly \`true\` arms it, so this is OFF" ;;
esac


# --- bad threshold ---
# That the thresholds are read at all. A gate that ignored its configuration
# would go on answering, correctly, from whatever it had, and the only symptom
# would be a budget nobody was enforcing. So a threshold it cannot parse must
# be a refusal to answer and never a permissive default.
# see docs/verify.md#bad-threshold

ACCOUNT_BUDGET_WEEKLY_CAP=nonsense python3 ./image/claude-usage.py --env >/dev/null 2>&1
rc=$?

if [ $rc -eq 2 ]; then
    verdict ok "bad threshold" "refuses to answer rather than falling back to a permissive default"
else
    verdict FAIL "bad threshold" "ANSWERED ANYWAY — the thresholds are not being read"
fi


# --- nothing left ---
# That the line the exhaustion floor reads is still printed. The floor is not
# the budget: it refuses a session against a window at 100% whether or not the
# guard is armed, and it reads one line of `--env` output to do it. If that
# line stopped being printed — a rename, a refactor — BUDGET_EXHAUSTED stays
# empty, the floor is simply gone, and nothing anywhere says so. `--selftest`
# proves `exhausted()` the function; this proves the line.
# see docs/verify.md#nothing-left

# Only on a reading that reached a verdict. The tool deliberately prints no
# EXHAUSTED line where it could not read — an unreadable account is not an
# exhausted one — so a host without a usage-reading login would otherwise fail
# this for doing exactly the right thing.
env_out=$(python3 ./image/claude-usage.py --env 2>/dev/null)
case $? in
0|75)
    if printf '%s' "$env_out" | grep -q '^EXHAUSTED='; then
        verdict ok "nothing left" "the --env output still carries EXHAUSTED=, which the floor reads"
    else
        verdict FAIL "nothing left" "NO EXHAUSTED LINE — the floor that refuses an exhausted window reads nothing"
    fi
    ;;
*)
    verdict LOOK "nothing left" "usage could not be read here, so the line the floor reads was not checked"
    ;;
esac

echo
