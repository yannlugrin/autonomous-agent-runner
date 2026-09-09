#!/usr/bin/env bash
# Provision an Ubuntu host to run the agent, when it does not run beside you.
#
# Runs ON THAT HOST, as a user with sudo (Ubuntu's own `ubuntu`), before the
# repository is cloned: it is self-contained on purpose and sources nothing —
# it cannot assume the checkout, because it is what makes the checkout possible.
# Idempotent — run it again after a failure and it picks up where it stopped.
#
# TWO USERS, and that is the point. The account that provisions has sudo; the
# account that runs the agent and receives deploys has none. It does have the
# docker group, which is root-equivalent — anyone who can reach the socket can
# mount / into a container — so the split is a guard against a mistyped command
# and a narrow blast radius, NOT a boundary against someone holding the key.
# Rootless docker is what would make it one, and costs cgroup delegation for
# mem_limit to keep working.
#
# It installs and it checks. It creates no credential, copies no secret and
# clones nothing: those are the steps a person has to make a judgement about,
# and they are in README.md beside this file.
#
#   scp examples/vps/provision.sh vps-admin:
#   ssh vps-admin 'DEPLOY_USER=agent-deploy bash provision.sh'
set -uo pipefail

# The account the agent runs as. Neutral by default: the agent's name does not
# appear in this repository's content.
DEPLOY_USER="${DEPLOY_USER:-agent-deploy}"

# The oldest `just` the justfile can be read by — `set minimum-version` in it.
# An older one dies at parse time, hourly, into a log nobody reads.
JUST_MIN=1.55.0
JUST_VERSION=1.58.0
# Empty means: verify against the release's own SHA256SUMS and print the digest,
# so it can be pinned here afterwards. The shape image/Dockerfile uses for bws.
JUST_SHA256=""

SWAP_GB=2

# At rest this takes about 7 GB: the OS and docker ~3, the volume 2.3, the image
# 1.2, the archive clone 0.4. DISK_MIN_GB is where that no longer fits with room
# to run; DISK_RECOMMENDED_GB is where the archive can grow for years without
# anyone thinking about it. The volume itself is bounded — Claude Code prunes
# transcripts past AGENT_TRANSCRIPT_RETENTION_DAYS — the archive is not.
DISK_MIN_GB=10
DISK_RECOMMENDED_GB=40

# What the machine needs, from what a session was measured to take: 450 MB
# steady, 535 MB at its peak. RAM_MIN_MB is ram alone, below which swap will not
# make it comfortable; MEM_RECOMMENDED_MB is ram plus swap, which is what the
# design actually rests on.
RAM_MIN_MB=1500
MEM_RECOMMENDED_MB=3500


# --- the verdict vocabulary ---
# The same three words `just verify` speaks, so what this prints reads the way
# the rest of the repository does. The word and the column carry the meaning;
# no check is told apart by colour.

ok=0; fail=0; look=0; fail_lines=""; look_lines=""

verdict() {
    local st="$1" label="$2" line; shift 2
    case "$st" in
        ok)   ok=$((ok + 1)); printf '  [ ok ] %-16s %s\n' "$label" "$*" ;;
        LOOK) look=$((look + 1)); line=$(printf '  [LOOK] %-16s %s' "$label" "$*")
              look_lines="$look_lines$line"$'\n'; printf '%s\n' "$line" ;;
        *)    fail=$((fail + 1)); line=$(printf '  [FAIL] %-16s %s' "$label" "$*")
              fail_lines="$fail_lines$line"$'\n'; printf '%s\n' "$line" ;;
    esac
}

step() { printf '\n== %s ==\n' "$1"; }

# --- slow ---
# A long command with a dot every two seconds and its output kept back for the
# failure case. Minutes of silence read as a freeze, and the answer is not to
# print hundreds of apt lines into a list whose whole value is that it can be
# scanned: it is to show that something is still happening.

slow() {
    local log rc pid
    log=$(mktemp)
    "$@" >"$log" 2>&1 &
    pid=$!
    printf '         '
    while kill -0 "$pid" 2>/dev/null; do printf '.'; sleep 2; done
    wait "$pid"; rc=$?
    printf '\n'
    [ "$rc" -ne 0 ] && tail -20 "$log" >&2
    rm -f "$log"
    return "$rc"
}

