#!/usr/bin/env python3
"""Build AUTO-MODE.md, and write the classifier rules into managed settings.

    python3 auto-mode/build.py            write both
    python3 auto-mode/build.py --check    build in memory, diff against what is
                                          on disk, exit 1 if they differ

The rules live in `image/managed-settings.json` and not in a file of their own:
that file is what Claude Code reads, and a second copy beside it would be one
more thing to keep in step. So this rewrites exactly one key there, `autoMode`,
plus the `_auto_mode_comment` that introduces it, and leaves every other byte
alone — the other `_comment` fields are hand-written. The file round-trips
through `json` byte-identically (2-space indent, ascii-escaped), so a diff
after a build shows the rule change and nothing else.

It is generated because the document carries every shipped rule with its
disposition and the config carries the subset that ships: the same decisions
rendered twice, which must agree exactly and have drifted before — see
docs/boundary.md, under "The auto-mode classifier".

Which means neither output is editable. AUTO-MODE.md is generated whole and the
`autoMode` key is rewritten every time, so a fix typed into either is lost on
the next build with no symptom — the failure this file exists to prevent. Edit
the reasoning in `decisions.py` and the prose in `prose.md`, then rebuild.

`host/release/check-auto-mode.py` proves the two outputs still agree with each
other and with the baseline; `--check` here proves they are what the sources say.
"""

import json
import re
import sys
import textwrap
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MANAGED = ROOT / "image" / "managed-settings.json"
sys.path.insert(0, str(HERE))
import decisions as D  # noqa: E402 — path set above

SHIPPED = json.loads((HERE / D.SHIPPED).read_text())
TXT = {"A": SHIPPED["allow"], "S": SHIPPED["soft_deny"], "H": SHIPPED["hard_deny"]}
DISP = {"A": D.ALLOW, "S": D.SOFT, "H": D.HARD}
BADGE = {
    "KEEP": "KEEP — installed unchanged",
    "TWEAK": "REPLACED",
    "DROP": "DROPPED — not installed",
}
WHY = "*Why (review note — not part of the installed text):*"


def title(sec, n):
    return TXT[sec][n - 1].split(":")[0].split("[")[0].strip().replace("**", "")


def quoted(s):
    return "\n".join(f"> {line}" for line in textwrap.wrap(s, 76))


def entry(sec, n):
    """One rule, whole: badge, why, the shipped text, and the new text if any."""
    status, why = DISP[sec][n]
    out = [f"### {sec}-{n}. {title(sec, n)}", "", f"**{BADGE[status]}**", "", f"{WHY} {why}", ""]
    out.append(
        "Shipped text, for reference — **not installed**:"
        if status == "DROP"
        else "Shipped — **NOT installed**:"
        if status == "TWEAK"
        else "**INSTALLED TEXT:**"
    )
    out += ["", quoted(TXT[sec][n - 1]), ""]
    if status == "TWEAK":
        out += [
            "**INSTALLED TEXT** — replaces the shipped text above:",
            "",
            D.REPLACEMENTS[f"{sec}-{n}"],
            "",
        ]
    return "\n".join(out)


def addition(i, name, why, text):
    return "\n".join(
        [
            f"### H-{i}. {name}",
            "",
            "**ADDED — not in the shipped rules**",
            "",
            f"{WHY} {why}",
            "",
            "**INSTALLED TEXT:**",
            "",
            quoted(text),
            "",
        ]
    )


def ships(sec):
    return [n for n in sorted(DISP[sec]) if DISP[sec][n][0] in ("KEEP", "TWEAK")]


def env_entries():
    """Section 1 — one entry per slot, shipped text beside ours."""
    sh = {
        re.match(r"\*\*(.+?)\*\*: ?(.*)$", e, re.S).group(1): re.match(
            r"\*\*(.+?)\*\*: ?(.*)$", e, re.S
        ).group(2)
        for e in SHIPPED["environment"]
    }
    order = [re.match(r"\*\*(.+?)\*\*", e).group(1) for e in SHIPPED["environment"]]
    ours = {}
    for e in D.ENVIRONMENT:
        m = re.match(r"\*\*(.+?)\*\*: ?(.*)$", e, re.S)
        ours[m.group(1)] = m.group(2)
    changed = sum(1 for s in order if ours[s].strip() != sh[s].strip())
    out = [
        "",
        "---",
        "",
        "# Section 1 — `environment`, entry by entry",
        "",
        "**All 20 slots are replaced.** The array is written out in full rather than",
        "spliced with `$defaults`, because shipped entries are one `**Slot**: value`",
        "bullet each and splicing would leave two contradictory bullets for the same",
        "slot. That makes this exhaustive by necessity: **a slot nobody writes here",
        "disappears**, and a missing slot has no symptom — the classifier simply knows",
        "less.",
        "",
        f"{20 - changed} slots are the shipped text unchanged, and say so. The other {changed} are",
        "where the work is.",
        "",
    ]
    for s in order:
        diff = ours[s].strip() != sh[s].strip()
        out += [
            f"### {s}",
            "",
            "**REPLACED**"
            if diff
            else "**UNCHANGED — shipped text, restated so the slot is not lost**",
            "",
            f"{WHY} {D.ENV_WHY[s]}",
            "",
        ]
        if diff:
            out += ["Shipped — **NOT installed**:", "", quoted(sh[s]), ""]
        out += ["**INSTALLED TEXT:**", "", quoted(ours[s]), ""]
    return "\n".join(out)


