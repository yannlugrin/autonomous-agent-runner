#!/usr/bin/env python3
"""The status page, as one self-contained HTML file.

RUNS IN CI, in this repository, and can be run by hand from a clone —
`scripts/render.py --out /tmp/page.html` — which is the only way to look at
a change before it is in front of you on the real hostname.

WHERE EVERY FACT COMES FROM, AND WHY IT COMES FROM THERE

  the host's snapshot   `status:snapshot.json`, written by publish-status.sh
                        in the runner. Everything in it is something
                        no reader on GitHub can know: whether a container is
                        up, what the crontab holds, what the account has
                        spent. It carries its own timestamp and this page
                        shows the AGE of it, always — a dashboard that
                        renders a stale snapshot as current is worse than
                        one that is plainly down, because you believe it.

  the sessions          `sessions`, through scripts/session-meta.jq — the
                        same program `just sessions` reads. Not recomputed
                        here and not shipped from the host either: the
                        transcripts are already in this repository, and a
                        third implementation of that counting would drift
                        from both.

  issues and articles   The GitHub API, with a token that can only read, on
                        one repository. Read here rather than folded into
                        the host's snapshot so that closing an issue from a
                        phone shows up on the next render rather than
                        waiting for the machine at home to notice.

  the archive itself    This repository: the mirror workflow's own run
                        history, the rewind tags, and how far `sessions` on
                        origin is behind what the host has.

NOTHING MISSING IS ZERO — the rule the snapshot follows, applied to the
page. Every section renders its own failure in place, and no section that
could not be read is drawn as an empty one. "No issues waiting on you" and
"the issue list could not be read" must never look alike.
"""

import argparse
import html
import json
import os
import re
import subprocess
import sys
from datetime import UTC, datetime

# Who this page is about. Every one of them is a REPLACE_WITH_ placeholder
# rather than a plausible default, so a leftover shows in the rendered page
# instead of quietly reading someone else's repository.
REPO = os.environ.get("GITHUB_REPOSITORY", "REPLACE_WITH_OWNER/REPLACE_WITH_ARCHIVE")
SOURCE = os.environ.get("AGENT_SOURCE_REPO", "REPLACE_WITH_SOURCE_REPO")
OWNER = os.environ.get("AGENT_OWNER", "REPLACE_WITH_OWNER")
NAME = os.environ.get("AGENT_NAME", "REPLACE_WITH_AGENT_NAME")
SLUG = os.environ.get("AGENT_USER", "REPLACE_WITH_AGENT")
# Everything under here is a real session or one of its subagents: the
# collection files what it keeps by the day it happened.
WORK = "transcripts"
AGENT = "--agent-"  # what separates a session id from its subagent's
NOW = datetime.now(UTC)

# TWO TOKENS, AND THEY ARE NOT INTERCHANGEABLE. The read token is
# fine-grained on the agent's repository alone and cannot see this
# repository; the workflow's own GITHUB_TOKEN is scoped to this repository
# and cannot see the agent's. A single GH_TOKEN in the environment would
# therefore make half the page render as an authentication error — and the
# half depends on which one was set, which is the kind of thing that looks
# like an outage. Empty means "use whatever gh is logged in as", which is
# what makes this script runnable from a clone.
SOURCE_TOKEN = os.environ.get("AGENT_READ_TOKEN", "")
REPO_TOKEN = os.environ.get("GITHUB_TOKEN", "")


def run(cmd, timeout=300, stdin=None, env=None):
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, input=stdin, env=env
        )
        return p.returncode, p.stdout, p.stderr.strip()
    except (subprocess.TimeoutExpired, OSError) as e:
        return 127, "", str(e)


def git(*args, timeout=300):
    return run(["git"] + list(args), timeout=timeout)


def ref(name):
    """A branch, wherever this clone happens to keep it.

    In CI there are only remote refs; in a working clone the local branch is
    the one that is ahead. Asking for both and preferring the local one is
    what makes the same script useful in either place.

    The third candidate is the mirror, which is NOT a branch: it lives at
    refs/archive/<agent> so that a workflow file the agent wrote can never
    execute in this repository — GitHub triggers only on refs/heads/* and
    refs/tags/*. Custom namespaces have no remote-tracking form, so the ref
    is the same string in CI and in a working clone.
    """
    for candidate in (name, "origin/" + name, "refs/archive/" + name):
        code, _, _ = git("rev-parse", "--verify", "--quiet", candidate)
        if code == 0:
            return candidate
    return None