# Everything the deploy user does. NOT `sudo -i`: that joins its arguments into
# one string and has the login shell parse it again, which destroys quoting and
# newlines — a multi-line command arrives as words, and a `{{...}}` format string
# arrives brace-expanded. `-H` gives the target's HOME with argv left intact, and
# the callers ask for `bash -lc` where they need the profile read.
as_deploy() { sudo -H -u "$DEPLOY_USER" "$@"; }


# --- sanity ---

step "the machine"

# shellcheck disable=SC1091  # read at run time on the VPS, absent here
. /etc/os-release 2>/dev/null || true
printf '         %-18s %s\n' "os:" "${PRETTY_NAME:-unknown}"
printf '         %-18s %s\n' "kernel:" "$(uname -r)"
printf '         %-18s %s\n' "arch:" "$(uname -m)"
printf '         %-18s %s\n' "deploy user:" "$DEPLOY_USER"

[ "$(id -u)" -eq 0 ] && {
    echo "Run this as the sudo-capable user, not as root: the deploy account is" >&2
    echo "created from the invoking user's authorized_keys, and root's are not yours." >&2
    exit 2; }

sudo -n true 2>/dev/null || sudo true || {
    echo "This needs sudo for the package steps and cannot get it." >&2; exit 2; }

if [ "${ID:-}" = ubuntu ]; then
    verdict ok "distribution" "${PRETTY_NAME}"
else
    verdict LOOK "distribution" "not Ubuntu (${ID:-unknown}) — the apt steps below assume it"
fi

ram_mb=$(free -m | awk '/^Mem:/{print $2}')
printf '         %-18s %s\n' "ram:" "${ram_mb} MB"

disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "$disk_gb" -ge "$DISK_RECOMMENDED_GB" ]; then
    verdict ok "disk" "${disk_gb} GB free on /"
elif [ "$disk_gb" -ge "$DISK_MIN_GB" ]; then
    verdict LOOK "disk" "${disk_gb} GB free on / — about 7 of them go at once, and the archive clone grows with every session"
else
    verdict FAIL "disk" "${disk_gb} GB free on /, under the ${DISK_MIN_GB} floor — roughly 7 GB is taken before anything runs"
fi


# --- swap ---
# 2 GB on a 2 GB machine, so a spike or two containers degrade instead of having
# the kernel pick a victim. Skipped where any swap already exists.

step "swap"

if [ "$(free -m | awk '/^Swap:/{print $2}')" -gt 0 ]; then
    verdict ok "swap" "$(free -m | awk '/^Swap:/{print $2}') MB already present"
elif [ -e /swapfile ]; then
    verdict LOOK "swap" "/swapfile exists but is not in use — 'swapon /swapfile', and check /etc/fstab"
else
    # A && B || C is what is meant: any step failing is the same refusal.
    # shellcheck disable=SC2015
    sudo fallocate -l "${SWAP_GB}G" /swapfile \
        && sudo chmod 600 /swapfile \
        && sudo mkswap /swapfile >/dev/null \
        && sudo swapon /swapfile \
        && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null \
        && verdict ok "swap" "${SWAP_GB} GB at /swapfile, and in /etc/fstab" \
        || verdict FAIL "swap" "could not create /swapfile"
fi


# --- memory, ruled on once swap is in ---
# On the total, because that is what the design rests on: a session measured
# 450 MB steady and the machine this runs on is deliberately small. RAM alone
# would report the intended configuration as something to look at, every run,
# which is how a check teaches you to skip it.

total_mb=$(( ram_mb + $(free -m | awk '/^Swap:/{print $2}') ))
if [ "$total_mb" -ge "$MEM_RECOMMENDED_MB" ]; then
    verdict ok "memory" "${total_mb} MB with swap, at or above ${MEM_RECOMMENDED_MB}"
elif [ "$ram_mb" -ge "$RAM_MIN_MB" ]; then
    verdict LOOK "memory" "${total_mb} MB with swap, under the ${MEM_RECOMMENDED_MB} wanted — it runs, with less room for a burst"
else
    verdict LOOK "memory" "${ram_mb} MB of ram, under the ${RAM_MIN_MB} floor — swap will not make that comfortable"
fi


# --- the base packages ---
# git, jq, python3 and flock are what host/verify/host-tools.sh requires; cron is
# what runs the agent at all. A missing flock reads as a held lock and skips
# every hour in silence, which is why it is checked and not assumed.