def config():
    cfg = {"environment": list(D.ENVIRONMENT), "allow": [], "soft_deny": [], "hard_deny": []}
    key = {"A": "allow", "S": "soft_deny", "H": "hard_deny"}
    for sec in ("H", "A", "S"):
        for n in ships(sec):
            status, _ = DISP[sec][n]
            cfg[key[sec]].append(
                TXT[sec][n - 1] if status == "KEEP" else unquote(D.REPLACEMENTS[f"{sec}-{n}"])
            )
    for _, _, text in D.ADDITIONS:
        cfg["hard_deny"].append(text)
    return {"autoMode": {k: cfg[k] for k in ("environment", "allow", "soft_deny", "hard_deny")}}


def unquote(block):
    """A markdown blockquote back to the paragraphs the classifier receives."""
    lines = [
        line[2:] if line.startswith("> ") else ("" if line.strip() == ">" else line)
        for line in block.strip().split("\n")
    ]
    paras, cur = [], []
    for line in lines:
        if not line.strip():
            if cur:
                paras.append(" ".join(cur))
                cur = []
        else:
            cur.append(line.strip())
    if cur:
        paras.append(" ".join(cur))
    return "\n\n".join(paras)


BANNER = (
    "<!-- Generated by auto-mode/build.py. Do not edit: this file is written whole on\n"
    "     every build, so a fix typed here is lost with no symptom. The sources are\n"
    "     auto-mode/prose.md and auto-mode/decisions.py; `python3 auto-mode/build.py`\n"
    "     rewrites this file and the `autoMode` key of image/managed-settings.json from\n"
    "     them both. `--check` says whether what is on disk is what the sources say, and\n"
    "     host/release/check-auto-mode.py says whether the two outputs still agree.\n"
    "     The rule texts quoted below are Anthropic's, Claude Code's own classifier\n"
    "     rules reproduced from `claude auto-mode defaults` for review; they are not\n"
    "     covered by this repository's licence. -->"
)


AUTO_MODE_COMMENT = (
    "the auto-mode classifier's rules, generated — do not edit here. "
    "`defaultMode: auto` runs a second-stage LLM classifier over tool calls that the "
    "permission rules above have not already settled, and these four arrays are what it "
    "is told. The source is auto-mode/decisions.py and the reasoning is AUTO-MODE.md, one "
    "entry per rule with the shipped text it replaces and why; `python3 auto-mode/build.py` "
    "writes this key and `host/release/check-auto-mode.py` proves the two agree. No `$defaults` "
    "anywhere, deliberately: each array is a full replacement, so a rule nobody wrote down "
    "is a rule that is gone, which is why AUTO-MODE.md is exhaustive and lists the dropped "
    "ones too. `environment` is not rules at all — it is what the classifier is told about "
    "this container, and an entry there gives context and never clears a block, which is "
    "why it is the cheapest thing here and was ruled first. What survives of the shipped "
    "set, and why any of this is generated rather than written by hand, is in "
    'docs/boundary.md, under "The auto-mode classifier".'
)


def managed_settings(auto_mode):
    """Rewrite one key of the boundary file, byte-for-byte elsewhere."""
    raw = MANAGED.read_text()
    data = json.loads(raw)
    if json.dumps(data, indent=2) + "\n" != raw:
        sys.exit("managed-settings.json does not round-trip; refusing to rewrite it")
    # In place: the key keeps the position the file gives it, and its comment
    # is re-emitted right before it, so reordering the file never moves it.
    out = {}
    for key, value in data.items():
        if key == "_auto_mode_comment":
            continue
        if key == "autoMode":
            out["_auto_mode_comment"] = AUTO_MODE_COMMENT
            out["autoMode"] = auto_mode
            continue
        out[key] = value
    if "autoMode" not in out:
        sys.exit("managed-settings.json has no autoMode key to rewrite")
    return json.dumps(out, indent=2) + "\n"


