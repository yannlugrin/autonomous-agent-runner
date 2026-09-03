#!/usr/bin/env python3
"""What gitleaks objected to in one held transcript, counted.

Runs on the host, inside `just collect`'s held-back report, when the pattern
floor matched nothing — gitleaks reads shapes the floor does not, so it can
be the only objector, and then it is the only account there is. Reads its
JSON report and prints one indented line per distinct finding on stdout;
nothing at all when it named none.

    findings.py <gitleaks report> <staged transcript>

What it objected to, not merely that it did. `--redact` blanks the value in
gitleaks' `Match` and keeps everything around it, so `token: 'REDACTED'` is a
whole account of the finding: the field name decides whether this is a
credential or a column of blockchain data, and it is the one thing the mask in
the passage below cannot show. Printed instead of `Description`, which is the
rule id said a second way, and counted like the pattern floor above.
see docs/archive.md#what-gitleaks-objected-to-not-merely-that-it-did
"""

import collections
import json
import sys


def counted(report_path, transcript):
    """The distinct findings on `transcript`, as {(line, rule, match): count}.

    An unreadable report is no findings: the caller has already decided the
    file is held, and this only accounts for why.
    """
    try:
        findings = json.load(open(report_path))
    except Exception:
        findings = []

    return collections.Counter(
        (
            int(f.get("StartLine") or 0),
            f.get("RuleID"),
            " ".join(str(f.get("Match", "")).split()),
        )
        for f in findings
        if f.get("File") == transcript
    )


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: findings.py <gitleaks report> <staged transcript>")

    for (line, rule, match), count in sorted(counted(sys.argv[1], sys.argv[2]).items()):
        print(f"    {count:>3}  gitleaks {rule} at line {line} — {match}")