step "base packages"

sudo apt-get update -qq

# Applying what is already pending is part of making a machine fit to be left
# alone, and provisioning is the one moment a reboot costs nothing. Guarded on a
# running container: this script is idempotent and a re-run on a live host must
# not restart the daemon under a session. docker may not exist yet on the first
# run, which is correctly read as nothing running.
busy=no
command -v docker >/dev/null 2>&1 && [ -n "$(docker ps -q 2>/dev/null)" ] && busy=yes

waiting=""
[ -x /usr/lib/update-notifier/apt-check ] && waiting=$(/usr/lib/update-notifier/apt-check 2>&1)

if [ "$busy" = yes ]; then
    verdict LOOK "system upgrade" "containers are running — skipped, so nothing restarts under a session"
else
    printf '         %s to apply; on a fresh image this takes minutes\n' \
        "${waiting%%;*} update(s)"
    if slow sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold; then
        verdict ok "system upgrade" "everything pending applied"
    else
        verdict FAIL "system upgrade" "dist-upgrade failed — the lines above are its last words, and the machine is part-way"
    fi
fi

printf '         installing the base packages\n'
if slow sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git jq python3 python3-venv curl ca-certificates gnupg cron util-linux; then
    verdict ok "apt base" "git jq python3 curl cron util-linux"
else
    verdict FAIL "apt base" "apt-get failed — nothing below will hold"
fi

sudo systemctl enable --now cron >/dev/null 2>&1
if systemctl is-active --quiet cron; then
    verdict ok "cron running" "$(systemctl is-enabled cron 2>/dev/null)"
else
    verdict FAIL "cron running" "cron is not active — no unattended session would ever start"
fi


# --- unattended upgrades ---
# A host nobody logs into has to patch itself. Whether unattended-upgrades is on
# is reported and not changed — that is a policy for a machine, not for this
# agent — and read from the resolved configuration rather than from a file,
# because the file holding a value is not always the file that wins. What IS
# applied, above, is the backlog: a fresh image is months behind, and the count
# below reads what is left once that has run.

step "security updates"

apt_key() { apt-config dump | sed -n "s/^$1 \"\(.*\)\";\$/\1/p"; }

lists=$(apt_key 'APT::Periodic::Update-Package-Lists')
unattended=$(apt_key 'APT::Periodic::Unattended-Upgrade')

if [ "${lists:-0}" != 0 ] && [ "${unattended:-0}" != 0 ]; then
    verdict ok "security updates" "unattended-upgrades is on"
else
    verdict LOOK "security updates" "lists=${lists:-unset} upgrade=${unattended:-unset} — a machine left alone is not patching itself"
fi

# Absent means the program's own default, which is false. It matters because a
# reboot lands on whatever session is running, and nothing reports that
# off-machine.
reboot=$(apt_key 'Unattended-Upgrade::Automatic-Reboot')
case "${reboot:-false}" in
    true|1) verdict LOOK "automatic reboot" "on — it will reboot under a running session, at Automatic-Reboot-Time" ;;
    *)      verdict ok "automatic reboot" "off${reboot:+ ($reboot)}" ;;
esac

# What is actually waiting, not what is configured: "unattended-upgrades is on"
# with a hundred security updates pending is a true sentence that misleads. The
# count comes from the MOTD's own source, so this number and the one printed at
# login are one thing rather than two that can disagree.
pending=""
[ -x /usr/lib/update-notifier/apt-check ] && pending=$(/usr/lib/update-notifier/apt-check 2>&1)
security=${pending##*;}
case "$security" in ''|*[!0-9]*) security=0 ;; esac

if [ -z "$pending" ]; then
    verdict LOOK "updates pending" "not counted — no /usr/lib/update-notifier/apt-check here"
elif [ "$security" -eq 0 ]; then
    verdict ok "updates pending" "none waiting"
else
    verdict LOOK "updates pending" "$security security updates still waiting, ${pending%%;*} in all — the upgrade above did not take them; look before going further"
fi

# Free to act on now, expensive later: a reboot lands on whatever session is
# running, and nothing reports that off-machine. It is only an answer once the
# updates above are applied — this runs before them, so a clean result on a
# machine with a kernel waiting means nothing yet, and says so.
if [ -e /var/run/reboot-required ]; then
    verdict LOOK "reboot required" "pending — 'sudo reboot' now, before the agent runs here"
