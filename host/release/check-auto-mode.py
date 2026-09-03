#!/usr/bin/env python3
"""Prove the auto-mode configuration is whole: sources, document, boundary file.

Run by `just build` and `just verify`. Two artifacts describe one set of
decisions — AUTO-MODE.md and the autoMode block inside managed-settings.json —
and when they drift nothing says so.

Freshness first — both outputs are still what the sources say — then the four
numbered checks below, each of which fails silently otherwise.

`build.py --check` does the same freshness comparison on its own and stays for
iterating on the sources; `just build` and `just verify` call this one instead,
because a stale output and a self-inconsistent one are the same question to
whoever reads the answer.

See docs/release.md#check-auto-mode-and-the-sibling-it-outlived.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "auto-mode"))
DOC = ROOT / "AUTO-MODE.md"
MANAGED = ROOT / "image" / "managed-settings.json"

ENTRY = re.compile(r"(?m)^### ([AHS]-\d+)\. .+\n\n\*\*([A-Z]+)")
SHIPS = ("KEEP", "REPLACED", "ADDED")


def fail(problems):
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    sys.exit(f"check-auto-mode: {len(problems)} problem(s)")


def main():
    # The pin has one owner, decisions.SHIPPED: a second spelling here would go
    # on checking the old capture after a refresh, with no symptom.
    import decisions

    shipped_path = ROOT / "auto-mode" / decisions.SHIPPED
    for path in (DOC, MANAGED, shipped_path):
        if not path.exists():
            sys.exit(f"check-auto-mode: missing {path}")
    # Freshness first, and reported rather than fatal: the structural checks
    # below still describe what is on disk, which is what would ship, so one
    # run should say everything that is wrong rather than stopping at the first.
    bad = []
    try:
        import build

        want_doc, want_cfg = build.build()
        want_settings = build.managed_settings(want_cfg["autoMode"])
        for path, want in ((DOC, want_doc), (MANAGED, want_settings)):
            if not path.exists() or path.read_text() != want:
                bad.append(
                    f"{path.relative_to(ROOT)}: stale — rebuild with `python3 auto-mode/build.py`"
                )
    except SystemExit as e:
        bad.append(f"auto-mode/build.py could not build from its sources: {e}")
    except Exception as e:
        bad.append(f"auto-mode/build.py raised {type(e).__name__}: {e}")

    doc = DOC.read_text()
    settings = json.loads(MANAGED.read_text())
    if "autoMode" not in settings:
        sys.exit("check-auto-mode: managed-settings.json carries no autoMode block")
    cfg = settings["autoMode"]
    shipped = json.loads(shipped_path.read_text())

    # 1 — per-section counts, and installed text on everything that ships
    sections = re.split(r"(?m)^# ", doc)
    for name, key in (
        ("Section 2", "hard_deny"),
        ("Section 3", "allow"),
        ("Section 4", "soft_deny"),
    ):
        block = next((s for s in sections if s.startswith(name)), "")
        ships = [i for i, st in ENTRY.findall(block) if st in SHIPS]
        if len(ships) != len(cfg[key]):
            bad.append(f"{key}: document ships {len(ships)}, config has {len(cfg[key])}")
    for block in re.split(r"(?m)^### ", doc):
        m = re.match(r"([AHS]-\d+)\. [^\n]+\n\n\*\*(KEEP|REPLACED|ADDED)", block)
        if m and "INSTALLED TEXT" not in block:
            bad.append(f"{m.group(1)}: marked as shipping with no INSTALLED TEXT block")

    # 2 — the index lists exactly the entries that exist
    entries = sorted(i for i, _ in ENTRY.findall(doc))
    index = sorted(re.findall(r"(?m)^\| `([AHS]-\d+)` \|", doc))
    if entries != index:
        for i in sorted(set(entries) ^ set(index)):
            where = (
                "an entry but not in the index" if i in entries else "the index but has no entry"
            )
            bad.append(f"{i}: in {where}")
    if len(entries) != len(set(entries)):
        bad.append("duplicate rule entries in the document")

    # 3 — the environment array, which is a full replacement
    names = [re.match(r"\*\*(.+?)\*\*", e).group(1) for e in shipped["environment"]]
    ours = [re.match(r"\*\*(.+?)\*\*: ", e) for e in cfg["environment"]]
    if any(o is None for o in ours):
        bad.append("an environment entry is not in the shipped `**Slot**: value` shape")
    else:
        got = [o.group(1) for o in ours]
        for missing in [n for n in names if n not in got]:
            bad.append(f"environment slot dropped, and a missing slot is silent: {missing}")
        for unknown in [g for g in got if g not in names]:
            bad.append(f"environment slot the classifier does not know: {unknown}")

    # 4 — nothing unresolved reached the config
    for key, values in cfg.items():
        for v in values:
            if "$defaults" in v:
                bad.append(f"{key}: `$defaults` in a full replacement")
            if v.lstrip().startswith(("…", "Shipped text")):
                bad.append(f"{key}: an unfinished fragment reached the config")

    if bad:
        fail(bad)
    n = {k: len(v) for k, v in cfg.items()}
    print(
        f"auto-mode: {sum(n.values())} entries ship "
        f"({', '.join(f'{k} {v}' for k, v in n.items())}); "
        f"{len(entries)} rules documented, index agrees, outputs match their sources"
    )


if __name__ == "__main__":
    main()
