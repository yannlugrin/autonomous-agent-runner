# shellcheck shell=bash
# The commit the running image was built from, against this checkout's HEAD.
#
# Sourced by host/verify/verify.sh, whose working directory is the checkout — so
# `git rev-parse` here answers for the tree this justfile belongs to.

echo
echo "== runner commit built into the image =="


# --- image commit ---
# What the image says it was built from. The value travels host -> compose
# build arg -> Dockerfile ARG -> ENV, and every joint fails the same silent
# way: an empty string, which reaches a session as a sentence saying the image
# does not say. Nothing else consults it, so nothing else would notice.
#
# Read through `--entrypoint sh` under the baked name, as the version probe in
# claude-code.sh does: entrypoint.sh is what renames it into the agent's
# namespace, and --entrypoint is what skips entrypoint.sh.
#
# A difference is not a defect — this proves the image that was last built, and
# committing since legitimately leaves it naming an older commit — so a
# mismatch is LOOK and only an absent value fails. see docs/verify.md#image-commit

head=$(git rev-parse --short HEAD 2>/dev/null || true)
read -r built at <<<"$(docker compose run --rm -T --entrypoint sh agent -c '
    printf "%s %s\n" "${AGENT_RUNNER_COMMIT:-unset}" "${AGENT_RUNNER_COMMITTED_AT:-unset}"' 2>/dev/null | tail -1)"

printf '         %-22s %s\n' "built into the image:" "${built:-UNREADABLE}"
printf '         %-22s %s\n' "committed:" "${at:-UNREADABLE}"
printf '         %-22s %s\n' "this checkout's HEAD:" "${head:-UNREADABLE}"

if [ -z "$head" ]; then
    verdict FAIL "image commit" "UNREADABLE — this checkout has no HEAD to compare against"
elif [ "$built" = unset ] || [ -z "$built" ]; then
    verdict FAIL "image commit" "THE IMAGE DOES NOT SAY — it predates this label, or was built by something other than 'just build'. A session is then told nothing about which version it runs. 'just verify --build'."
elif [ "$at" = unset ] || [ -z "$at" ]; then
    verdict FAIL "image commit" "HALF AN ANSWER — the image names $built but no date. One build argument arrived and the other did not, which is the wiring failing quietly."
elif [ "$built" = "$head" ]; then
    verdict ok "image commit" "built from $built, committed $at, which is this checkout's HEAD"
else
    verdict LOOK "image commit" "the image was built from $built and this checkout is at $head — what was last built is not what is committed now. 'just verify --build' makes them the same."
fi