else
    verdict ok "reboot required" "none pending"
fi


# --- docker ---
# Docker's own apt repository, not Ubuntu's docker.io and never the snap: the
# snap's confinement breaks named-volume access in ways that read as permission
# bugs in the container, and docker.io lags the compose plugin this uses.

step "docker"

if ! command -v docker >/dev/null 2>&1; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    printf '         installing docker-ce and its plugins\n'
    slow sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if command -v docker >/dev/null 2>&1; then
    verdict ok "docker" "$(docker --version 2>/dev/null)"
else
    verdict FAIL "docker" "not installed — nothing in the repository runs"
fi

if docker compose version >/dev/null 2>&1; then
    verdict ok "compose" "$(docker compose version 2>/dev/null | head -1)"
else
    verdict FAIL "compose" "no compose plugin — every recipe that starts a container fails"
fi

sudo systemctl enable --now docker >/dev/null 2>&1
if systemctl is-active --quiet docker; then
    verdict ok "docker running" "and enabled at boot"
else
    verdict FAIL "docker running" "the daemon is not up"
fi


# --- tailscale ---
# A permanent system service here, which is the opposite of how the machine you
# work at runs it: `just listen --remote` starts its own userspace daemon in the
# foreground of a window, because that machine may keep nothing alive past it. A
# server has no such rule, and a daemon that is always up is what lets the live
# view and Tailscale SSH work without anyone being there.
#
# Installed and enabled only. Joining the tailnet is a credential step and an ACL
# decision, and both are in README.md.

step "tailscale"

if ! command -v tailscale >/dev/null 2>&1; then
    if curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg" \
        | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
       && curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.tailscale-keyring.list" \
        | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null; then
        sudo apt-get update -qq
        printf '         installing tailscale\n'
        slow sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
    else
        verdict FAIL "tailscale" "no package repository for ${VERSION_CODENAME:-this release} — the static tarball from pkgs.tailscale.com is the fallback"
    fi
fi

if command -v tailscale >/dev/null 2>&1; then
    verdict ok "tailscale" "$(tailscale version 2>/dev/null | head -1)"
    sudo systemctl enable --now tailscaled >/dev/null 2>&1
    if systemctl is-active --quiet tailscaled; then
        verdict ok "tailscaled" "running and enabled at boot"
    else
        verdict FAIL "tailscaled" "the daemon is not up"
    fi

    # Logged out is the expected state at provisioning time and is not a defect:
    # `tailscale up` is a person's step. What matters once it IS logged in is the
    # node's key expiry — 180 days by default, after which a headless machine
    # silently leaves the tailnet.
    backend=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "unknown"')
    case "$backend" in
        Running)
            expiry=$(tailscale status --json 2>/dev/null | jq -r '.Self.KeyExpiry // empty')
            if [ -z "$expiry" ]; then
                verdict ok "tailnet" "joined, and this node's key does not expire"
            else
                verdict LOOK "tailnet" "joined, but the key expires $expiry — a headless node drops off the tailnet in silence; tag it or disable expiry"
            fi ;;
        NeedsLogin|Stopped|NoState)
            verdict LOOK "tailnet" "not joined ($backend) — 'tailscale up --ssh' is a step in README.md" ;;
        *)
            verdict LOOK "tailnet" "state is $backend" ;;
    esac
fi

# Only `just listen --remote` wants it, and it names the same package.
if command -v ttyd >/dev/null 2>&1; then
    verdict ok "ttyd" "$(command -v ttyd)"
elif sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ttyd >/dev/null 2>&1; then
    verdict ok "ttyd" "$(command -v ttyd) — the live view's server"
else
    verdict LOOK "ttyd" "not installed; only 'just listen --remote' wants it"
fi


# --- gh ---
# From GitHub's own apt repository, because Ubuntu's lags. Two things on this
# machine want it: `dispatch-mirror.sh`, which asks the mirror to run at the end
# of every session, and `mirror-status`, which the status page reads for the
# workflow's state and its last run. Both degrade rather than fail without it —
# the mirror falls back to its daily backstop — which is why
# host/verify/host-tools.sh calls gh `spare` and not required.
#
# The credential they need is a separate matter and arrives later; the binary is
# part of what this machine is for.

