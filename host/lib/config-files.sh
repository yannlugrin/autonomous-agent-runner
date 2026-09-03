# shellcheck shell=bash
# shellcheck disable=SC2034  # CONFIG_FILES is read by whoever sources this.
#
# The per-installation files, derived from their committed examples.
#
# Each holds what is this installation's and not this repository's, each is
# untracked, and each has a committed `<name>.example.txt` beside it — and the
# examples are the list: they are tracked, so the set is known from a bare
# checkout, and an absent `<name>.txt` is one that has an example and no file.
# `just setup` makes them, `just build` refuses without them, `just deploy`
# carries them into the deployed checkout and backs them up to the archive,
# and `just verify` compares each with what the image ended up holding — which
# is what catches an example added without the Dockerfile line to read it.
# see docs/configuration.md#the-three-files-that-are-yours

CONFIG_FILES=()
for _config_example in image/config/*.example.txt; do
    CONFIG_FILES+=("$(basename "${_config_example%.example.txt}").txt")
done
unset _config_example