def ago(then, now=None):
    """A duration in the words a person would use, or None if unknown."""
    if then is None:
        return None
    now = now or NOW
    s = int((now - then).total_seconds())
    if s < 0:
        return "in the future"
    if s < 90:
        return "%ds ago" % s
    if s < 5400:
        return "%dm ago" % (s // 60)
    if s < 172800:
        return "%dh%02dm ago" % (s // 3600, (s % 3600) // 60)
    return "%dd ago" % (s // 86400)


def instant(text):
    if not text:
        return None
    try:
        return datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=UTC)
    except ValueError:
        return None


def tokens(n):
    """The same rounding `just sessions` uses, deliberately.

    119_500 shown as 119k on one screen and 120k on another is two
    implementations disagreeing about one session, which is the whole risk
    of having two.
    """
    n = float(n)
    if n < 1000:
        return "%d" % n
    if n < 10000:
        return "%.1fk" % (n / 1000)
    if n < 1000000:
        return "%dk" % (n / 1000 + 0.5)
    return "%.1fM" % (n / 1000000)


# ---------------------------------------------------------------- the host


def snapshot():
    where = ref("status")
    if where is None:
        return None, "no `status` branch — publish-status.sh has never run"
    code, out, err = git("show", "%s:snapshot.json" % where)
    if code != 0:
        return None, "snapshot.json is not on `%s`: %s" % (where, err)
    try:
        return json.loads(out), None
    except json.JSONDecodeError as e:
        return None, "snapshot.json does not parse: %s" % e


# ------------------------------------------------------------- the sessions


def sessions(limit=20):
    where = ref("sessions")
    if where is None:
        return [], 0, "no `sessions` branch — nothing has been collected yet"

    code, out, err = git("ls-tree", "-r", "--name-only", where, "--", WORK)
    if code != 0:
        return [], 0, "could not list `%s`: %s" % (where, err)

    files = [f for f in out.splitlines() if f.endswith(".jsonl")]
    # A subagent is `<session-id>--agent-<agent-id>.jsonl`, beside the
    # session that spawned it rather than in a folder under it. It is NOT a
    # session: listed as one it is a row nothing accounts for, and its
    # output would be counted twice — once as itself, once inside the
    # session that spawned it. session-meta.jq cumulates them into it.
    subs = [f for f in files if AGENT in f]
    files = [f for f in files if AGENT not in f]
    if not files:
        return [], 0, "no transcripts under %s on `%s`" % (WORK, where)

    here = os.path.dirname(os.path.abspath(__file__))
    program = os.path.join(here, "session-meta.jq")

    rows, failed = [], 0
    for f in files:
        code, blob, _ = git("show", "%s:%s" % (where, f))
        if code != 0:
            failed += 1
            continue
        text = blob
        for s in subs:
            if s.startswith(f[: -len(".jsonl")] + AGENT):
                c, extra, _ = git("show", "%s:%s" % (where, s))
                if c == 0:
                    text += extra
        code, tsv, _ = run(["jq", "-rn", "-f", program], stdin=text, timeout=120)
        if code != 0 or not tsv.strip():
            failed += 1
            continue
        parts = tsv.strip().split("\t")
        if len(parts) < 14:
            failed += 1
            continue
        rows.append(parts)

    # Newest first: the session anyone is looking for is nearly always the
    # last one that ran.
    rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
    error = None
    if failed:
        # Counted, never dropped in silence. A transcript that stopped
        # parsing is a fact about the archive, not a row to omit.
        error = "%d transcript(s) could not be read" % failed
    return rows[:limit], len(rows), error


def unpushed():
    """How far the host is ahead of origin on `sessions`.

    Only answerable in a clone that has both, so it is absent in CI rather
    than wrong there — and absent is said, not drawn as zero. The interesting
    direction is the one that means transcripts exist on exactly one disk.
    """
    code, out, _ = git("rev-list", "--count", "origin/sessions..sessions")
    if code != 0 or not out.strip().isdigit():
        return None
    return int(out.strip())


# ---------------------------------------------------------------- the forge


def gh(*args, token=None, timeout=120):
    env = None
    if token:
        env = dict(os.environ, GH_TOKEN=token, GITHUB_TOKEN=token)
    code, out, err = run(["gh"] + list(args), timeout=timeout, env=env)
    if code != 0:
        return None, (err or out or "gh failed").splitlines()[0][:200]
    return out, None


def issues():
    out, err = gh(
        "issue",
        "list",
        "-R",
        SOURCE,
        "--state",
        "open",
        "--limit",
        "100",
        "--json",
        "number,title,assignees,author,updatedAt,createdAt,comments,url",
        token=SOURCE_TOKEN,
    )
    if err:
        return None, None, err
    try:
        data = json.loads(out)
    except json.JSONDecodeError as e:
        return None, None, str(e)

    waiting, other = [], []
    for i in data:
        who = [a.get("login") for a in (i.get("assignees") or [])]
        comments = i.get("comments") or []
        row = {
            "number": i["number"],
            "title": i["title"],
            "url": i["url"],
            "author": (i.get("author") or {}).get("login"),
            "updated": instant(i.get("updatedAt")),
            "comments": len(comments),
            "last_by": (comments[-1].get("author") or {}).get("login")
            if comments
            else (i.get("author") or {}).get("login"),
            "assignees": who,
        }
        # A convention, and one the agent's own CLAUDE.md has to state for
        # this to mean anything: the agent assigns the operator when it is
        # actually waiting on them and leaves the issue unassigned when the
        # thing can wait. So this is read off the assignee and is not a
        # heuristic about who spoke last.
        (waiting if OWNER in who else other).append(row)

    # Most recently updated first. Nothing is hidden by it now that the
    # list is uncapped, so this is only about which one meets the eye —
    # reverse it and the longest-neglected rises to the top instead.
    waiting.sort(key=lambda r: r["updated"] or NOW, reverse=True)
    other.sort(key=lambda r: r["updated"] or NOW, reverse=True)
    return waiting, other, None


def articles():
    q = """
    { repository(owner: "%s", name: "%s") {
        discussions(first: 20, orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes { number title url createdAt bodyText category { name }
                  comments { totalCount } }
    } } }
    """ % tuple(SOURCE.split("/"))
    out, err = gh("api", "graphql", "-f", "query=" + q, token=SOURCE_TOKEN)
    if err:
        return None, err
    try:
        nodes = json.loads(out)["data"]["repository"]["discussions"]["nodes"]
    except (json.JSONDecodeError, KeyError, TypeError) as e:
        return None, "the discussions response did not have the expected shape: %s" % e
    for n in nodes:
        n["created"] = instant(n.get("createdAt"))
        body = " ".join((n.get("bodyText") or "").split())
        n["excerpt"] = body[:280] + ("…" if len(body) > 280 else "")
        n["words"] = len((n.get("bodyText") or "").split())
    return nodes, None


def token_expiry():
    """When the read token dies, from the header GitHub sends on every call.

    Nothing else reports it, and a fine-grained token stops working on its
    date with no warning anywhere — including here, where the first symptom
    would be this whole section rendering as an error.
    """
    out, err = gh("api", "-i", "repos/" + SOURCE, token=SOURCE_TOKEN)
    if err:
        return None, err
    m = re.search(r"^github-authentication-token-expiration:\s*(.+)$", out, re.M | re.I)
    if not m:
        return None, "no expiry header — this is not a fine-grained token"
    return m.group(1).strip(), None


def mirror():
    """The mirror's health, which the mirrored ref's own tip does not give.

    That ref moves only when the agent pushed something, so a week of
    silence there is a quiet agent and not a broken mirror. What says the
    mirror is alive is the workflow's run history and its `state` — GitHub
    disables a schedule after 60 days of repository inactivity, and a
    disabled workflow fails by never running.
    """
    info = {
        "state": None,
        "last": None,
        "conclusion": None,
        "rewinds": [],
        "tip": None,
        "tip_at": None,
        "error": None,
    }

    workflow = "mirror-%s.yml" % SLUG
    out, err = gh(
        "api",
        "repos/%s/actions/workflows/%s" % (REPO, workflow),
        "--jq",
        ".state",
        token=REPO_TOKEN,
    )
    if err:
        info["error"] = err
    else:
        info["state"] = out.strip()

    out, err = gh(
        "run",
        "list",
        "--repo",
        REPO,
        "--workflow",
        workflow,
        "--limit",
        "1",
        "--json",
        "status,conclusion,createdAt",
        token=REPO_TOKEN,
    )
    if not err:
        try:
            runs = json.loads(out)
            if runs:
                info["last"] = instant(runs[0].get("createdAt"))
                info["conclusion"] = runs[0].get("conclusion") or runs[0].get("status")
        except json.JSONDecodeError:
            pass

    where = ref(SLUG)
    if where:
        code, out, _ = git("log", "-1", "--format=%h\t%cI\t%s", where)
        if code == 0 and out.strip():
            h, when, subject = out.strip().split("\t", 2)
            info["tip"] = (h, subject)
            info["tip_at"] = instant(when)

    # refs/archive/rewound/*, not tags: refs/tags/* triggers workflows on
    # push exactly as a branch does, and these refs carry the agent's tree.
    # A plain ref anchors the preserved objects just as well.
    code, out, _ = git(
        "for-each-ref", "--sort=-refname", "--format=%(refname)", "refs/archive/rewound/*"
    )
    if code == 0:
        info["rewinds"] = [t for t in out.splitlines() if t.strip()]
    return info


# ----------------------------------------------------------------- the page


def e(text):
    return html.escape("" if text is None else str(text), quote=True)


def when(dt, mode="ago", fallback="unknown"):
    """An instant the browser re-reads, rather than a phrase frozen at render.

    The page is rebuilt every half hour and a reader may leave it open for
    longer than that, so "6m ago" baked into the HTML is wrong within
    minutes and wrong in the direction that reassures — it under-reports
    staleness exactly when staleness is the thing worth seeing.

    So the instant goes in `datetime` and the words are computed in the
    browser. What is rendered here is the same phrase computed server-side,
    which is what a reader with no JavaScript keeps: stale, but never
    emptier than the page used to be.

      ago    "6m ago"     something that happened
      since  "up 6m"      something still going on
      until  "in 3h27m"   something that has not happened yet
    """
    if dt is None:
        return '<span class="dim">%s</span>' % e(fallback)
    if mode == "ago":
        text = ago(dt) or fallback
    elif mode == "since":
        text = (ago(dt) or "").replace(" ago", "")
    else:
        text = (ago(NOW, dt) or "").replace(" ago", "")
        text = "in " + text if text else fallback
    return '<time datetime="%s" data-mode="%s">%s</time>' % (
        e(dt.strftime("%Y-%m-%dT%H:%M:%SZ")),
        mode,
        e(text),
    )


def bar(percent, klass=""):
    pct = max(0.0, min(100.0, float(percent)))
    return '<div class="bar%s"><i style="width:%.1f%%"></i></div>' % (klass, pct)


SOURCE_URL = "https://github.com/" + SOURCE
PROFILE_URL = "https://github.com/" + SOURCE.split("/")[0]
ARCHIVE_URL = "https://github.com/" + REPO

# Baked rather than fetched at render time: a page that reaches out to another
# host for its decoration is a page that renders late when that host is slow
# and wrong when it moves.
ICON_GITHUB = (
    '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" '
    'd="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 '
    "0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13"
    "-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66."
    "07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-."
    "08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 "
    "2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 "
    "2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 "
    '2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>'
)
# One row per place the agent can be read. Add the community's own here.
LINKS = [
    (SOURCE_URL, ICON_GITHUB, "the agent's repository"),
]

CSS = """
:root{--bg:#fbfbfa;--fg:#1a1a19;--dim:#6b6b66;--line:#e4e3df;--card:#fff;
--ok:#2f7d4f;--warn:#9a6700;--warnbg:#fdf6e3;--bad:#b3261e;--accent:#2f5d8f;
--mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
--bg:#16171a;--fg:#e8e8e4;--dim:#9a9a94;--line:#2b2d31;--card:#1d1f23;
--ok:#5fbf87;--warn:#d9a441;--warnbg:#2a2418;--bad:#f08a80;--accent:#7fa8d8}}
:root[data-theme="dark"]{--bg:#16171a;--fg:#e8e8e4;--dim:#9a9a94;--line:#2b2d31;
--card:#1d1f23;--ok:#5fbf87;--warn:#d9a441;--warnbg:#2a2418;--bad:#f08a80;
--accent:#7fa8d8}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,
-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-text-size-adjust:100%}
.wrap{max-width:900px;margin:0 auto;padding:24px 18px 80px}
.top{display:flex;align-items:center;gap:12px;margin-bottom:14px}
h1{font-size:15px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;
color:var(--dim);margin:0;flex:1}
h1 a{color:inherit}
h1 a:hover{color:var(--accent);text-decoration:none}
.icons{display:flex;gap:6px;align-items:center}
.icons a{display:inline-flex;align-items:center;justify-content:center;
width:30px;height:30px;border:1px solid var(--line);border-radius:8px;
color:var(--dim);background:var(--card)}
.icons a:hover{color:var(--fg);border-color:var(--dim)}
.icons svg{width:17px;height:17px;display:block}
.emoji{font-size:16px;line-height:1}
h2{font-size:13px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;
color:var(--dim);margin:34px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--line)}
.hero{font-size:22px;line-height:1.35;font-weight:500;margin:0 0 6px}
.stale{color:var(--bad);font-weight:600}
.age{color:var(--dim);font-size:13px;margin:4px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;
padding:14px 16px;margin:10px 0}
.band{border-left:3px solid var(--warn);background:var(--warnbg);
border-radius:8px;padding:11px 14px;margin:14px 0}
.band.bad{border-left-color:var(--bad)}
.row{display:flex;gap:12px;align-items:baseline;flex-wrap:wrap}
.row .grow{flex:1;min-width:0}
.dim{color:var(--dim)}
.mono{font-family:var(--mono);font-size:12.5px}
.tag{display:inline-block;font-size:11px;letter-spacing:.04em;text-transform:uppercase;
padding:2px 7px;border-radius:20px;border:1px solid var(--line);color:var(--dim)}
.tag.you{border-color:var(--warn);color:var(--warn)}
.tag.ok{border-color:var(--ok);color:var(--ok)}
.tag.bad{border-color:var(--bad);color:var(--bad)}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.more{display:inline-block;margin-top:8px;font-size:13.5px}
.bar{height:6px;background:var(--line);border-radius:4px;overflow:hidden;margin-top:6px}
.bar i{display:block;height:100%;background:var(--accent)}
.bar.hot i{background:var(--warn)}
.bar.over i{background:var(--bad)}
table{width:100%;border-collapse:collapse;font-size:13.5px}
th{text-align:left;font-weight:600;color:var(--dim);font-size:11px;
letter-spacing:.05em;text-transform:uppercase;padding:0 8px 6px 0}
td{padding:6px 8px 6px 0;border-top:1px solid var(--line);vertical-align:top}
td.num{text-align:right;font-family:var(--mono);font-size:12.5px;white-space:nowrap}
.scroll{overflow-x:auto}
.err{color:var(--bad);font-size:13.5px}
.foot{margin-top:40px;padding-top:14px;border-top:1px solid var(--line);
color:var(--dim);font-size:12.5px}
"""

# Every phrase of elapsed time on the page is computed here, from the
# instants in the markup, and again every half minute. The page itself is
# rebuilt every thirty minutes at best and may sit open on a phone for a
# day; the staleness banner in particular has to be able to appear on a page
# that was fresh when it was rendered, because the case it exists for — the
# host stopping — is exactly the case where no new render will ever arrive
# to draw it.
JS = """
(function(){
 function pad(n){return (n<10?'0':'')+n}
 function phrase(s){
  if(s<0) return 'in the future';
  if(s<90) return s+'s';
  // Math.floor and not round, to agree with ago() in this file — the
  // rendered fallback and the live text must never disagree by a minute
  // on the same instant, which is what a reader would notice first.
  if(s<5400) return Math.floor(s/60)+'m';
  if(s<172800) return Math.floor(s/3600)+'h'+pad(Math.floor((s%3600)/60))+'m';
  return Math.floor(s/86400)+'d';
 }
 function tick(){
  var now=Date.now();
  var els=document.querySelectorAll('time[datetime]');
  for(var i=0;i<els.length;i++){
   var el=els[i], t=Date.parse(el.getAttribute('datetime'));
   if(isNaN(t)) continue;
   var mode=el.getAttribute('data-mode')||'ago';
   var s=Math.round((mode==='until'?t-now:now-t)/1000);
   el.textContent = mode==='ago' ? phrase(s)+' ago'
                  : mode==='until' ? (s<0?'overdue':'in '+phrase(s))
                  : phrase(s);
  }
  var band=document.getElementById('staleness');
  if(band){
   var t=Date.parse(band.getAttribute('data-at'));
   var mins=(now-t)/60000;
   band.style.display = mins>65 ? '' : 'none';
   var n=document.getElementById('staleness-age');
   if(n) n.textContent=phrase(Math.round((now-t)/1000));
  }
 }
 tick(); setInterval(tick,30000);
 document.addEventListener('visibilitychange',function(){
  if(!document.hidden) tick();
 });
})();
"""


def render():
    parts = []
    add = parts.append

    snap, snap_error = snapshot()
    generated = instant((snap or {}).get("generated_at"))

    add('<div class="wrap">')
    add(
        '<div class="top"><h1><a href="%s">%s</a></h1><div class="icons">'
        % (e(PROFILE_URL), e(NAME))
    )
    for url, icon, title in LINKS:
        add('<a href="%s" title="%s" rel="noreferrer">%s</a>' % (e(url), e(title), icon))
    add("</div></div>")

    # ------------------------------------------------------------ now
    if snap_error:
        add('<p class="hero err">The host snapshot could not be read.</p>')
        add('<p class="err">%s</p>' % e(snap_error))
    else:
        s = snap.get("session") or {}
        last = snap.get("last_session") or {}
        sched = snap.get("schedule") or {}
        started = instant(s.get("started_at"))
        ended = instant(last.get("ended_at"))

        if s.get("running"):
            head = {
                "auto": "An unattended session is running",
                "chat": "A conversation is running",
            }.get(s.get("kind"), "A %s session is running" % e(s.get("kind") or "?"))
            if started:
                head += " — up %s" % when(started, "since")
        elif last.get("forgotten"):
            head = "Idle — no session has ended since this machine last forgot"
        elif ended:
            head = "Idle — the last session ended %s" % when(ended, "ago")
        else:
            head = "Idle"
        add('<p class="hero">%s</p>' % head)

        word = {
            "enabled": "Scheduling enabled",
            "paused": "Scheduling paused",
            "disabled": "Scheduling disabled",
        }.get(sched.get("state"), "Scheduling unknown")
        if sched.get("state") == "enabled" and sched.get("daemon") == "stopped":
            word = '<span class="stale">Scheduling enabled, but cron is not running</span>'
        bits = [word]
        if sched.get("cron"):
            bits.append('<span class="mono">%s</span>' % e(sched["cron"]))
        if (sched.get("cooldown") or "0") not in ("0", ""):
            bits.append("cooldown %s min" % e(sched["cooldown"]))
        add('<p class="age">%s</p>' % " · ".join(bits))

        if generated:
            # Rendered hidden and shown by the script the moment the snapshot
            # passes an hour old. It has to be in the markup already: the
            # failure it announces is the host no longer publishing, and in
            # that failure no later render arrives to add it.
            add(
                '<div class="band bad" id="staleness" data-at="%s" style="display:none">'
                '<b>The host stopped publishing <span id="staleness-age"></span> ago.</b>'
                " Everything below is at least that old."
                "</div>" % e(generated.strftime("%Y-%m-%dT%H:%M:%SZ"))
            )

        add('<p class="age">Host snapshot %s' % when(generated, "ago", "of unknown age"))
        if (snap.get("stats") or {}).get("lines"):
            add(" · " + " · ".join(e(line) for line in snap["stats"]["lines"]))
        add("</p>")

        # The review gate, at the top where a warning belongs. It is repeated
        # in full under The archive; here it is only enough to know that
        # something is being held and that it is waiting on a person.
        t = snap.get("transcripts") or {}
        if t.get("waiting_on_review"):
            add(
                '<div class="band"><b>%d transcript(s) are held out of the archive, '
                "waiting on you.</b> They looked credential-shaped — real or from a "
                'test. <span class="mono">just collect</span> prints what and why; '
                '<span class="mono">just collect --clear &lt;hash&gt; "why"</span> '
                "settles it.</div>" % t["waiting_on_review"]
            )
        elif t.get("error"):
            add(
                '<div class="band bad"><b>The review gate did not answer.</b> %s</div>'
                % e(t["error"])
            )

        for problem in snap.get("errors") or []:
            add('<p class="err">%s</p>' % e(problem))

    # -------------------------------------------------- waiting on you
    waiting, other, issue_error = issues()
    add("<h2>Waiting on you</h2>")
    if issue_error:
        add('<p class="err">The issue list could not be read: %s</p>' % e(issue_error))
    elif not waiting:
        add(
            '<p class="dim">Nothing is assigned to you. %s assigns you '
            "when it is actually waiting; unassigned means it can wait.</p>" % e(NAME)
        )
    else:
        # Every one of them, uncapped. This is the list of things that
        # cannot move without the operator, and the count is bounded by how
        # many they have not answered — if it is ever long enough to want a
        # "more" link, the length is the message.
        for i in waiting:
            add(
                '<div class="card"><div class="row">'
                '<span class="tag you">waiting</span>'
                '<span class="grow"><a href="%s">#%d %s</a></span>'
                '<span class="dim">%s</span></div>'
                '<div class="age">opened by %s · %d comment(s)%s</div></div>'
                % (
                    e(i["url"]),
                    i["number"],
                    e(i["title"]),
                    when(i["updated"]),
                    e(i["author"]),
                    i["comments"],
                    " · last word from %s" % e(i["last_by"]) if i["last_by"] else "",
                )
            )

    # ------------------------------------------------------ open issues
    add("<h2>Open, not waiting on you</h2>")
    if issue_error:
        add('<p class="err">The issue list could not be read: %s</p>' % e(issue_error))
    elif not other:
        add('<p class="dim">Nothing open that is %s\'s call right now.</p>' % e(NAME))
    else:
        add('<div class="scroll"><table>')
        for i in other[:5]:
            add(
                '<tr><td class="mono">#%d</td><td><a href="%s">%s</a></td>'
                '<td class="dim">%s</td></tr>'
                % (i["number"], e(i["url"]), e(i["title"]), when(i["updated"]))
            )
        add("</table></div>")
        if len(other) > 5:
            add('<a class="more" href="%s/issues">%d more →</a>' % (e(SOURCE_URL), len(other) - 5))
        add(
            '<p class="age">Open is not unanswered: the operator closes what '
            "they have settled and leaves open what is %s's call.</p>" % e(NAME)
        )

    # ----------------------------------------------------- the articles
    posts, article_error = articles()
    add("<h2>Articles</h2>")
    if article_error:
        add('<p class="err">The discussions could not be read: %s</p>' % e(article_error))
    elif not posts:
        add('<p class="dim">Nothing published yet.</p>')
    else:
        add('<div class="scroll"><table>')
        for p in posts[:3]:
            add(
                '<tr><td><a href="%s">%s</a></td>'
                '<td class="dim mono">%s</td>'
                '<td class="dim">%d words</td></tr>'
                % (
                    e(p["url"]),
                    e(p["title"]),
                    e(p["created"].strftime("%Y-%m-%d") if p["created"] else "?"),
                    p["words"],
                )
            )
        add("</table></div>")
        if len(posts) > 3:
            add(
                '<a class="more" href="%s/discussions">%d more →</a>'
                % (e(SOURCE_URL), len(posts) - 3)
            )

    # ------------------------------------------------------ the budget
    if snap and not snap_error:
        b = snap.get("budget") or {}
        add("<h2>Budget</h2>")
        # The reading has its own age, separate from the snapshot's. The
        # heartbeat carries the last one forward rather than asking again —
        # the usage endpoint rate-limited the account once and stood every
        # session down for three hours — so these numbers can be older than
        # everything else on the page, and saying so is the whole difference
        # between a stale figure and a lie.
        if b.get("as_of"):
            add(
                '<p class="age">Read %s · carried forward since; it is taken '
                "afresh when a session starts and when one ends.</p>"
                % when(instant(b["as_of"]), "ago", "at an unknown time")
            )
        if b.get("error"):
            add('<p class="err">%s</p>' % e(b["error"]))
        for name, w in (b.get("windows") or {}).items():
            ratio = w.get("ratio") or 0
            klass = "" if ratio < 80 else (" hot" if ratio < 100 else " over")
            add(
                '<div class="card"><div class="row">'
                '<span class="grow"><b>%s</b> <span class="dim">%s window, '
                "budget %s</span></span>"
                '<span class="mono">%.1f%% used of %.1f%% allowed</span></div>'
                '%s<div class="age">%d%% of the allowance · resets %s</div></div>'
                % (
                    e(name.lower()),
                    e(w.get("window")),
                    e(w.get("budget")),
                    w.get("used") or 0,
                    w.get("allowed") or 0,
                    bar(ratio, klass),
                    ratio,
                    when(instant(w.get("resets")), "until"),
                )
            )
        for line in b.get("scoped") or []:
            add('<p class="age">%s</p>' % e(line))
        if b.get("token_renewed"):
            add('<p class="age">The access token was renewed on this reading.</p>')

    # ----------------------------------------------------- the sessions
    rows, total, session_error = sessions()
    add("<h2>Recent sessions</h2>")
    if session_error:
        add('<p class="err">%s</p>' % e(session_error))
    if not rows and not session_error:
        add('<p class="dim">No session has been archived yet.</p>')
    if rows:
        add(
            '<div class="scroll"><table><tr><th>when</th><th>kind</th>'
            "<th>for</th><th>req</th><th>output</th><th>context</th>"
            "<th>what it called itself</th></tr>"
        )
        for r in rows:
            add(
                '<tr><td class="mono">%s %s</td><td>%s</td>'
                '<td class="num">%s</td><td class="num">%s</td>'
                '<td class="num">%s</td><td class="num">%s</td><td>%s</td></tr>'
                % (
                    e(r[0]),
                    e(r[1]),
                    e(r[4]),
                    e(r[2]),
                    e(r[5]),
                    tokens(r[8]),
                    tokens(r[10]),
                    e(r[13]),
                )
            )
        add("</table></div>")
        add(
            '<a class="more" href="%s/tree/sessions">%d archived in all →</a>'
            % (e(ARCHIVE_URL), total)
        )

    # ------------------------------------------------------ the archive
    add("<h2>The archive</h2>")
    m = mirror()
    behind = unpushed()
    if behind:
        # The one failure in this whole arrangement that loses something:
        # transcripts that exist on the host and nowhere else. Only visible
        # from a clone that has both refs, so its absence in CI is absence
        # and not zero.
        add(
            '<div class="band bad"><b>%d collection(s) are on the host and not on '
            "origin.</b> They are in the volume and in the local archive clone, on "
            'one disk. <span class="mono">just collect --push</span></div>' % behind
        )
    if snap and not snap_error:
        t = snap.get("transcripts") or {}
        if t.get("waiting_on_review"):
            add(
                '<div class="card"><span class="tag">held</span> '
                "%d transcript(s) held out of the archive pending review."
                '<div class="age">Credential-shaped content, real or from a test. '
                '<span class="mono">just collect</span> prints what and why.</div>'
                "</div>" % t["waiting_on_review"]
            )
        elif not t.get("error"):
            add('<p class="dim">No transcript is waiting on review.</p>')

    state = m.get("state")
    if state == "active":
        tag = '<span class="tag ok">active</span>'
    elif state is None:
        tag = '<span class="tag bad">unreadable</span>'
    else:
        tag = '<span class="tag bad">%s</span>' % e(state)
    add(
        '<div class="card"><div class="row">%s<span class="grow">'
        '<b>Memory mirror</b></span><span class="dim">last run %s%s</span></div>'
        % (
            tag,
            when(m["last"], "ago", "never"),
            " · " + e(m["conclusion"]) if m.get("conclusion") else "",
        )
    )
    if m.get("tip"):
        add(
            '<div class="age">%s last pushed %s — <span class="mono">%s</span> %s</div>'
            % (e(NAME), when(m["tip_at"]), e(m["tip"][0]), e(m["tip"][1]))
        )
    if m.get("rewinds"):
        add(
            '<div class="age">%d rewrite(s) preserved as tags: %s</div>'
            % (len(m["rewinds"]), e(", ".join(m["rewinds"][:3])))
        )
    if m.get("error"):
        add('<div class="err">%s</div>' % e(m["error"]))
    add("</div>")

    # ------------------------------------------------------------ footer
    add('<div class="foot">')
    if snap and not snap_error:
        im = snap.get("image") or {}
        add(
            "Claude Code %s · base %s<br>"
            % (
                e(im.get("claude_code_version") or "?"),
                e((im.get("base_digest") or "unpinned")[:19]),
            )
        )
    expiry, expiry_error = token_expiry()
    if expiry:
        w = instant(expiry.replace(" UTC", "").replace(" ", "T", 1))
        days = int((w - NOW).total_seconds() // 86400) if w else None
        add(
            "Read token expires %s%s<br>"
            % (e(expiry), " — %d days" % days if days is not None else "")
        )
    elif expiry_error:
        add('<span class="err">Token expiry unknown: %s</span><br>' % e(expiry_error))
    add(
        "Rendered %s · the host publishes, this page reads." % e(NOW.strftime("%Y-%m-%d %H:%M UTC"))
    )
    add("</div></div>")

    return (
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="color-scheme" content="light dark">'
        "<title>%s — status</title><style>%s</style></head><body>%s"
        "<script>%s</script></body></html>" % (e(NAME), CSS, "".join(parts), JS)
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="page.html")
    args = ap.parse_args()
    page = render()
    with open(args.out, "w") as f:
        f.write(page)
    print("%s — %d bytes" % (args.out, len(page)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