step "gh"

if ! command -v gh >/dev/null 2>&1; then
    if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null; then
        sudo chmod a+r /usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt-get update -qq
        printf '         installing gh\n'
        slow sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
    fi
fi

if command -v gh >/dev/null 2>&1; then
    verdict ok "gh" "$(gh --version 2>/dev/null | head -1)"
else
    verdict FAIL "gh" "not installed — no session end would ask the mirror to run, leaving it on its daily backstop"
fi


# --- just ---
# The justfile declares `set minimum-version := '1.55.0'`, and an older one does
# not warn: it fails to parse. Ubuntu's is used when it is new enough, and the
# release binary otherwise.

step "just"

have=""
command -v just >/dev/null 2>&1 && have=$(just --version 2>/dev/null | awk '{print $2}')

new_enough() { [ "$(printf '%s\n%s\n' "$JUST_MIN" "$1" | sort -V | head -1)" = "$JUST_MIN" ]; }

if [ -z "$have" ]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq just >/dev/null 2>&1
    command -v just >/dev/null 2>&1 && have=$(just --version 2>/dev/null | awk '{print $2}')
fi

if [ -n "$have" ] && new_enough "$have"; then
    verdict ok "just" "$have, at or above $JUST_MIN"
else
    [ -n "$have" ] && echo "         apt's just is $have, below $JUST_MIN — taking the release binary"
    tmp=$(mktemp -d)
    tarball="just-${JUST_VERSION}-$(uname -m)-unknown-linux-musl.tar.gz"
    base="https://github.com/casey/just/releases/download/${JUST_VERSION}"
    if curl -fsSL "$base/$tarball" -o "$tmp/$tarball"; then
        got=$(sha256sum "$tmp/$tarball" | awk '{print $1}')
        if [ -n "$JUST_SHA256" ]; then
            want="$JUST_SHA256"
        else
            # Trust on first use: the release's own list. Print the digest so it
            # can be pinned at the top of this file and compared from then on.
            want=$(curl -fsSL "$base/SHA256SUMS" | awk -v f="$tarball" '$2 == f || $2 == "*"f {print $1}')
            echo "         just $JUST_VERSION sha256: $got  (pin it as JUST_SHA256)"
        fi
        if [ -n "$want" ] && [ "$got" = "$want" ]; then
            # A && B || C is what is meant: either step failing is the same refusal.
            # shellcheck disable=SC2015
            tar -xzf "$tmp/$tarball" -C "$tmp" just \
                && sudo install -m 0755 "$tmp/just" /usr/local/bin/just \
                && verdict ok "just" "$(just --version), from the pinned release" \
                || verdict FAIL "just" "unpacked but could not install to /usr/local/bin"
        else
            verdict FAIL "just" "checksum mismatch or no published sum — nothing installed"
        fi
    else
        verdict FAIL "just" "could not download $tarball"
    fi
    rm -rf "$tmp"
fi


# --- the deploy account ---
# No sudo, docker group, and this user's own authorized_keys copied over so the
# key already reaching this box reaches that account too. A deploy from CI later
# adds its key here and needs nothing else.

step "the deploy account"

if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    verdict ok "account" "$DEPLOY_USER exists"
else
    if sudo useradd -m -s /bin/bash "$DEPLOY_USER"; then
        verdict ok "account" "$DEPLOY_USER created, no password set — key only"
    else
        verdict FAIL "account" "could not create $DEPLOY_USER"
    fi
fi

deploy_home=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)

if [ -n "$deploy_home" ]; then
    sudo usermod -aG docker "$DEPLOY_USER" >/dev/null 2>&1
    if id -nG "$DEPLOY_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        verdict ok "docker group" "$DEPLOY_USER is in it — root-equivalent, by design and not by accident"
    else
        verdict FAIL "docker group" "$DEPLOY_USER is not in it; nothing it runs can reach the daemon"
    fi

    # Probed, not assumed: an account that silently kept sudo is the whole point
    # of this split failing with no symptom.
    if as_deploy sudo -n true >/dev/null 2>&1; then
        verdict FAIL "no sudo" "$DEPLOY_USER CAN sudo — check /etc/sudoers.d and its groups"
    else
        verdict ok "no sudo" "$DEPLOY_USER cannot sudo"
    fi

    if [ -s "$HOME/.ssh/authorized_keys" ]; then
        sudo install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$deploy_home/.ssh"
        sudo install -m 0600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" \
            "$HOME/.ssh/authorized_keys" "$deploy_home/.ssh/authorized_keys"
        verdict ok "authorized keys" "$(wc -l < "$HOME/.ssh/authorized_keys") copied from $USER"
    else
        verdict LOOK "authorized keys" "$USER has none to copy — put your public key in $deploy_home/.ssh/authorized_keys by hand"
    fi
