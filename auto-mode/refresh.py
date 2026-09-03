#!/usr/bin/env python3
"""Compare the shipped classifier rules against the pinned baseline.

The capture, auto-mode/shipped-<version>.json, holds Anthropic's own rule texts,
reproduced from `claude auto-mode defaults` for review and not covered by this
repository's licence.

    python3 auto-mode/refresh.py              read them from the test twin
    python3 auto-mode/refresh.py --from F     compare a capture you already have

Run this after every Claude Code upgrade. The rules ship with the binary, so an
upgrade can add, reword or remove one without anything here noticing — and the
arrays in managed settings are FULL REPLACEMENTS, which decides what that costs:

  a rule the release ADDED     never reaches the classifier, because our arrays
                               do not contain it and nothing says so. This is
                               the quiet one, and the reason to run this at all.
  a rule the release CHANGED   ships in our wording, not theirs. Sometimes right
                               — twelve of ours are deliberate rewrites — and
                               sometimes a fix we are holding out of.
  a rule the release REMOVED   goes on shipping from our copy, addressing
                               something the vendor no longer thinks is a risk.

It reads and reports; it never rewrites the baseline. Refreshing the pin is a
decision — it means re-reading AUTO-MODE.md's dispositions against the new set,
which is the work this only tells you is owed.
"""

import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import decisions as D  # noqa: E402 — path set above

SECTIONS = (("allow", "A", D.ALLOW), ("soft_deny", "S", D.SOFT), ("hard_deny", "H", D.HARD))


def title(text):
    return text.split(":")[0].split("[")[0].strip().replace("**", "")


def capture():
    """The twin: no volume, no login, no session lock, and it spends nothing."""
    print("reading the shipped rules from the test twin…", file=sys.stderr)
    r = subprocess.run(
        ["just", "test-env", "claude", "auto-mode", "defaults"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        env={**__import__("os").environ, "AGENT_SKIP_CLONE": "1"},
    )
    if r.returncode != 0:
        sys.exit(f"could not read the twin's rules:\n{r.stderr[-800:]}")
    start = r.stdout.find("{")
    if start < 0:
        sys.exit("the twin printed no JSON")
    return json.loads(r.stdout[start:])


def main():
    if "--from" in sys.argv:
        now = json.loads(Path(sys.argv[sys.argv.index("--from") + 1]).read_text())
    else:
        now = capture()
    base = json.loads((HERE / D.SHIPPED).read_text())

    print(f"baseline: {D.SHIPPED}")
    drift = False
    for key, letter, disp in SECTIONS:
        old, new = base[key], now[key]
        common = min(len(old), len(new))
        changed = [i + 1 for i in range(common) if old[i] != new[i]]
        added = list(range(common + 1, len(new) + 1))
        removed = list(range(common + 1, len(old) + 1))
        if not (changed or added or removed):
            print(f"  {key:11} {len(new):3} rules — unchanged")
            continue
        drift = True
        print(
            f"  {key:11} {len(new):3} rules — "
            f"{len(added)} added, {len(removed)} removed, {len(changed)} reworded"
        )
        for n in added:
            print(f"      + {letter}-{n} {title(new[n - 1])}")
            print("        NO DISPOSITION — it will not ship until decisions.py rules on it")
        for n in removed:
            state = disp.get(n, ("?", ""))[0]
            print(f"      - {letter}-{n} {title(old[n - 1])}  (ours says {state})")
        for n in changed:
            state = disp.get(n, ("?", ""))[0]
            note = (
                "we ship our own text, so their change does not reach the agent"
                if state == "TWEAK"
                else "we ship their text, so this changes what the agent is told"
                if state == "KEEP"
                else "dropped here, so their change costs nothing"
            )
            print(f"      ~ {letter}-{n} {title(new[n - 1])}  ({state}: {note})")

    env_old, env_new = base["environment"], now["environment"]
    if env_old != env_new:
        drift = True
        print(
            "  environment — the shipped slots moved; ours is a full replacement, so "
            "compare slot NAMES:"
        )
        import re

        def names(a):
            return [re.match(r"\*\*(.+?)\*\*", e).group(1) for e in a]

        for n in set(names(env_new)) - set(names(env_old)):
            print(f"      + slot {n!r} — absent from our array, so the classifier loses it")
        for n in set(names(env_old)) - set(names(env_new)):
            print(f"      - slot {n!r} — ours still sends it; it may no longer be read")
    else:
        print(f"  environment  {len(env_new):3} slots — unchanged")

    if not drift:
        print("\nidentical to the pin. Nothing owed.")
        return 0
    print("\nThe pin is out of date. Re-read the affected dispositions in AUTO-MODE.md,")
    print("update decisions.py, then save the new capture as auto-mode/shipped-<version>.json")
    print("and point SHIPPED at it. This script does not do that for you on purpose.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
