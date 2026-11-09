#!/bin/bash
# End-to-end test: real git repos, real hook stdin, real hook stdout.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/scripts/git-freshness.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export XDG_CACHE_HOME="$T/cache" GIT_FRESHNESS_CONFIG="$T/none.json"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fails=0

# clone_behind <name> <n>: a clone whose HEAD is <n> commits behind origin/main.
clone_behind() {
  local up="$T/$1-up" cl="$T/$1"
  git init -q -b main "$up" && git -C "$up" commit -q --allow-empty -m 0
  git clone -q "$up" "$cl"
  for i in $(seq "$2"); do git -C "$up" commit -q --allow-empty -m "$i"; done
  git -C "$cl" fetch -q
  echo "$cl"
}

# run <session> <tool> <path> -> hook stdout
run() {
  jq -nc --arg s "$1" --arg t "$2" --arg p "$3" \
    '{session_id:$s, tool_name:$t, tool_input:{file_path:$p, path:$p}, cwd:"/"}' | "$HOOK"
}

check() {  # check <label> <expected decision or "silent"> <output>
  local got; got="$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$3" 2>/dev/null)"
  [ -n "$3" ] || got=silent
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: want $2, got $got"; fails=$((fails + 1)); fi
}

far="$(clone_behind far 60)"
check "60 behind: first read is blocked"   deny   "$(run s1 Read "$far/README")"
check "60 behind: second read only warns"  allow  "$(run s1 Read "$far/README")"
check "new session is blocked again"       deny   "$(run s2 Grep "$far")"

near="$(clone_behind near 10)"
out="$(run s1 Glob "$near")"
check "10 behind: warns"                   allow  "$out"
grep -q "10 commits behind" <<<"$out" && echo "ok   warning names the count" \
  || { echo "FAIL warning text: $out"; fails=$((fails + 1)); }

check "2 behind: silent"                   silent "$(run s1 Read "$(clone_behind fresh 2)/x")"

pinned="$(clone_behind pinned 60)"; touch "$pinned/.claude-freshness-ignore"
check "ignore marker: silent"              silent "$(run s1 Read "$pinned/x")"

check "outside any repo: silent"           silent "$(run s1 Read "$T/nowhere/x")"
check "file outside a repo ignores cwd"    silent "$(jq -nc --arg p "$T/nowhere/x" --arg d "$far" '{session_id:"s9",tool_name:"Read",tool_input:{file_path:$p},cwd:$d}' | "$HOOK")"
check "unmatched tool: silent"             silent "$(echo '{"session_id":"s","tool_name":"Bash","tool_input":{},"cwd":"/nonexistent"}' | "$HOOK")"

bash_run() {  # bash_run <session> <command> <cwd>
  jq -nc --arg s "$1" --arg c "$2" --arg d "$3" \
    '{session_id:$s, tool_name:"Bash", tool_input:{command:$c}, cwd:$d}' | "$HOOK"
}
sh="$(clone_behind shell 60)"
check "bash: cd <stale repo> && grep is blocked"  deny   "$(bash_run b1 "cd $sh && grep -rn foo ." /)"
check "bash: git -C <stale repo> warns after"     allow  "$(bash_run b1 "git -C '$sh' log -1" /)"
check "bash: absolute path argument is checked"   deny   "$(bash_run b2 "rg foo \"$sh/src\"" /)"
check "bash: cwd inside stale repo is checked"    deny   "$(bash_run b3 "ls" "$sh")"
check "bash: relative cd resolves against cwd"    deny   "$(bash_run b4 "cd shell && cat x" "$T")"
check "bash: outside any repo is silent"          silent "$(bash_run b5 "ls /" /)"
check "bash: git pull is never blocked"           silent "$(bash_run b6 "cd $sh && git pull --ff-only" /)"
git -C "$sh" pull -q --ff-only
check "bash: pull clears the stale count"         silent "$(bash_run b7 "cat $sh/x" /)"

ext="$(clone_behind external 60)"
check "external pull: blocked before"             deny   "$(run e1 Read "$ext/a")"
sleep 1; git -C "$ext" pull -q --ff-only
check "external pull: recounted at once"          silent "$(run e2 Read "$ext/a")"

GIT_FRESHNESS_MAX_BLOCKS=0 check "max_blocks 0: warn only" allow "$(GIT_FRESHNESS_MAX_BLOCKS=0 run s3 Read "$(clone_behind warnonly 60)/x")"

sleep 1   # let detached fetches finish before the temp dir goes
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
