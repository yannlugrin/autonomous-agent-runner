# The status page — optional

A private web page showing what the runner and the agent are doing: whether
a session is running, what the account has spent, what is waiting on you,
what the agent last published, and whether the mirror is alive. It is a
convenience, not a mechanism. Nothing in the runner needs it, and
`just status` answers most of the same questions on the terminal.

**It needs a Cloudflare account** — a Workers script, a KV namespace, and
Cloudflare Access in front of it. Free tiers are enough. Without one, delete
this directory and `check-credentials.yml` with it.

## How it fits together

    dashboard.yml (here, every 30 min)
      reads   sessions, status, refs/archive/<agent>, and the agent's
              issues and discussions through a read-only token
      renders one self-contained HTML file with scripts/render.py
      writes  it into one Cloudflare KV key called `page`

    worker/index.js (deployed by hand)
      verifies the Cloudflare Access token on every request
      serves  whatever is in that KV key, and nothing else

The Worker renders nothing and reaches nothing. The page is built in CI,
where it can be read before it ships.

## Installing it

1. Move the files into place on `main` of the archive:
   `dashboard.yml` → `.github/workflows/`, `scripts/render.py` → `scripts/`
   (beside `session-meta.jq`, which it reads from its own directory), and
   `worker/` → `worker/`.
2. Replace every `REPLACE_WITH_` in all three. `git grep REPLACE_WITH_`
   lists what is left.
3. Create the KV namespace and a token that may write it, and a
   fine-grained GitHub token that is read-only on the agent's repository
   with Issues and Discussions read. Set the four secrets:
   `<PREFIX>_READ_TOKEN`, `CF_ACCOUNT_ID`, `CF_KV_NAMESPACE_ID`,
   `CF_KV_TOKEN`.
4. `gh workflow run check-credentials.yml` — it proves all four without
   printing one, and each failure names which secret it just tried.
5. Deploy the Worker by hand from `worker/`: `npx wrangler deploy`. Not from
   CI, deliberately — CI holds a token that can write one KV key and nothing
   else, so it cannot replace the door it comes through.

## Two things that fail silently

**`workers_dev = false`.** Left at its default, the Worker also answers on
`<name>.<account>.workers.dev` — the whole private page, on a hostname
Access has never heard of, with nothing to warn you. Probe that hostname
after deploying.

**Access protecting a route looks exactly like Access not protecting it**,
from every side but an unauthenticated request. So `worker/index.js`
verifies the Access assertion itself as well: if the application is deleted,
the policy loosened, or the route reached by a path that skips Access, it
still refuses.

Run `python3 scripts/render.py --out /tmp/page.html` from a clone to see a
change before it is on the real hostname.
