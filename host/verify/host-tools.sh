# shellcheck shell=bash
# Host tools — what this repository invokes on the machine `just` runs on,
# and the `just` a scheduled run would resolve.
#
# Host-side and first, because a missing tool here explains every failure
# below it. Only what this repository actually invokes: a list nobody believes
# is a list nobody reads. `need` and `spare` live in lib.sh.
# see docs/verify.md#host-tools

echo "== host tools =="


# --- docker, git, jq, python3 ---

need docker  "nothing in this repository runs"
need git     "just pin, and the archive worktree just collect commits in"
need jq      "just listen renders nothing"
need python3 "just pin, the classifier check and the guard's own selftest"


# --- flock, crontab ---
# Not "the lock stops working": lock_try is `flock -n 9`, and a missing binary
# exits 127, which reads as "held" — so every run stands down, hourly and in
# silence. see docs/verify.md#a-missing-flock-reads-as-a-held-lock

need flock   "every run would read the lock as held and skip, hourly and silently"
need crontab "just schedule cannot report or change the unattended session"


# --- date -d ---
# Behaviour, not presence: BSD date has no -d, and session_started then
# returns nothing, so a waiting run calls a live session wedged. A wrong
# answer, not a missing one. see docs/verify.md#behaviour-not-presence

if date -u -d "2026-08-23T01:02:03.000000000Z" +%s >/dev/null 2>&1; then
    verdict ok "date -d" "accepts ISO timestamps"
else
    verdict FAIL "date -d" "REJECTS ISO timestamps — the wait display would call a live session wedged"
fi


# --- gh, gitleaks, fuser, systemctl ---
# Optional by design. `gh` is the one that costs something real: without it no
# session end dispatches the mirror, which looks like nothing at all until a
# rewrite upstream is lost.

spare gh        "no session end asks the archive to mirror; only its schedule does"
spare gitleaks  "just collect runs its pattern floor alone"
spare fuser     "the hint run prints when the lock is held with nothing running"
spare systemctl "just schedule cannot say whether cron is actually running"


# --- cron just ---
# The `just` a scheduled run would use, which is not the one you typed this
# with: the crontab line carries its own PATH, and a justfile using a feature
# that version predates dies at parse time — hourly, before any recipe runs,
# into a log nobody is reading. `set minimum-version` is read out of the
# justfile so there is one place the number is declared. LOOK where nothing is
# scheduled: no crontab line is a correct state.
# see docs/verify.md#the-just-a-scheduled-run-would-use

just_min=$(sed -n "s/^set minimum-version := ['\"]\([^'\"]*\)['\"].*/\1/p" justfile | head -1)

# The marker `just schedule` writes, matched on its shape rather than its
# wording: an exact match would report a line that is installed and running as
# absent. see docs/schedule.md

cron_line=$(crontab -l 2>/dev/null | awk -v p="# ${COMPOSE_PROJECT_NAME}:" '
    index($0, p) == 1 && index($0, "installed by just schedule") > 0 { pair = 1; next }
    pair { print; exit }')

cron_path=""
case "$cron_line" in *' PATH='*) cron_tail="${cron_line#* PATH=}"; cron_path="${cron_tail%% *}" ;; esac
cron_just=$(env -i PATH="$cron_path" sh -c 'command -v just' 2>/dev/null)
cron_ver=$(env -i PATH="$cron_path" just --version 2>/dev/null | cut -d' ' -f2)

if [ -z "$just_min" ]; then
    verdict FAIL "cron just" "THE JUSTFILE DECLARES NO MINIMUM — 'set minimum-version' is what an old just fails on with a sentence instead of a parse error"
elif [ -z "$cron_line" ]; then
    verdict LOOK "cron just" "nothing scheduled — no crontab line here, so no PATH to resolve a just on; the justfile asks for $just_min"
elif [ -z "$cron_path" ]; then
    verdict LOOK "cron just" "the installed line carries no PATH= — cron's own bare PATH decides, and this cannot say which just that finds"
elif [ -z "$cron_just" ]; then
    verdict FAIL "cron just" "NO just ON THE CRONTAB LINE'S PATH ($cron_path) — every scheduled run dies before the recipe"
elif [ -z "$cron_ver" ]; then
    verdict FAIL "cron just" "$cron_just ANSWERED NOTHING to --version, and it is what cron runs"
elif [ "$(printf '%s\n%s\n' "$just_min" "$cron_ver" | sort -V | head -1)" != "$just_min" ]; then
    verdict FAIL "cron just" "TOO OLD — cron resolves $cron_just at $cron_ver and the justfile asks for $just_min; a scheduled run fails at parse time, hourly and silently"
else
    verdict ok "cron just" "$cron_just at $cron_ver, on the crontab line's own PATH, meets the justfile's $just_min"
fi
