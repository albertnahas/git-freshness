#!/bin/bash
# git-freshness — PreToolUse hook: keep Claude from reasoning on a stale checkout.
#
# Resolves the git repo enclosing whatever file the tool is about to touch and:
#   behind >= block_behind  -> deny the call, telling Claude to update first
#   behind >= warn_behind   -> allow, but inject the behind-count as context
#   otherwise               -> silent
#
# Works on ANY repo the session wanders into, not just the one it started in —
# the case SessionStart cannot cover.
#
# It fires on every Read/Grep/Glob/Edit/Write, so it must be cheap and must never
# wait on the network: the decision is read from a per-repo cache, and the actual
# `git fetch` runs DETACHED in the background to refresh that cache for next time.
# Worst case the count is one TTL out of date; it is never a stall.
#
# Config: ~/.claude/git-freshness.json, or GIT_FRESHNESS_* env overrides.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-git-freshness"
CONFIG="${GIT_FRESHNESS_CONFIG:-$HOME/.claude/git-freshness.json}"

# --- input: one jq pass, not four -------------------------------------------

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0

# Bash is deliberately not matched: parsing shell to guess a path is worse than
# nothing, and its cwd is already covered by whatever file tool runs alongside it.
FIELDS="$(jq -r '
  [ .session_id // "x",
    (if .tool_name == "Read" or .tool_name == "Edit" or .tool_name == "Write"
        then .tool_input.file_path
     elif .tool_name == "NotebookEdit" then .tool_input.notebook_path
     elif .tool_name == "Grep" or .tool_name == "Glob" then .tool_input.path
     else null end) // .cwd // ""
  ] | @tsv' <<<"$INPUT" 2>/dev/null)" || exit 0

SESSION="${FIELDS%%$'\t'*}"
TARGET="${FIELDS#*$'\t'}"
[ -n "$TARGET" ] && [ "$TARGET" != "$SESSION" ] || exit 0

# --- locate the repo (cheapest git call there is) ---------------------------

DIR="$TARGET"
[ -d "$DIR" ] || DIR="${DIR%/*}"
[ -d "$DIR" ] || exit 0

REPO="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$REPO" ] || exit 0

# Opt-out for repos deliberately pinned behind (vendored copies, archived clones,
# a checkout parked on an old release). Drop the marker file in the repo root.
[ -e "$REPO/.claude-freshness-ignore" ] && exit 0

mkdir -p "$CACHE" 2>/dev/null || true
# Pure-bash cache key: shasum costs ~25ms, the largest single spawn in a hook that
# runs on every tool call. Note bash 3.2 returns EMPTY for ${v: -n} when v is
# shorter than n (bash 4+ clamps), so no negative-offset truncation here — only an
# over-long path falls back to hashing, which effectively never happens.
KEY="${REPO//[^A-Za-z0-9]/_}"
[ "${#KEY}" -le 200 ] || KEY="h$(printf '%s' "$REPO" | shasum | cut -c1-32)"
STATE="$CACHE/$KEY.state"     # "<epoch>\t<behind>\t<upstream>"
LOCK="$CACHE/$KEY.fetching"

# --- config (only now that we know we care) ---------------------------------

