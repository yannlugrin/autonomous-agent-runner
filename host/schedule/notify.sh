#!/usr/bin/env bash
# Put one line in front of the operator, on the Windows desktop this WSL host
# lives inside — the one thing that is by definition awake whenever a session
# could be failing. Runs on the host, like publish-status.sh and
# dispatch-mirror.sh; the container has no part in it and is not told it exists.
# see docs/schedule.md#why-a-toast
#
# Silent when someone is watching: on a terminal the caller has already printed
# the reason and a toast on top is noise, so this is for the runs nobody is in.
# It is publish-status.sh's `say` rule turned the other way up, and --force is
# for proving it by hand.
#
# The powershell path is spelled out, and that is the whole reason this is not a
# one-line call at the point of need: cron's environment is not a login shell,
# and WSL's Windows interop path is appended by the profile.
# see docs/schedule.md#the-powershell-path-under-cron
#
# It can never fail its caller — exit 0 whatever happens, --check aside: an
# alert that could not be delivered must not turn a session that merely failed
# into a run that also crashed on the way out.
set -uo pipefail

PS_EXE=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe

force=false
check=false
case "${1:-}" in
    --force) force=true; shift ;;
    # Prints which powershell it would use and refuses when there is none. The
    # delivery ends on a screen and cannot be probed, so what is probeable is
    # the one silent part. Ask it as cron would: env -i notify.sh --check
    --check) check=true; shift ;;
esac

if [ "$check" = false ] && [ $# -eq 0 ]; then
    echo "Usage: notify.sh [--force|--check] <one line>" >&2
    exit 2
fi

powershell=""
if [ -x "$PS_EXE" ]; then
    powershell="$PS_EXE"
else
    powershell="$(command -v powershell.exe 2>/dev/null)" || powershell=""
fi

if [ "$check" = true ]; then
    if [ -n "$powershell" ]; then echo "notify: $powershell"; exit 0; fi
    echo "notify: no powershell.exe — nothing would be delivered." >&2
    exit 1
fi

# Not a WSL host with Windows behind it. Nothing to say and nothing wrong.
[ -n "$powershell" ] || exit 0
[ "$force" = true ] || [ ! -t 1 ] || exit 0

# The title falls back to a generic name. Every other script here refuses to run
# on an unset variable; this one deliberately does not, because the alternative
# to a vague title is no alert at all — the failure this file exists to prevent.
title="${AGENT_NAME:-agent}"

# Newlines out, then XML-escaped. A toast is one line, and stripping them also
# keeps a message from closing the PowerShell here-string below: its terminator
# only counts at the start of a line.
body="$(printf '%s' "$*" | tr '\n\r\t' '   ')"
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# scenario="reminder" with an <actions> element rather than a plain toast: this
# one stays on screen until it is dismissed, which is the point — it must
# survive the operator being in another window when a session dies.
# see docs/schedule.md#a-reminder-toast-not-a-banner
#
# The AppId is PowerShell's own, registered under HKCU\...\Notifications\Settings
# the first time anything posts through it. Registering one of our own would mean
# writing to the Windows registry from here, for a nicer name on a toast.
#
# -EncodedCommand, and never `-Command -` reading the script from stdin: that
# consumes stdin the way a prompt does, so a multi-line here-string never
# completes and PowerShell exits 0 having posted nothing. Base64 of UTF-16LE is
# what the flag wants; iconv and base64 are both in cron's PATH.
# see docs/schedule.md#encodedcommand-not-command-dash
#
# `timeout` because WSL interop can hang, and a wedged notifier inside a run
# that wakes every minute would be a worse fault than the one it came to report.
read -r -d '' script <<PS
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > \$null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] > \$null
\$xml = @"
<toast scenario="reminder">
  <visual><binding template="ToastGeneric">
    <text>$(esc "$title")</text>
    <text>$(esc "$body")</text>
  </binding></visual>
  <audio src="ms-winsoundevent:Notification.Reminder"/>
  <actions><action content="OK" arguments="ok" activationType="background"/></actions>
</toast>
"@
\$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
\$doc.LoadXml(\$xml)
\$t = New-Object Windows.UI.Notifications.ToastNotification \$doc
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show(\$t)
PS

encoded="$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" || exit 0
timeout 30 "$powershell" -NoProfile -NonInteractive -EncodedCommand "$encoded" >/dev/null 2>&1

exit 0
