# shellcheck shell=bash
# Mechanical checks — everything that can be proved without a Claude session:
# host-side files, the classifier rules, compose's own resolution, and what the
# image says when a container is asked directly. Sourced by
# host/verify/verify.sh, after the docker daemon has been found.

echo "== mechanical checks =="


# --- auto-mode ---
# The classifier rules, host-side and offline: managed settings, AUTO-MODE.md
# and auto-mode/decisions.py agree, and the environment array still carries all
# 20 slots — the array is a full replacement, so a slot nobody wrote is simply
# gone. What no check reaches is a source that says something nobody meant,
# which is what reading AUTO-MODE.md is for.
# see docs/verify.md#the-classifier-rules

if out=$(host/release/check-auto-mode.py 2>&1); then
    verdict ok "auto-mode" "${out#auto-mode: }"
else
    verdict FAIL "auto-mode" "${out:-check-auto-mode.py could not run}"
fi


# --- compose image ---
# compose.yaml carries the deployed tag as its `image:` default — the one copy
# of that name outside the justfile, because compose cannot read a just
# variable. Read with the variable unset, so the fallback itself is compared.
# see docs/verify.md#compose-resolves-only-through-just

compose_default=$(env -u RUNNER_IMAGE docker compose config --format json 2>/dev/null \
    | jq -r '.services.agent.image // empty' 2>/dev/null)
if [ "$compose_default" = "$RUNNER_IMAGE_DEPLOYED" ]; then
    verdict ok "compose image" "runs $RUNNER_IMAGE_DEPLOYED by default, as the justfile names it"
else
    verdict FAIL "compose image" "MISMATCH — compose defaults to '${compose_default:-(unreadable)}', the justfile names '$RUNNER_IMAGE_DEPLOYED'; only one is what cron runs"
fi


# --- compose alone ---
# That compose refuses to guess which agent it is. It derives the whole chain —
# home, checkout, volume, image tag — from AGENT_USER and requires it, because
# a default would make a `docker compose` typed by hand address an empty volume
# beside the real one, create it, and say nothing. Read with this file's own
# exports stripped, which is exactly what such a command would carry.

if env -u AGENT_USER -u AGENT_HOME -u AGENT_REPO_DIR -u AGENT_VOLUME \
       -u RUNNER_IMAGE -u COMPOSE_PROJECT_NAME \
   docker compose config -q >/dev/null 2>&1
then
    verdict FAIL "compose alone" "RESOLVES WITHOUT AGENT_USER — a bare 'docker compose' is addressing some other agent's world, silently"
else
    verdict ok "compose alone" "refuses without AGENT_USER, so only 'just' decides which agent this is"
fi


# --- test twin ---
# `just test-container` runs the same image with the same credentials, and the
# one thing that makes it safe to wipe a home inside it is that the home is not
# the agent's. A twin holding the volume would look exactly right while
# destroying the thing recovery exists for.
# see docs/verify.md#the-test-twin-has-no-volume

if docker compose config --format json \
    | python3 -c 'import json,sys; sys.exit(0 if not json.load(sys.stdin)["services"]["agent-test"].get("volumes") else 1)' 2>/dev/null
then verdict ok "test twin" "no volume — a rehearsal cannot reach the agent's home"
else verdict FAIL "test twin" "HAS A VOLUME — it can reach the agent's home"; fi


# --- tools rule ---
# The tools rule still matches the checkout. The build substitutes the checkout
# path into a placeholder, so this is the one permission rule written by a build
# rather than typed — and a rule naming a path nothing is at denies nothing and
# allows nothing, so every `python3 tools/x.py` waits for a human who is not
# coming. Asked of the image and of the container's own environment at once.
# see docs/verify.md#the-rendered-tools-rule

out=$(docker compose run --rm -T --entrypoint python3 agent -c 'import json,os,getpass; a=json.load(open("/etc/claude-code/managed-settings.json"))["permissions"]["allow"]; d=os.environ.get(getpass.getuser().upper().replace("-","_")+"_REPO_DIR","(unset)"); w="Bash(python3 %s/tools/*)"%d; print("rendered rule matches the running checkout: "+w if w in a else "MISMATCH — the image allows "+repr([x for x in a if x.startswith("Bash(python3 /")])+" and the checkout is "+d)' 2>/dev/null | tr -d '\r')
case "$out" in
    "rendered rule matches"*) verdict ok   "tools rule" "$out" ;;
    MISMATCH*)                verdict FAIL "tools rule" "$out" ;;
    *)                        verdict FAIL "tools rule" "UNREADABLE — could not read the rule out of the image" ;;
