# What one archived session cost and what it was, as one TSV row.
#
# The status page's copy. `scripts/render.py` reads it from beside itself,
# and it stays here rather than in the runner because the dashboard action
# runs in this checkout and cannot reach that tree. The runner keeps its own
# at host/archive/session-meta.jq, which differs in one thing: it renders the
# date and the time in local time, for a person at a terminal, where a page
# rendered on a CI runner has no clock in the room to render against.
#
# Fed one session's transcript plus its sub-agents', concatenated, with
# `jq -rn -f`. Emits: date, time, duration, messages, kind, requests,
# subagent requests, agents, output, thinking, end context, seconds,
# generating seconds, title.
#
# One streaming pass per transcript. `reduce inputs` rather than `-s`
# so a long session is never held in memory whole — these grow without
# bound and the list must stay cheap enough to run reflexively.
#
# aiTitle is Claude Code's own summary of the session and the only
# human-readable label there is; entrypoint separates the unattended
# runs (`sdk-cli`, from `claude -p`) from a session the operator opened (`cli`).
#
# The same pass answers what the session cost. Written here rather than
# shared with the runner's session-stats.py: that one reads the live volume
# through a container and this reads a blob in git.
#
# Three traps, all of them silent, all measured and written up in the
# runner's host/session/session-stats.py:
#
#   Assistant records are streaming snapshots. Several carry one
#   requestId and a usage that GROWS across them, so they are keyed by
#   requestId and the last one wins. Counting records instead inflates
#   both the request count and the output by more than two.
#
#   A sub-agent is cumulated — its requests and its output are the
#   session's — but its CONTEXT is not, and that is the one number that
#   must not be: every agent has a context of its own and adding them
#   together names nothing that ever existed. isSidechain is what tells
#   the two apart, in whichever file the record arrived from.
#
#   Cache reads are left out on purpose. They are the same context
#   re-read once per request, which reads as catastrophe and says only
#   turns by size. They stay in the transcript, so a cost can still be
#   worked out later.
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
      | [ $s[0:10], $s[11:16],
          (if $d >= 3600 then "\($d / 3600 | floor)h\(($d % 3600) / 60 | floor)m"
           elif $d >= 60 then "\($d / 60 | floor)m"
           else "\($d)s" end),
          (.msgs | tostring),
          (if .entry == "sdk-cli" then "auto" else "chat" end),
          ($reqs | tostring), ($subreqs | tostring), (.agents | length | tostring),
          ($out | tostring), ($think | tostring), (.endctx | tostring),
          ($d | tostring), (if .turns then (.gen | floor | tostring) else "" end),
          (.title // "(untitled)") ] | @tsv
