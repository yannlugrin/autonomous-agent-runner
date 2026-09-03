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

echo
