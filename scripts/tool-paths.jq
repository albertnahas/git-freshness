# Hook stdin -> "now \x1f session \x1f sync \x1f cwd \x1f candidate paths..." (see git-freshness.sh)
def unquote: gsub("^[\"']|[\"']$"; "");
(.tool_input // {}) as $i
| ($i.command // "") as $c
| [ (now | floor | tostring), .session_id // "x",
    (if .tool_name == "Bash"
        and ($c | test("\\bgit\\b[^;&|]*\\b(pull|fetch|merge|rebase|reset|checkout|switch)\\b"))
     then "1" else "0" end),
    .cwd // "" ]
  + ( if .tool_name == "Bash" then
        [ ($c | capture("(^|[;&|(])\\s*cd\\s+(?<p>[^\\s;&|)]+)").p | unquote),
          ($c | capture("\\bgit\\s+-C\\s+(?<p>[^\\s;&|)]+)").p | unquote) ]
        # The program a segment runs (`/opt/homebrew/bin/git …`) is not what it reads.
        + ([ $c | gsub("(?<s>^|[;&|(])\\s*(?:\\w+=\\S*\\s+)*[\"']?~?/[^\\s;&|)\"']*[\"']?"; "\(.s) ")
               | scan("(^|[\\s=])[\"']?(~?/[^\\s;&|)\"'*?]+)")
               # \u0002 marks a `=value` path: git-freshness.sh skips it when it names a program.
               | (if .[0] == "=" then "\u0002" else "" end) + .[1] ] | .[0:3])
        + [ .cwd // empty ]
      # A file tool's path IS its target: outside a repo means silent, not "use cwd".
      else [ $i.file_path // $i.notebook_path // $i.path // .cwd // empty ] end )
| join("\u001f")