fi


# --- node, for `claude login`, as the deploy account ---
# The budget guard is python reading ~/.claude/.credentials.json and nothing on
# the host calls the claude binary. It is here because only the interactive
# `claude login` creates that file with the scope the usage endpoint wants — and
# it has to be THAT account's file, because that is the one cron runs as.

step "claude code, for the login"

if ! command -v node >/dev/null 2>&1; then
    printf '         installing nodejs and npm\n'
    slow sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
fi

node_major=$(node --version 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)
if [ -n "$node_major" ] && [ "$node_major" -ge 18 ]; then
    verdict ok "node" "$(node --version)"
else
    verdict FAIL "node" "${node_major:-absent} — Claude Code needs 18 or newer; install from nodesource"
fi

if [ -n "$node_major" ] && [ "$node_major" -ge 18 ] && [ -n "$deploy_home" ]; then
    # A prefix under that home, so a global install needs no root — the shape
    # image/Dockerfile gives the agent. The heredoc delimiter is quoted and the
    # sh string single-quoted so $HOME reaches .profile unexpanded, and the line
    # holds if the home ever moves.
    # shellcheck disable=SC2016
    as_deploy bash -lc 'mkdir -p "$HOME/.npm-global"
        grep -qs NPM_CONFIG_PREFIX "$HOME/.profile" || cat >> "$HOME/.profile"' <<'PROFILE'

export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"
PROFILE

    if as_deploy bash -lc 'command -v claude' >/dev/null 2>&1 \
       || { printf '         installing claude code for %s\n' "$DEPLOY_USER"
            slow as_deploy bash -lc 'npm install -g @anthropic-ai/claude-code'; }; then
        verdict ok "claude cli" "$(as_deploy bash -lc 'claude --version' 2>/dev/null || echo installed) — 'claude login' is a checklist step, not this script's"
    else
        verdict FAIL "claude cli" "npm install failed; the budget guard has no credential to read without it"
    fi
fi


# --- what the deploy account actually sees ---
# host/verify/host-tools.sh is the real list and it runs after the clone. This
# asks it AS THE DEPLOY USER, because a tool on root's PATH and not on that
# account's is exactly the failure a check run here would miss.

step "the tools, as $DEPLOY_USER"

for t in docker git jq python3 flock crontab gh; do
    if where=$(as_deploy bash -lc "command -v $t" 2>/dev/null) && [ -n "$where" ]; then
        verdict ok "$t" "$where"
    else
        verdict FAIL "$t" "absent, or not on $DEPLOY_USER's PATH"
    fi
done

if as_deploy docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    verdict ok "daemon reachable" "$DEPLOY_USER can talk to docker"
else
    verdict FAIL "daemon reachable" "$DEPLOY_USER cannot reach the socket — the group needs a fresh login, or the daemon is down"
fi

py=$(as_deploy bash -lc 'python3 --version' 2>/dev/null | awk '{print $2}')
if [ "$(printf '3.14\n%s\n' "$py" | sort -V | head -1)" = "3.14" ]; then
    verdict ok "python" "$py — what CI proves the host scripts on"
else
    verdict LOOK "python" "${py:-unknown} — CI proves the host scripts on 3.14 only; a failure here would be loud, not silent"
fi


# --- the summary ---

printf '\n== summary ==\n'
printf '  %d ok, %d to look at, %d failed\n' "$ok" "$look" "$fail"
[ -n "$look_lines" ] && printf '\n%s' "$look_lines"
[ -n "$fail_lines" ] && printf '\n%s' "$fail_lines"

if [ "$fail" -gt 0 ]; then
    printf '\nProvisioning is not finished. Fix the FAIL lines and run this again.\n'
    exit 1
fi
printf '\nInstalled. Everything from here on is done as %s — README.md beside this script is the rest.\n' "$DEPLOY_USER"
