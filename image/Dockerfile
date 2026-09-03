# syntax=docker/dockerfile:1

# The environment the agent lives in. This repository belongs to the operator;
# the agent has read access and never write, because the thing that defines a
# confinement must not be editable by what it confines.
#
# The Dockerfile is only half the story. Every dangerous capability is a
# *run-time* flag, so a careful image launched carelessly is not isolated at
# all — see compose.yaml and the list of things never to add to it.

# Node, because Claude Code installs from npm.
#
# A tag is not a pin — it moves underneath you and the rebuild says nothing.
# `just pin` resolves the digest, writes it here with the date it was taken,
# and commits nothing: read the diff it prints.
# see docs/release.md#the-two-pins
# Digest taken 2026-09-03. Re-pin with `just pin --image`.
FROM node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

# Who the agent is, inside: a value and not a literal, because a name spelled
# into forty files is forty places for someone else's to be wrong. The defaults
# are what a bare `docker build` gets, and must stay generic — one that happens
# to be right for an installation is one nobody notices is being used.
# see docs/image.md#everything-derives-from-agent_user
ARG AGENT_USER=agent
ARG AGENT_HOME=/home/agent

# Where the checkout lands, needed at build time by one thing: the permission
# rule allowing the agent's own tools/ directory, rendered below. compose passes
# it at run time too and `just verify` compares them — a rendered rule that no
# longer matches the running checkout denies nothing and allows nothing, so
# every tool call quietly starts asking for approval.
ARG AGENT_REPO_DIR=/home/agent/agent

# The names the classifier is told. The autoMode block describes THIS
# installation, because a classifier that cannot resolve a name it meets in a
# transcript against the trusted list is judging blind — and the tree names
# nobody, so the committed file carries placeholders and the substitution
# happens here. Empty tells the classifier nothing rather than telling it wrong.
#
# The community is not among them: it is a sentence and not a name, so it comes
# from community.txt in the build context, read by the render below.
ARG AGENT_NAME=agent
ARG AGENT_DOMAIN=
ARG AGENT_MODEL=sonnet
ARG OPERATOR_NAME=Operator
ARG OPERATOR_GITHUB_HANDLE=

# How long transcripts survive in the volume, rendered into managed settings
# below. 30 is Claude Code's own default, so an unset variable changes nothing.
# The operator's value lives in .env, beside what it costs.
ARG AGENT_TRANSCRIPT_RETENTION_DAYS=30

# Deliberately small. What the agent later discovers it needs, it installs
# into its own home; a new system package is a rebuild, which is the price
# of it running unprivileged.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        less \
        openssh-client \
        python3 \
        python3-venv \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# gh from GitHub's own apt repository rather than Debian's, which lags by
# years — the same choice the dotfiles make on the host.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Claude Code, pinned: an agent whose harness changes underneath it cannot
# tell a behaviour change from one of its own mistakes, and every measurement
# it recorded was taken on a version.
# see docs/image.md#the-claude-code-pin-held-for-one-day
# Version taken 2026-09-03. Re-pin with `just pin --claude`.
ARG CLAUDE_CODE_VERSION=2.1.259
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# The same number, carried into every container so what runs can be compared
# with what was meant to run. Assigned from the ARG, never retyped: a second
# hand-maintained copy is the copy that goes stale, invisibly, in exactly the
# case this exists to catch.
#
# It exists because the pin installs a version and does not KEEP it: PATH (set
# further down) puts ~/.npm-global/bin and ~/.local/bin ahead of /usr/local/bin,
# both inside the volume, so a second `claude` landing there wins the lookup and
# survives every rebuild. see docs/image.md#path-defeats-the-pin
ENV AGENT_CLAUDE_VERSION=${CLAUDE_CODE_VERSION}

# accept-new, not yes: the first connection is trusted and recorded, and a later
# change of host key is refused rather than swallowed. Unattended runs cannot
# answer a prompt, and baking GitHub's host key pins one that has rotated
# before. In /etc and not in the home, which the volume freezes at first run.
# see docs/image.md#accept-new-not-yes
RUN printf '%s\n' \
        'Host github.com' \
        '    StrictHostKeyChecking accept-new' \
        > /etc/ssh/ssh_config.d/10-github.conf \
    && chmod 644 /etc/ssh/ssh_config.d/10-github.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# The boundary. Managed settings outrank every other source, and this path
# is outside the volume and owned by root while the agent runs unprivileged —
# so nothing it writes in its own repository can loosen what is here. It is
# readable on purpose: it may see what confines it and report a defect.
# see docs/boundary.md
COPY managed-settings.json /etc/claude-code/managed-settings.json