esac


# --- agent settings ---
# That the agent has not granted itself anything. `status` runs the same script
# with `|| true`, which is right for a status line and wrong for a proof — here
# its answer becomes a verdict. 0 clean, 1 a permissions block was found, 2 the
# container did not answer; both non-zero are FAIL.
# see docs/verify.md#the-agent-has-granted-itself-nothing

out=$(host/release/check-agent-settings.sh 2>&1); rc=$?
detail=$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g')
case $rc in
    0) verdict ok   "agent settings" "no permissions block in any file the agent can write" ;;
    1) verdict FAIL "agent settings" "$detail" ;;
    *) verdict FAIL "agent settings" "${detail:-could not be read}" ;;
esac


# --- env duplicates ---
# A name assigned twice in .env has no symptom: both readers take the last
# assignment — `just` under dotenv-load, and compose — so an earlier line is
# silently overridden and the file goes on saying something that is not in
# force. Reading only the keys, since this file holds the vault token and the
# report is printed. see docs/verify.md#env-names-nothing-twice

if [ ! -f .env ]; then
    verdict LOOK "env duplicates" "no .env on this host — nothing is configured, so nothing could be shadowed"
else
    dupes=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' .env | sed 's/=$//' | sort | uniq -d | tr '\n' ' ')
    if [ -z "$dupes" ]; then verdict ok "env duplicates" "none — every name is assigned once"
    else verdict FAIL "env duplicates" "SHADOWED — the last assignment wins, so these say nothing: $dupes"; fi
fi


# --- this installation's own files ---
# The three under image/ travel by copy and not by git: `just deploy` puts them
# in the deployed checkout, the build bakes two of them in and renders the third
# into the classifier's community slot. A checkout whose copy has moved on from
# the image's is a rule that is written down and not in force — every edit here
# needs a build, and the file reads exactly the same either way.
#
# Named from host/lib/config-files.sh, the same list the recipes use, so a
# fourth file cannot be added to them and not to this.
# see docs/verify.md#the-per-installation-files

# shellcheck source=SCRIPTDIR/../lib/config-files.sh
. host/lib/config-files.sh