def index(shipping, dropped, slots):
    m = {
        "KEEP": "unchanged",
        "TWEAK": "**replaced**",
        "ADD": "**added**",
        "REPLACED": "**replaced**",
        "UNCHANGED": "unchanged",
    }
    out = [
        "",
        "---",
        "",
        "# Index",
        "",
        "## Section 1 — `environment`: 20 slots, all installed",
        "",
        "| slot | |",
        "| --- | --- |",
    ]
    out += [f"| {s} | {v} |" for s, v in slots]
    out += [
        "",
        f"## Sections 2–4 — the {len(shipping)} rules that ship",
        "",
        "| id | rule | |",
        "| --- | --- | --- |",
    ]
    out += [f"| `{i}` | {t} | {m[st]} |" for i, t, st in shipping]
    out += [
        "",
        f"## Section 5 — the {len(dropped)} rules that are dropped",
        "",
        "Grouped there by reason; listed here in order.",
        "",
        "| id | rule |",
        "| --- | --- |",
    ]
    out += [f"| `{i}` | {t} |" for i, t in dropped]
    return "\n".join(out)


def build():
    prose = {}
    parts = re.split(r"<!-- SECTION: ([\w-]+) -->\n", (HERE / "prose.md").read_text())
    for i in range(1, len(parts), 2):
        prose[parts[i]] = parts[i + 1].strip()

    sh_ids, dr_ids, slots = [], [], []
    sec2 = ["", "---", "", "# Section 2 — `hard_deny` (3 rules)", ""]
    sec2.append(entry("H", 1))
    sh_ids.append(("H-1", title("H", 1), "KEEP"))
    for i, (name, why, text) in enumerate(D.ADDITIONS, 2):
        sec2.append(addition(i, name, why, text))
        sh_ids.append((f"H-{i}", name, "ADD"))
    for sec, head in (
        ("A", "# Section 3 — `allow`, the %d that ship"),
        ("S", "# Section 4 — `soft_deny`, the %d that ship"),
    ):
        n_ship = ships(sec)
        sec2 += ["", "---", "", head % len(n_ship), ""]
        for n in n_ship:
            sec2.append(entry(sec, n))
            sh_ids.append((f"{sec}-{n}", title(sec, n), DISP[sec][n][0]))

    drops = ["", "---", ""]
    total = sum(len(ids) for _, _, ids in D.REASON_CLASSES)
    drops += [
        f"# Section 5 — the {total} rules that are dropped",
        "",
        "Grouped by reason, because the reason is what survives a version bump.",
        "Nothing here is installed; the shipped text is kept so the decision can be",
        "checked without going back to the binary.",
        "",
    ]
    for name, why, ids in D.REASON_CLASSES:
        drops += [f"## {name} — {len(ids)} rule{'' if len(ids) == 1 else 's'}", ""]
        if why:
            drops += [why, ""]
        drops += ["**" + ", ".join(f"{i[0]}-{i[1:]}" for i in ids) + "**", ""]
        for i in ids:
            sec, n = i[0], int(i[1:])
            drops.append(entry(sec, n))
            dr_ids.append((f"{sec}-{n}", title(sec, n)))

    sh = {
        re.match(r"\*\*(.+?)\*\*: ?(.*)$", e, re.S).group(1): re.match(
            r"\*\*(.+?)\*\*: ?(.*)$", e, re.S
        ).group(2)
        for e in SHIPPED["environment"]
    }
    for e in D.ENVIRONMENT:
        m = re.match(r"\*\*(.+?)\*\*: ?(.*)$", e, re.S)
        slots.append(
            (
                m.group(1),
                "**replaced**" if m.group(2).strip() != sh[m.group(1)].strip() else "unchanged",
            )
        )

    cfg = config()
    doc = "\n".join(
        [
            BANNER,
            "",
            prose["head"],
            index(sh_ids, dr_ids, slots),
            "",
            prose["amend"],
            "",
            prose["scope"],
            env_entries(),
            "",
            prose["rules-intro"],
            "\n".join(sec2),
            "\n".join(drops),
            "",
            prose["tail"],
            "",
            prose["install"],
            "",
            "```json",
            json.dumps(cfg, indent=2, ensure_ascii=False),
            "```",
            "",
        ]
    )
    return doc, cfg


if __name__ == "__main__":
    doc, cfg = build()
    doc_path = ROOT / "AUTO-MODE.md"
    settings_text = managed_settings(cfg["autoMode"])
    if "--check" in sys.argv:
        bad = [
            str(p)
            for p, want in ((doc_path, doc), (MANAGED, settings_text))
            if not p.exists() or p.read_text() != want
        ]
        if bad:
            sys.exit("stale, rebuild with `python3 auto-mode/build.py`: " + ", ".join(bad))
        print("AUTO-MODE.md and managed-settings.json match their sources")
    else:
        doc_path.write_text(doc)
        MANAGED.write_text(settings_text)
        n = {k: len(v) for k, v in cfg["autoMode"].items()}
        print(f"AUTO-MODE.md               {len(doc.splitlines())} lines")
        print(f"image/managed-settings.json  autoMode: {n} = {sum(n.values())} entries")