# The community sentence, from the build context rather than from a build
# argument: it is a sentence and not a name, and `.env` is no place for a
# paragraph. Read by the render below and removed in the same step — the
# rendered sentence in managed settings is the only copy, and a second one the
# agent could read is a second one to drift.
# see docs/configuration.md#the-three-files-that-are-yours
COPY config/community.txt /tmp/community.txt
RUN python3 - "$AGENT_REPO_DIR" "$AGENT_USER" "$AGENT_NAME" "$AGENT_DOMAIN" \
             "$OPERATOR_NAME" "$OPERATOR_GITHUB_HANDLE" "$AGENT_MODEL" \
             "$AGENT_TRANSCRIPT_RETENTION_DAYS" <<'RENDER' \
    && chmod 0644 /etc/claude-code/managed-settings.json \
    && rm -f /tmp/community.txt
import json, pathlib, sys
p = pathlib.Path("/etc/claude-code/managed-settings.json")
s = p.read_text()
for name, value in zip(("AGENT_REPO_DIR", "AGENT_USER", "AGENT_NAME", "AGENT_DOMAIN",
                        "OPERATOR_NAME", "OPERATOR_GITHUB_HANDLE",
                        "AGENT_MODEL"), sys.argv[1:]):
    s = s.replace("{{%s}}" % name, value)
# Comments out, then all whitespace collapsed, because this lands INSIDE a
# sentence. Nothing left is the literal `none` and not empty: empty would leave
# "**Its community**: ." — a hole that reads as a rendering fault rather than as
# an answer.
lines = [line for line in pathlib.Path("/tmp/community.txt").read_text().splitlines()
         if not line.lstrip().startswith("#")]
s = s.replace("{{AGENT_COMMUNITY}}", " ".join(" ".join(lines).split()) or "none")
# The retention is the one value that must land as a JSON NUMBER, so its
# quotes are replaced along with it — the committed file has to stay
# parseable for the host-side readers of it. `0` is valid JSON and means
# delete everything at the next session start, so a typo in .env would wipe
# the corpus with no symptom until it was gone.
days = sys.argv[8]
if not sys.argv[7].strip():
    sys.exit("managed-settings.json: the model is empty — unset <NAME>_MODEL rather than blanking it")
if not days.isdigit() or int(days) < 1:
    sys.exit(f"managed-settings.json: retention {days!r} is not a whole number of days, 1 or more")
s = s.replace('"{{TRANSCRIPT_RETENTION_DAYS}}"', days)
# Before writing, not after: a template that still carries a placeholder is a
# boundary nobody chose, and it is silent in both directions.
if "{{" in s:
    sys.exit("managed-settings.json: unsubstituted placeholder remains")
json.loads(s)   # and still valid JSON after substitution
p.write_text(s)
RENDER

# The backup hook, registered by the managed settings above. It lives here
# rather than in the agent's repository because a hook the agent could blank
# would stop backing up with no symptom at all. see docs/backup.md
COPY push-on-exit.sh /usr/local/bin/push-on-exit.sh
RUN chmod 0755 /usr/local/bin/push-on-exit.sh

# The PreToolUse guard, registered by the managed settings above, and here for
# the same reason as the hook beside it. It says on parsed argv what a prefix
# rule cannot: `env BWS_PROBE=1 bws --help` and `sh -c 'gh auth token'` are
# gated acts behind a wrapper, and neither begins with a string the deny list
# can match. vault-exempt.txt and secret-shapes.txt sit beside it because the
# guard is the only reader either has in the image; the checkout's own copies
# are what `just collect` reads on the host, and COPY is the comparison.
# see docs/boundary.md
#
# --selftest at build time, deliberately: this guard fails OPEN, so a guard that
# cannot decide correctly must stop the build rather than ship quiet.
# see docs/image.md#selftests-at-build-time
COPY config/vault-exempt.txt /etc/agent/vault-exempt.txt
COPY config/secret-shapes.txt /etc/agent/secret-shapes.txt
COPY bash-guard.py /usr/local/bin/bash-guard.py
RUN chmod 0755 /usr/local/bin/bash-guard.py \
    && python3 /usr/local/bin/bash-guard.py --selftest

# What the account has spent, read from its own rate limits. It REPORTS; whether
# that report refuses anything belongs to whoever reads its exit status, and the
# host and the container want opposite answers. see docs/budget.md
#
# Baked in, root-owned and outside the volume for the reason the two above are:
# what the agent could edit is what the agent decides for itself. Its --selftest
# is the proof that costs nothing — the arithmetic is pure, and a wrong
# allowance reads exactly like a right one.
COPY claude-usage.py /usr/local/bin/claude-usage
RUN chmod 0755 /usr/local/bin/claude-usage \
    && python3 /usr/local/bin/claude-usage --selftest

# What a session cost, in dollars, from its own transcript. The neighbour above
# answers for the ACCOUNT — one login the operator's own sessions share — so
# nothing there can say what one session spent. It reads transcripts and nothing
# else. Baked in and root-owned because a price table the agent can edit is a
# price table that says what the agent would like, and its --selftest is there
# for the neighbour's reason: a wrong price prints like a right one.
COPY session-cost.py /usr/local/bin/session-cost
RUN chmod 0755 /usr/local/bin/session-cost \
    && python3 /usr/local/bin/session-cost --selftest

