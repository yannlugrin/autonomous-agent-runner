#!/usr/bin/env bash
# The pre-commit hooks over the whole tree, then mypy.
#
# Runs on the host, no arguments. Each check says ok or FAIL itself and the
# count at the end is what a person reads; the exit status is what CI reads.
# An absent .venv is a FAIL and not a skip: a check that quietly did not run is
# the shape this repository is written against.
# see docs/release.md#setup-the-project-local-venv-and-the-lint-set
#
# shellcheck disable=SC2015  # `tool && verdict ok || verdict FAIL` is the whole
# idiom here: the tool is the A, and there is no C that could run after a
# successful ok — verdict returns zero.
set -uo pipefail
# shellcheck source=SCRIPTDIR/../lib/root.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/root.sh"

ok=0; fail=0

verdict() {
    if [ "$1" = ok ]; then ok=$((ok + 1)); printf '[ ok ] %s\n' "$2"
    else fail=$((fail + 1)); printf '[FAIL] %s\n' "$2"; fi
}


# --- the pinned tools ---

# The hooks, all of them, at the versions .pre-commit-config.yaml pins — the
# one list, so this command, the commit hook and CI cannot run different
# checks or different versions. shellcheck in particular: the apt one on a CI
# runner is a version behind the pinned one and reports what it does not.
if [ -x .venv/bin/pre-commit ]; then
    .venv/bin/pre-commit run --all-files && verdict ok "pre-commit hooks" || verdict FAIL "pre-commit hooks"
else
    verdict FAIL "pre-commit — .venv is absent or incomplete, run 'just setup'"
fi
# Not a hook: mypy is too slow for every commit, and it is here and in CI.
if [ -x .venv/bin/mypy ]; then
    .venv/bin/mypy && verdict ok "mypy" || verdict FAIL "mypy"
else
    verdict FAIL "mypy — .venv is absent or incomplete, run 'just setup'"
fi


# --- the count ---

echo
echo "$ok ok, $fail FAIL"
[ "$fail" -eq 0 ]
