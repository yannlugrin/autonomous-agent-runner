# shellcheck shell=bash
# Host-wide sysstat samples while a session runs, read back with `sar -f`.
#
# Sourced by host/session/run.sh and chat.sh. Off unless RUNNER_SAMPLE_SECONDS
# is a number, and silently off where sysstat is not installed: nothing here may
# fail a session.

sampler=""

sample_start() {
    local every="${RUNNER_SAMPLE_SECONDS:-}" sadc
    local dir="$RUNNER_CACHE_DIR/sysstat"
    case "$every" in ''|0|*[!0-9]*) return 0 ;; esac

    # Not on PATH, and packaged in a different place by release and distribution.
    for sadc in /usr/libexec/sysstat/sadc /usr/lib/sysstat/sadc /usr/lib64/sa/sadc /usr/lib/sa/sadc; do
        [ -x "$sadc" ] && break
    done
    [ -x "$sadc" ] || return 0
    mkdir -p "$dir" 2>/dev/null || return 0

    # sadc and not sa1: sa1 writes to /var/log/sysstat, which only root can.
    # Given a directory, sadc writes the daily saDD file and replaces it a month on.
    "$sadc" -F -L -S DISK "$every" 100000000 "$dir" </dev/null >/dev/null 2>&1 &
    sampler=$!
}

sample_stop() {
    [ -n "$sampler" ] && kill "$sampler" 2>/dev/null
    sampler=""
    return 0
}
