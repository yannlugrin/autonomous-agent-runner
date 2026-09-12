# shellcheck shell=bash
# The vault entries that are not credentials, appended to a secrets stream.
#
# Sourced by read-volume.sh and read-archive.sh, the two stages that build the
# stream needles.py reads. From the same list the guard reads —
# `image/config/vault-exempt.txt`, one file for two readers that cannot see each
# other — and on the same stream as the secrets, so no reader can be given the
# secrets and not the exemptions.
# see docs/vault.md
#
# Blanks and comments out, and anything with a space in it out with them — a
# vault key has none, and a note someone forgot to comment would otherwise
# become an exemption. An absent or unreadable list exempts nothing.

with_exemptions() {
    printf '%s\n=== exempt\n%s\n' "$1" \
        "$(awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                  if ($0 != "" && $0 !~ /[[:space:]]/) print }' \
            image/config/vault-exempt.txt 2>/dev/null || true)"
}
