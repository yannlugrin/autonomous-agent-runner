# How one transcript entry is shown on screen. A jq module, included by
# `just listen` and `just read`.
#
# One copy, because two spellings of "what a message looks like" drift, and the
# one that drifts is the one nobody is reading at the moment it does. What is
# deliberately not here is which entries to show: `listen` skips subagent lines
# because they are noise beside a running session, and `read` shows them because
# a subagent's transcript is entirely made of them. That is the caller's
# question, and each has exactly one answer to it.
#
# $dim, $bold and $off are the caller's --arg colours, passed in rather than
# written here: a control character in a source file is invisible to whoever
# edits it next and survives exactly until someone reflows the line.
# see docs/sessions.md#one-renderer-for-both-readers

# Who is speaking, read from the entry rather than from which recipe called. A
# subagent's transcript holds the same two types a session's does, and the
# `user` side of it is a prompt the agent wrote plus tool results — calling that
# "operator" would put words in their mouth, which these files must never do.
def text_of:
  (.message.content
   | if type == "string" then .
     else (map(select(type == "object" and .type == "text") | .text) | join(" "))
     end) // "";

def who:
  if .isSidechain == true then
    (if .type == "assistant" then "subagent" else "task" end)
  elif .type == "assistant" then ($agent // "agent")
  # An unattended session's first message is the runner's, not the operator's,
  # and a label that contradicts the line under it is the exact confusion rule 1
  # exists to prevent — so the marker `run` writes is read back here. $runner
  # comes from the justfile, the one place it is spelled.
  elif (text_of | startswith($runner)) then "runner"
  else ($operator // "operator")
  end;

def render:
  # Local time, converted here rather than sliced out of the string, because a
  # time read by a person is local and a time given to the agent — its
  # environment, its system prompt, the transcript, the day-directory the
  # archive files it under — is UTC. Display only: nothing written down changes.
  #
  # [0:19] before the parse, because fromdateiso8601 rejects the fractional
  # seconds the transcript carries ("…:42.818Z") and a rejection in jq kills the
  # whole render rather than the one line. try/catch rather than a length test,
  # falling back to the raw UTC slice: a clock an hour out is a bug report, a
  # transcript that will not display is a session nobody can read.
  (.timestamp // "") as $ts
  | (try ($ts[0:19] + "Z" | fromdateiso8601 | strflocaltime("%H:%M"))
     catch $ts[11:16]) as $hm
  | who as $who
  | (.message.content | if type == "string" then [{type: "text", text: .}] else . end)[]
  | if .type == "text" then
        (if (.text | gsub("\\s"; "")) == "" then empty
         else "\n" + $dim + $hm + $off + " " + $bold + $who + $off + "\n"
              + (.text | split("\n") | map("  " + .) | join("\n"))
         end)
    elif .type == "tool_use" then
        # $full is the caller's, and every caller passes it: an undefined
        # variable is a compile error in jq, not a null. `listen` passes false,
        # `read --full` true — where a long prompt is the reason the flag was
        # reached for and ninety characters of it is the same nothing as none.
        #
        # Each line of an expanded payload carries its own dim/reset: a single
        # span around a multi-line block leaves the colour on if the output is
        # cut short.
        ((.input.command // .input.file_path // .input.pattern // .input.prompt // "")
         | tostring) as $payload
        | if $full then
              $dim + $hm + $off + "   > " + .name
              + (if $payload == "" then ""
                 else "\n" + ($payload | split("\n")
                               | map($dim + "         " + . + $off) | join("\n"))
                 end)
          else
              $dim + $hm + $off + "   > " + .name + "  " + $dim
              + ($payload | split("\n")[0] | .[0:90]) + $off
          end
    else empty end;