# One jq pass for the whole config — this runs on every tool call, so four
# separate spawns here cost more than all the git work combined.
CFG_W=5 CFG_B=50 CFG_T=300 CFG_M=1
if [ -f "$CONFIG" ]; then
  IFS=$'\t' read -r CFG_W CFG_B CFG_T CFG_M < <(jq -r '
    [ .warn_behind // 5, .block_behind // 50, .fetch_ttl // 300, .max_blocks // 1 ]
    | @tsv' "$CONFIG" 2>/dev/null) || { CFG_W=5 CFG_B=50 CFG_T=300 CFG_M=1; }
fi
WARN_BEHIND="${GIT_FRESHNESS_WARN:-$CFG_W}"
BLOCK_BEHIND="${GIT_FRESHNESS_BLOCK:-$CFG_B}"
FETCH_TTL="${GIT_FRESHNESS_TTL:-$CFG_T}"
MAX_BLOCKS="${GIT_FRESHNESS_MAX_BLOCKS:-$CFG_M}"

# --- cached decision, or recompute + refresh in the background --------------

now="$(date +%s)"
age=$((FETCH_TTL + 1)); BEHIND=""; UPSTREAM=""
if [ -f "$STATE" ]; then
  IFS=$'\t' read -r ts BEHIND UPSTREAM < "$STATE" 2>/dev/null || true
  [ -n "${ts:-}" ] && age=$((now - ts))
fi

if [ "$age" -gt "$FETCH_TTL" ]; then
  UPSTREAM="$(git -C "$REPO" rev-parse --abbrev-ref '@{u}' 2>/dev/null \
              || git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
              || true)"
  if [ -z "$UPSTREAM" ]; then
    printf '%s\t0\t-' "$now" > "$STATE"   # nothing to compare against; stop asking
    exit 0
  fi
  # Counted against the refs we already have — no network on this path.
  BEHIND="$(git -C "$REPO" rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)"
  printf '%s\t%s\t%s' "$now" "$BEHIND" "$UPSTREAM" > "$STATE"

  # A background fetch killed before its trap ran would leave the lock behind and
  # silently stop all future refreshes, so reap one that is older than any fetch
  # could legitimately take.
  if [ -d "$LOCK" ]; then
    # GNU first: GNU `stat -f` means filesystem status and "succeeds" with garbage.
    lock_ts="$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo "$now")"
    [ $((now - lock_ts)) -gt 120 ] && rmdir "$LOCK" 2>/dev/null
  fi

  # Detached refresh so the NEXT call sees the truth. One at a time per repo.
  if mkdir "$LOCK" 2>/dev/null; then
    (
      trap 'rmdir "$LOCK" 2>/dev/null' EXIT
      # Never prompt: nobody is there to answer. Stock macOS has no `timeout`;
      # without it a hung fetch only holds the lock until it is reaped.
      export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"
      T="$(command -v timeout || command -v gtimeout || true)"
      ${T:+$T 60} git -C "$REPO" fetch --quiet 2>/dev/null || true
      u="$(git -C "$REPO" rev-parse --abbrev-ref '@{u}' 2>/dev/null \
           || git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      [ -n "$u" ] || exit 0
      b="$(git -C "$REPO" rev-list --count "HEAD..$u" 2>/dev/null || echo 0)"
      printf '%s\t%s\t%s' "$(date +%s)" "$b" "$u" > "$STATE"
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
fi

[ -n "${BEHIND:-}" ] || exit 0
[ "$BEHIND" -ge "$WARN_BEHIND" ] 2>/dev/null || exit 0

# --- decide -----------------------------------------------------------------

emit() {  # emit <decision> <reason-key> <text>
  jq -n --arg d "$1" --arg k "$2" --arg t "$3" \
    '{hookSpecificOutput: ({hookEventName:"PreToolUse", permissionDecision:$d} + {($k): $t})}'
}

if [ "$BEHIND" -ge "$BLOCK_BEHIND" ]; then
  # Capped per repo per session: if the update cannot be done (dirty tree,
  # diverged branch, no access), a permanent block would wedge the session with
  # no way forward. Past the cap this degrades to a warning.
  BLOCKS="$CACHE/$KEY.$SESSION.blocks"
  n=0; [ -f "$BLOCKS" ] && n="$(cat "$BLOCKS" 2>/dev/null || echo 0)"
  if [ "$n" -lt "$MAX_BLOCKS" ]; then
    printf '%s' "$((n + 1))" > "$BLOCKS"
    emit deny permissionDecisionReason \
"$REPO is $BEHIND commits behind $UPSTREAM — too stale to reason about.

Update it first, then retry:
  git -C $REPO pull --ff-only

If that fails (dirty tree, diverged branch, no upstream), say so and ask the user
how to proceed rather than reading the files another way. This block fires once
per repo per session; the next read is allowed with a warning."
    exit 0
  fi
fi

emit allow additionalContext \
"Heads up: $REPO is $BEHIND commits behind $UPSTREAM. What you are about to read may be out of date."