# The names are prefixed because the sections share one shell: verify.sh's own
# `want` holds the model every section below compares against.
for cfg_name in "${CONFIG_FILES[@]}"; do
    cfg_label="${cfg_name%.txt}"
    if [ ! -e "image/config/$cfg_name" ]; then
        verdict FAIL "$cfg_label" "ABSENT FROM THIS CHECKOUT — 'just setup' makes it from its example, and 'just build' refuses without it"
        continue
    fi

    # The community sentence is not baked as a file: it is substituted into the
    # autoMode block, so what is asked of the image is the rendered slot. The
    # collapse is spelled here as well as in the build, and the two disagreeing
    # is what this reports — loudly, which is the difference that matters.
    if [ "$cfg_name" = community.txt ]; then
        cfg_want=$(python3 -c '
import pathlib
lines = [l for l in pathlib.Path("image/config/community.txt").read_text().splitlines()
         if not l.lstrip().startswith("#")]
print(" ".join(" ".join(lines).split()) or "none")')
        if cfg_got=$(docker compose run --rm -T --entrypoint python3 agent -c '
import json
block = json.load(open("/etc/claude-code/managed-settings.json"))["autoMode"]["environment"]
said = [x for x in block if "**Its community**:" in x][0]
told = said.split("**Its community**:", 1)[1].strip()
print(told[:-1] if told.endswith(".") else told)' 2>/dev/null | tr -d '\r')
        then
            if [ "$cfg_got" = "$cfg_want" ]; then
                verdict ok "$cfg_label" "the classifier is told: $cfg_got — which is what the file says"
            else
                verdict FAIL "$cfg_label" "THE IMAGE TELLS THE CLASSIFIER: $cfg_got — AND THE FILE SAYS: $cfg_want. The rendered sentence is the one in force"
            fi
        else
            verdict FAIL "$cfg_label" "THE COMMUNITY SLOT COULD NOT BE READ OUT OF THE IMAGE — what the classifier is told is unproved"
        fi
        continue
    fi

    if cfg_got=$(docker compose run --rm -T --entrypoint cat agent "/etc/agent/$cfg_name" 2>/dev/null | tr -d '\r'); then
        if [ "$cfg_got" = "$(cat "image/config/$cfg_name")" ]; then
            verdict ok "$cfg_label" "the image holds this checkout's copy, line for line"
        else
            verdict FAIL "$cfg_label" "THE IMAGE'S COPY IS NOT THIS CHECKOUT'S — it was edited after the build, and the image's older copy is what is in force"
        fi
    else
        verdict FAIL "$cfg_label" "COULD NOT BE READ OUT OF THE IMAGE — nothing is proved about what the guard reads"
    fi
done


# --- key shape ---
# The three readers of "is this a private key" must answer alike, and two of
# them fail silently when they do not: gitleaks ignores a config option it
# predates without a word, and panics on a malformed rule — which `--exit-code
# 1` reports as a finding, so a crash and a leak are the same number. Asked of
# the gitleaks actually installed, on both halves of the rule.
#
# Host-side and offline; the "key" is armour with 48 characters of base64
# behind it and is not one. see docs/verify.md#key-shape

if ! command -v gitleaks >/dev/null 2>&1; then
    verdict LOOK "key shape" "gitleaks absent — the pattern floor in collect runs alone"
else
    probe=$(mktemp -d)
    B='-----BEGIN '
    printf '%sPRIVATE KEY-----\n-----END PRIVATE KEY-----\n' "$B" > "$probe/pair.txt"
    printf '%sRSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy\n' "$B" > "$probe/key.txt"
    pair_gl=$(gitleaks detect --config host/archive/gitleaks.toml --source "$probe" --no-git \
                --redact --exit-code 1 >/dev/null 2>&1; echo $?)
    rm -f "$probe/key.txt"
    only_pair=$(gitleaks detect --config host/archive/gitleaks.toml --source "$probe" --no-git \
                --redact --exit-code 1 >/dev/null 2>&1; echo $?)
    rm -rf "$probe"
    # armour alone must be 0; armour plus a body must be exactly 1 —
    # anything above 1 is gitleaks failing to run, never "found nothing".

    if [ "$only_pair" = 0 ] && [ "$pair_gl" = 1 ]; then
        verdict ok "key shape" "armour alone passes, a body is caught"
    elif [ "$only_pair" != 0 ] && [ "$only_pair" -le 1 ]; then
        verdict FAIL "key shape" "GITLEAKS STILL FLAGS BARE ARMOUR — host/archive/gitleaks.toml is not in force"
    else
        verdict FAIL "key shape" "GITLEAKS COULD NOT RUN (armour $only_pair, key $pair_gl) — a crash reads as a finding"
    fi
fi


# --- hex values ---
# The hex allowlist, both halves. host/archive/gitleaks.toml stops
# `generic-api-key` firing on values that are nothing but hex, and an allowlist
# fails the two silent ways an anchored rule does: dead, since gitleaks says
# nothing about a config key it does not know, or too wide, and a real key
# bound to a keyword walks through the second opinion in silence.
#
# So both are asked of the gitleaks actually installed: a chain value must
# pass, and a mixed-alphabet secret beside it must still be caught. The
# "secret" is keyboard noise. see docs/verify.md#hex-values

if ! command -v gitleaks >/dev/null 2>&1; then
    verdict LOOK "hex values" "gitleaks absent — nothing to allowlist"
else
    probe=$(mktemp -d)
    printf "token: '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913'\n" > "$probe/chain.txt"  # gitleaks:allow — a fixture, not a secret
    hex_only=$(gitleaks detect --config host/archive/gitleaks.toml --source "$probe" --no-git \
                --redact --exit-code 1 >/dev/null 2>&1; echo $?)
    printf 'api_secret = "zq7Xf2Kd91LmPw04Rt83Yb56Nh21Vc9jGs4A"\n' > "$probe/mixed.txt"  # gitleaks:allow — a fixture, not a secret
    with_key=$(gitleaks detect --config host/archive/gitleaks.toml --source "$probe" --no-git \
                --redact --exit-code 1 >/dev/null 2>&1; echo $?)
    rm -rf "$probe"

    if [ "$hex_only" = 0 ] && [ "$with_key" = 1 ]; then
        verdict ok "hex values" "a hex value passes, a keyword-bound secret is caught"
    elif [ "$hex_only" != 0 ] && [ "$hex_only" -le 1 ]; then
        verdict FAIL "hex values" "GITLEAKS STILL FLAGS PLAIN HEX — the allowlist is not in force, and every chain-data session will be held for a review nobody can rule on"
    elif [ "$with_key" = 0 ]; then
        verdict FAIL "hex values" "THE ALLOWLIST SWALLOWS A REAL SECRET — it is too wide; gitleaks is now decoration"
    else
        verdict FAIL "hex values" "GITLEAKS COULD NOT RUN (hex $hex_only, secret $with_key) — a crash reads as a finding"
    fi
fi


# --- the floor these two probes ask ---
# `host/archive/floor.sh` builds what `just collect` runs over every transcript:
# the shapes true of every installation, plus whatever `image/config/secret-shapes.txt`
# adds for this one. Sourced rather than retyped — a copy of the floor written
# into a probe is the copy that goes stale while still passing.

# shellcheck source=SCRIPTDIR/../archive/floor.sh
. host/archive/floor.sh


# --- feed token ---
# The Reddit feed token has no shape of its own, so the rule for it anchors on
# the query parameter — and a rule anchored that way is wrong two ways that both
# look like working: stop matching the tokenised URL and the token reaches the
# archive in clear; start matching the bare feed URL and every transcript
# mentioning it is held. Both halves are asked.
#
# The rule is this installation's own and may simply not be here, which is a
# state and not a defect. What tells that apart from a rule that has stopped
# catching is whether the floor carries the anchor at all — so the anchor is
# named here and the rule is not.
# see docs/verify.md#feed-token

tokened='https://www.reddit.com/user/someone/.rss?user=someone&feed=0123456789abcdef'
bare='reads https://www.reddit.com/r/example/new/.rss — the feed, no token in it'
if [ -z "$patterns" ]; then
    verdict FAIL "feed token" "THE FLOOR CAME OUT EMPTY — nothing is proved about what a collection would catch"
elif ! printf '%s' "$patterns" | grep -q 'feed='; then
    verdict LOOK "feed token" "not configured here — image/config/secret-shapes.txt carries no feed-token shape, so a tokenised feed URL reaches the archive in clear"
elif ! printf '%s\n' "$tokened" | grep -qE "$patterns"; then
    verdict FAIL "feed token" "A TOKENISED FEED URL PASSES THE FLOOR — it would reach the archive in clear"
elif printf '%s\n' "$bare" | grep -qE "$patterns"; then
    verdict FAIL "feed token" "THE FLOOR FIRES ON AN UNTOKENISED FEED URL — every mention would be held"
else
    verdict ok "feed token" "tokenised URL caught, plain feed URL passes"
fi


# --- webhook token ---
# A webhook URL is the secret, and the one class the verbatim layer cannot see:
# the token never touches the volume, so there is nothing to compare against and
# only a shape can catch it.
#
# The same three answers as the feed rule above and for the same reasons, plus
# the legacy discordapp.com host, which still works and still carries the token.
# see docs/verify.md#webhook-token

hooked='"config":{"url":"https://discord.com/api/webhooks/1540000000000000000/abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"}'
legacy='https://discordapp.com/api/webhooks/1540000000000000000/abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'

# The endpoint written down without a secret behind it — what a rule widened
# off the token would fire on, and what the agent writes while working. Not a
# docs link: that has no /api/webhooks in it and would pass any spelling.

plain='POST https://discord.com/api/webhooks to create one; the id and token come back in the response'
if [ -z "$patterns" ]; then
    verdict FAIL "webhook token" "THE FLOOR CAME OUT EMPTY — nothing is proved about what a collection would catch"
elif ! printf '%s' "$patterns" | grep -q '/api/webhooks/'; then
    verdict LOOK "webhook token" "not configured here — image/config/secret-shapes.txt carries no webhook shape, so a hook URL reaches the archive in clear"
elif ! printf '%s\n' "$hooked" | grep -qE "$patterns"; then
    verdict FAIL "webhook token" "A WEBHOOK URL PASSES THE FLOOR — a hook secret would reach the archive in clear"
elif ! printf '%s\n' "$legacy" | grep -qE "$patterns"; then
    verdict FAIL "webhook token" "THE LEGACY discordapp.com HOST PASSES — it still works and still carries the token"
elif printf '%s\n' "$plain" | grep -qE "$patterns"; then
    verdict FAIL "webhook token" "THE FLOOR FIRES ON THE BARE ENDPOINT — every mention of making a hook would be held"
else
    verdict ok "webhook token" "tokenised hook URL caught on both hosts, the bare endpoint passes"
fi


# --- archive skip ---
# The skip in `just collect` rests on one number agreeing with git's: a staged
# transcript is passed over only when its bytes hash to the object the archive
# already holds. A pruner computing something slightly different would drop
# transcripts nothing had ever read, and the count it prints would look exactly
# as right as it does now — so the number is asked of git and of archived.py
# over the same bytes, with ls-tree's own shape typed out by hand. The empty
# listing is the second half: an unreadable archive is not "it is all in there
# already". see docs/verify.md#the-archive-skip

skipprobe="$(mktemp -d)/$AGENT_PROJECT_DIR"
mkdir -p "$skipprobe"

# A timestamp, because the layout files a transcript by the day it happened
# and one without lands in `undated/` — a path this would prove nothing about.

stamp='{"timestamp":"2026-08-26T10:00:00.000Z","type":"user"}'
printf '%s\n' "$stamp" > "$skipprobe/a.jsonl"
printf '%s\nchanged\n' "$stamp" > "$skipprobe/b.jsonl"
printf '%s\nredacted\n' "$stamp" > "$skipprobe/c.jsonl"
printf '%s\nredacted\n' "$stamp" > "$skipprobe/d.jsonl"

# The two scripts asked together, because what fails silently is them
# disagreeing about a path: a listing spelled by hand here would pass on a
# pair that could never match in the real one.

root="${skipprobe%/*}"
python3 host/archive/archive-layout.py "$root" > "$root/map"
at() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$root/map"; }

# c and d carry the same ruling and identical bytes; only c is in the listing.
# A rewrite that never reached the archive must not settle, or the transcript
# vanishes unread — and a rulings map keyed on the hash would keep one of them
# and drop the other's ruling.

printf '%s\t%s\n%s\t%s\n' \
    "$AGENT_PROJECT_DIR/c.jsonl" "$(sha256sum "$skipprobe/c.jsonl" | cut -d' ' -f1)" \
    "$AGENT_PROJECT_DIR/d.jsonl" "$(sha256sum "$skipprobe/d.jsonl" | cut -d' ' -f1)" > "$root/rulings"
zero=0000000000000000000000000000000000000000
skipped=$(printf '%s\ttranscripts/%s\n%s\ttranscripts/%s\n%s\ttranscripts/%s\n' \
              "$(git hash-object "$skipprobe/a.jsonl")" "$(at "$AGENT_PROJECT_DIR/a.jsonl")" \
              "$zero" "$(at "$AGENT_PROJECT_DIR/b.jsonl")" \
              "$zero" "$(at "$AGENT_PROJECT_DIR/c.jsonl")" \
          | python3 host/archive/archived.py "$root" "$root/map" "$root/rulings" \
          | sed 's|.*/||' | sort | tr '\n' ' ')
none=$(: | python3 host/archive/archived.py "$root" "$root/map" "$root/rulings")
day=$(at "$AGENT_PROJECT_DIR/a.jsonl")
rm -rf "$root"

if [ "$skipped" = "a.jsonl c.jsonl " ] && [ -z "$none" ] && [ "$day" = "2026/08-26/a.jsonl" ]; then
    verdict ok "archive skip" "layout dates the file, git's object id and a ruling settle it, nothing else does"
else
    verdict FAIL "archive skip" "WRONG ('$skipped', empty listing '$none', layout '$day') — collect would drop unread transcripts"
fi


# --- public winnow ---
# The public-half winnow, asked in both directions because only one of them is
# loud. A winnow one step too wide drops all the needles and the ssh comparison
# then compares nothing, with no symptom whatever — that is the direction this
# exists for; a winnow never reached puts the published key back among the
# needles, which is loud but spends a ruling on every session that prints it.
#
# Asked of the real needler, which runs its own probe end to end on a synthetic
# key and prints the verdict, so `just collect` and this line cannot be reading
# two different winnows. see docs/verify.md#the-public-winnow

winnow=$(python3 host/archive/needles.py --selftest 2>/dev/null)
verdicts_from <<< "${winnow:-FAIL|public winnow|needles.py --selftest PRINTED NOTHING — it could not run, and the winnow is unproved}"


# --- session login ---
verdicts_from < <(docker compose run --rm -T --entrypoint /usr/local/bin/vault-env agent sh -c '
    # Which login the session will run on — not the budget guard, which reads
    # usage, needs the user:profile scope, and runs on the host against a login
    # that has one. No network: presence, not validity.
    #
    # LOOK and not ok: both shapes work and they fail differently, so which one
    # is in force is the whole content of this line, and only the operator can
    # say whether it is the one they meant today.
    # see docs/verify.md#which-login-a-session-runs-on

    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        echo "LOOK|session login|a session here runs on the vault setup-token — inference only, so it cannot read usage, and it does not expire from disuse"
    elif [ -s "$HOME/.claude/.credentials.json" ]; then
        echo "LOOK|session login|a session here runs on the credentials file in the volume — its refresh token expires on a wall clock even while the machine is off"
    else
        echo "FAIL|session login|NEITHER a vault token nor a credentials file — no session can run"
    fi')


# --- ssh policy, guard decides, backup asks, guard secrets ---
verdicts_from < <(docker compose run --rm -T --entrypoint sh agent -c '
    # No apostrophes in this block: it is the body of a sh -c "..." in a
    # single-quoted string, and one closes the quote, which surfaces as an
    # unbalanced paren hundreds of lines further down.


    # --- ssh policy ---
    # The policy value itself, not the line ssh printed: a grep that finds
    # something passes on any setting at all. see docs/verify.md#ssh-policy

    pol=$(ssh -G github.com 2>/dev/null | grep -i "^stricthostkeychecking " | cut -d" " -f2)
    case "$pol" in
        accept-new) echo "ok|ssh policy|accept-new — a first key is trusted, a changed one is refused" ;;
        "")         echo "FAIL|ssh policy|NOT APPLIED — ssh reports no stricthostkeychecking at all" ;;
        *)          echo "FAIL|ssh policy|is $pol, not accept-new" ;;
    esac


    # --- guard decides ---
    # The subject must be an argv rule. `bws` is an argv verdict with no
    # content path behind it, so a `deny` here can only come from the layer
    # this line is named for; a subject the content layer would also refuse
    # prints `deny` either way. see docs/verify.md#guard-reached

    echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"env BWS_PROBE=1 bws --help\"}}" \
        | /usr/local/bin/bash-guard.py 2>/dev/null \
        | grep -q "\"permissionDecision\": \"deny\"" \
        && echo "ok|guard decides|denies bws behind an env wrapper, which only argv parsing can see" \
        || echo "FAIL|guard decides|DID NOT DENY — the argv layer is not deciding"


    # --- backup asks ---
    # The backup hook is the path everything takes to origin, and it asks the
    # guard before pushing. If it stopped asking, nothing would say so — the
    # pushes would simply succeed. So a throwaway repository with a token shape
    # in an unpushed commit, and the hook must decline and say why. A fake
    # shape, never a real credential — a probe that staged one would be doing
    # the thing the check exists to stop. see docs/verify.md#backup-asks

    rm -rf /tmp/vb && mkdir -p /tmp/vb/rem /tmp/vb/w \
        && git init -q --bare /tmp/vb/rem && cd /tmp/vb/w \
        && git init -q . && git config user.email v@v && git config user.name v \
        && echo base > a.md && git add a.md && git commit -qm first \
        && git remote add origin file:///tmp/vb/rem \
        && printf "ghp_A1b2C3d4E5f6G7h8I9j0K1l2m3\n" > t.txt && git add t.txt \
        && git commit -qm second

    # The name the hook actually reads, derived the way the hook derives it —
    # `id -un`, upper-cased, dashes to underscores — and not written out.
    # AGENT_REPO_DIR is the runner-side plumbing name the build arg travels
    # under; the hook reads ${AGENT_PREFIX}_REPO_DIR. Derived rather than
    # spelled, so the day the two ways of naming the agent part company this
    # fails instead of lying.

    env "$(id -un | tr a-z A-Z | tr - _)_REPO_DIR=/tmp/vb/w" \
        /usr/local/bin/push-on-exit.sh >/dev/null 2>&1
    if grep -q "^reason: refused-by-guard" /tmp/vb/w/ERROR_ON_PUSH 2>/dev/null; then
        echo "ok|backup asks|refused a token-carrying commit, so it is still consulting the guard"
    else
        echo "FAIL|backup asks|DID NOT REFUSE — the backup is not consulting the guard"
    fi


    # --- guard secrets ---
    # The argv layer and the content layer fail independently: the checks above
    # prove the guard decides on a command, this one proves it reads what a
    # commit would carry. see docs/verify.md#guard-secrets

    rm -rf /tmp/vp && mkdir -p /tmp/vp && cd /tmp/vp \
        && git init -q . && git config user.email v@v && git config user.name v \
        && printf "ghp_A1b2C3d4E5f6G7h8I9j0K1l2m3\n" > t.txt && git add t.txt
    echo "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp/vp\",\"tool_input\":{\"command\":\"git commit -m x\"}}" \
        | /usr/local/bin/bash-guard.py 2>/dev/null \
        | grep -q "\"permissionDecision\": \"deny\"" \
        && echo "ok|guard secrets|denies a commit carrying a token shape, so it reads what a commit would carry" \
        || echo "FAIL|guard secrets|DID NOT DENY — the content layer is not reading staged changes"
')


# --- how a run ended ---
# The verdict a stopped run produces, against fixtures, because no probe can
# make a session stop. It runs on the host with RUNNER_LAST_RUN pointed at a
# scratch file, so nothing here touches the real record.
#
# Every branch of this is silent when it is wrong. A verdict of `clean` for a
# stop is a recovery that never happens and a session that never notices; one
# of `stopped` for a clean end is a recovery message on every ordinary session.
# The envelope's field names are the part that moves under an upgrade, and the
# api_error case is the one that catches it: `subtype` reads "success" on a run
# that failed — measured 2026-09-04 on 2.1.260 — so a check keyed on the
# obvious field would pass here and be wrong in production.
# see docs/verify.md#run-record

wrong=$(
    scratch=$(mktemp -d)
    (
        export RUNNER_LAST_RUN="$scratch/last-run"
        # shellcheck source=SCRIPTDIR/../lib/run-record.sh
        . host/lib/run-record.sh
        say() { printf '%s; ' "$1"; }

        [ "$(run_record_verdict no)" = none ] || say "no record does not read as none"

        run_record_open probe-container
        [ "$(run_record_verdict no)" = "stopped killed" ] || say "an open record is not a stop"
        [ "$(run_record_verdict yes)" = running ] || say "an open record is a stop while a session runs"

        printf '{"type":"result","subtype":"success","is_error":false,"terminal_reason":"completed"}\n' > "$scratch/ok"
        run_record_close 0 "$scratch/ok"
        [ "$(run_record_verdict no)" = clean ] || say "a completed run is not clean"

        run_record_open probe-container
        printf '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":401}\n' > "$scratch/bad"
        run_record_close 1 "$scratch/bad"
        [ "$(run_record_verdict no)" = "stopped api_error" ] || say "an api_error run is not a stop"
        [ "$(run_record_field api_error_status)" = 401 ] || say "the api status is not kept"

        run_record_open probe-container
        printf 'not json at all\n' > "$scratch/junk"
        run_record_close 2 "$scratch/junk"
        [ "$(run_record_verdict no)" = "stopped none" ] || say "junk does not fail toward recovery"
    )
    rm -rf "$scratch"
)

if [ -z "$wrong" ]; then
    verdict ok "run record" "a stop, a clean end, a killed run and junk each read as themselves"
else
    verdict FAIL "run record" "WRONG VERDICT — ${wrong%; }"
fi


# --- what a recovery start would say ---
# The projection over this volume's newest transcript. Not a fixture, because
# what fails here is a transcript shape that moved under an upgrade and only
# the real corpus carries those. A first message that grew to hundreds of
# kilobytes is not an error anywhere: it is paid for once per recovery, in
# silence. The ceiling here is twice the projection's own, so this fails when
# the cap has stopped working rather than whenever a session was talkative.
# see docs/verify.md#recovery-size

if projected=$(host/session/session-recovery.py --since 0 --reason api_error 2>&1); then
    projected_bytes=$(printf '%s' "$projected" | wc -c)
    if [ "$projected_bytes" -eq 0 ]; then
        verdict FAIL "recovery size" "EMPTY — a stopped session would be announced with nothing after it"
    elif [ "$projected_bytes" -gt 8192 ]; then
        verdict FAIL "recovery size" "$projected_bytes bytes — past its own ceiling, so the cap is not holding"
    else
        verdict ok "recovery size" "$projected_bytes bytes from the newest transcript in the volume"
    fi
else
    verdict LOOK "recovery size" "could not project from the volume — ${projected%%$'\n'*}"
fi


echo
