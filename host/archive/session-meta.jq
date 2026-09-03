# What one archived session cost and what it was, as one TSV row.
#
# Read by `just sessions` for the listing and by `just read` for the header
# over one transcript — through archive_rows in host/lib/archive.sh, the one
# place the table is built — and by the archive's own dashboard workflow, which
# keeps its own copy beside render.py: that action runs in the archive checkout
# and cannot reach this tree.
#
# Fed one session's transcript plus its sub-agents', concatenated, with
# `jq -rn -f`. Emits: date, time, duration, messages, kind, requests, subagent
# requests, agents, output, thinking, end context, seconds, generating seconds,
# title.
#
# The date and the time are local, and everything the transcript stores stays
# UTC: a time read by a person is read against the clock in the room, and a
# time the agent is given, or a path the archive files a session under, is not.
#
# One streaming pass per transcript. `reduce inputs` rather than `-s` so a long
# session is never held in memory whole — these grow without bound and the list
# must stay cheap enough to run reflexively.
#
# aiTitle is Claude Code's own summary of the session and the only
# human-readable label there is; entrypoint separates the unattended runs
# (`sdk-cli`, from `claude -p`) from a session the operator opened (`cli`).
#
# Written here rather than shared with host/session/session-stats.py: that one
# reads the live volume through a container and this reads a blob in git.
#
# Three traps, all silent, all written up in host/session/session-stats.py:
# assistant records are streaming snapshots, so several carry one requestId
# with a usage that grows across them and are keyed by requestId, the last one
# winning; a sub-agent's requests and output are cumulated into the session's
# but its context is not, since every agent has a context of its own, and
# isSidechain is what tells the two apart; and cache reads are left out, being
# the same context re-read once per request, which reads as catastrophe and
# says only turns by size.
# see docs/archive.md#what-session-metajq-measures
reduce inputs as $x (
        {start:null, end:null, title:null, entry:null, msgs:0,
         req:{}, agents:{}, endctx:0, endat:"", gen:0, turns:false};
        if $x.isSidechain == true then
          # A sub-agent. What it spent counts; nothing else about it does.
            (if $x.type == "assistant" and $x.requestId
             then .req[$x.requestId] = {side: true, u: ($x.message.usage // {})}
             else . end)
          | (if $x.agentId then .agents[$x.agentId] = true else . end)
        else
            (if $x.timestamp
             then .start = (if .start == null or $x.timestamp < .start
                            then $x.timestamp else .start end)
                | .end   = (if .end == null or $x.timestamp > .end
                            then $x.timestamp else .end end)
             else . end)
          | .title = (if $x.type == "ai-title" and $x.aiTitle then $x.aiTitle else .title end)
          | .entry = (if $x.entrypoint then $x.entrypoint else .entry end)
          | .msgs = (if ($x.type == "assistant" or $x.type == "user")
                     then .msgs + 1 else .msgs end)
          # Turns exist only where someone took them. An unattended run is
          # headless and has none, and there the elapsed time IS the
          # working time — printing it twice under two names would be the
          # lie, not the omission.
          | (if $x.subtype == "turn_duration"
             then .turns = true | .gen += (($x.durationMs // 0) / 1000)
             else . end)
          | (if $x.type == "assistant"
             then ($x.message.usage // {}) as $u
                | (if $x.requestId then .req[$x.requestId] = {side: false, u: $u} else . end)
                | (if $x.timestamp and $x.timestamp >= .endat
                   then .endat = $x.timestamp
                      | .endctx = (($u.input_tokens // 0)
                                   + ($u.cache_creation_input_tokens // 0)
                                   + ($u.cache_read_input_tokens // 0))
                   else . end)
             else . end)
        end)
      | (.req | to_entries | map(.value)) as $r
      | ($r | map(select(.side | not)) | length) as $reqs
      | (($r | length) - $reqs) as $subreqs
      | ($r | map(.u.output_tokens // 0) | add // 0) as $out
      | ($r | map(.u.output_tokens_details.thinking_tokens // 0) | add // 0) as $think
      | (.start // "") as $s | (.end // "") as $e
      | (if $s != "" and $e != ""
         then (($e[0:19] + "Z" | fromdateiso8601) - ($s[0:19] + "Z" | fromdateiso8601))
         else 0 end) as $d
      # The start as an instant, so the two fields below can be rendered
      # against the clock in the room. [0:19] before the parse, because
      # fromdateiso8601 rejects the fractional seconds a transcript carries;
      # try/catch falls back to the raw UTC slice, since a row that will not
      # render is worse than one an hour out.
      | (try ($s[0:19] + "Z" | fromdateiso8601) catch null) as $t
      | [ (if $t == null then $s[0:10] else $t | strflocaltime("%Y-%m-%d") end),
          (if $t == null then $s[11:16] else $t | strflocaltime("%H:%M") end),
          (if $d >= 3600 then "\($d / 3600 | floor)h\(($d % 3600) / 60 | floor)m"
           elif $d >= 60 then "\($d / 60 | floor)m"
           else "\($d)s" end),
          (.msgs | tostring),
          (if .entry == "sdk-cli" then "auto" else "chat" end),
          ($reqs | tostring), ($subreqs | tostring), (.agents | length | tostring),
          ($out | tostring), ($think | tostring), (.endctx | tostring),
          ($d | tostring), (if .turns then (.gen | floor | tostring) else "" end),
          (.title // "(untitled)") ] | @tsv