# The vault. `bws` is pinned to a version AND to the digest of the archive that
# version resolves to — a tag can be moved and a release asset replaced, and
# neither leaves a mark. Unpacked with python3's zipfile rather than unzip,
# which is one package this image does not otherwise need.
#
# It is DENIED to the session, by the guard and by the managed deny list both:
# /usr/local/bin/vault is the route, because only `vault` puts a fetched secret
# in a file the guard can compare a commit against. see docs/vault.md
ARG BWS_VERSION=2.1.0
ARG BWS_SHA256=ba8233c3a4aee5d43e3c73bbd04d99e9bc5aba13bbbfd06d89b073abe732b860
RUN curl -fsSL -o /tmp/bws.zip \
        "https://github.com/bitwarden/sdk-sm/releases/download/bws-v${BWS_VERSION}/bws-x86_64-unknown-linux-gnu-${BWS_VERSION}.zip" \
    && echo "${BWS_SHA256}  /tmp/bws.zip" | sha256sum -c - \
    && python3 -c "import zipfile,sys; zipfile.ZipFile('/tmp/bws.zip').extractall('/usr/local/bin')" \
    && chmod 0755 /usr/local/bin/bws \
    && rm -f /tmp/bws.zip \
    && /usr/local/bin/bws --version

COPY vault.sh /usr/local/bin/vault
RUN chmod 0755 /usr/local/bin/vault

# What puts the vault's ENVIRONMENT credentials into the environment, for both
# the session and the budget gate. Here rather than in the entrypoint because
# the gate deliberately does not run the entrypoint — it must not clone a
# repository to answer whether a session may start — and a credential that
# reached only one of the two would have the gate measuring a login the session
# does not use. see docs/vault.md
COPY vault-env.sh /usr/local/bin/vault-env
RUN chmod 0755 /usr/local/bin/vault-env

# The system prompt a session runs on, and what renders it. Here rather than in
# the agent's repository for the guard's reason: it is the one text that speaks
# to the agent every session through a layer it cannot answer.
#
# `run`, `chat` and the verify probes start `claude-session` instead of
# `claude`; a `claude` typed by hand in `just shell` is not intercepted — a
# documented gap, chosen over a PATH shim that would have had to tell a session
# from `claude login` by parsing arguments. Rendered once at build, because from
# inside a session a literal `{{NOW}}` is invisible. see docs/sessions.md
COPY system-prompt-template.md /usr/local/share/agent/system-prompt-template.md
COPY claude-session.py /usr/local/bin/claude-session
RUN chmod 0644 /usr/local/share/agent/system-prompt-template.md \
    && chmod 0755 /usr/local/bin/claude-session \
    && /usr/local/bin/claude-session --render >/dev/null

# uid 1001, not 1000: the node base already owns 1000, and a collision on a
# named volume produces permission errors that read as anything but. The home
# directory created here is what gives the fresh volume its ownership; nothing
# else needs to be placed in it.
# see docs/image.md#uid-1001-not-1000
RUN useradd --create-home --uid 1001 --shell /bin/bash --home-dir "$AGENT_HOME" "$AGENT_USER"

USER ${AGENT_USER}
WORKDIR ${AGENT_HOME}

# No checkout directory is created here, deliberately. `git clone` makes it,
# owned by agent, and a pre-existing one is only ever in the way — clone
# refuses to write into a directory that already holds something.
# see docs/image.md#docker-run--w-creates-the-path-as-root

# Userspace prefixes: the agent runs unprivileged and no-new-privileges
# blocks escalation, so it installs npm packages and python venvs for
# itself and never with apt.
ENV NPM_CONFIG_PREFIX=${AGENT_HOME}/.npm-global \
    PATH=${AGENT_HOME}/.npm-global/bin:${AGENT_HOME}/.local/bin:$PATH \
    TZ=UTC \
    LANG=C.UTF-8

# What this image was built from, measured on the host by `just build` and
# passed in, because the build context is image/ and carries no .git.
#
# Last on purpose: they change with every commit and an ARG invalidates every
# layer below it, so higher up they would rebuild the whole image for a one-line
# change. Empty is a legitimate answer — claude-session.py then says the image
# does not say, rather than naming a commit that is not one.
# see docs/image.md#what-the-image-was-built-from
ARG RUNNER_COMMIT=
ARG RUNNER_COMMITTED_AT=
ENV AGENT_RUNNER_COMMIT=${RUNNER_COMMIT} \
    AGENT_RUNNER_COMMITTED_AT=${RUNNER_COMMITTED_AT}

# Nothing personal is written into /home/agent at build time. The volume
# shadows it and is seeded only at first creation, so anything placed there
# would freeze at first run and ignore every later rebuild — silently. Git
# identity, the SSH key and the checkout are all the entrypoint's job, and it
# runs on every start. see docs/image.md#the-volume-is-seeded-once
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash", "-l"]
