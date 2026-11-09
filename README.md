# git-freshness

[![test](https://github.com/albertnahas/git-freshness/actions/workflows/test.yml/badge.svg)](https://github.com/albertnahas/git-freshness/actions/workflows/test.yml) ![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-D97757) ![License: MIT](https://img.shields.io/badge/license-MIT-blue)

**Stop Claude Code from reasoning on a stale checkout.**

You ask Claude about a repo. It greps your local clone, which is 800 commits behind
`origin/main`, and confidently explains code that no longer exists. `git-freshness` is a
Claude Code plugin that catches this before the read happens, in **any** repo the session
wanders into, not just the one it started in.

| Commits behind upstream | What happens |
|---|---|
| 50 or more | **Blocked once.** Claude is told to run `git pull --ff-only` and retry. |
| 5 or more | Allowed, with a one-line warning: *"repo is N commits behind origin/main"*. |
| fewer | Silent. |

## Install

```
/plugin marketplace add albertnahas/git-freshness
/plugin install git-freshness@git-freshness
```

Needs `git`, `jq` and `bash`. Works on macOS and Linux.

## Why it never gets in your way

- **No waiting on the network.** The decision comes from a local cache; `git fetch` runs
  detached in the background so the *next* call sees fresh numbers. Cost is ~100 ms per
  file tool call, all process start-up.
- **Never wedges a session.** The block fires once per repo per session, then degrades to a
  warning. A repo that cannot be updated (dirty tree, diverged branch, no access) is still
  readable.
- **Never prompts.** Background fetches run with credential and SSH prompts disabled.
- **No API calls, no tokens** unless it actually fires, and then one sentence.

## Configure

`~/.claude/git-freshness.json` (all optional):

```json
{ "warn_behind": 5, "block_behind": 50, "fetch_ttl": 300, "max_blocks": 1 }
```

| Key | Meaning |
|---|---|
| `warn_behind` | Commits behind before warning. |
| `block_behind` | Commits behind before blocking. |
| `fetch_ttl` | Seconds between background fetches per repo. |
| `max_blocks` | Blocks per repo per session before it only warns. `0` = never block. |

Env overrides: `GIT_FRESHNESS_WARN`, `GIT_FRESHNESS_BLOCK`, `GIT_FRESHNESS_TTL`,
`GIT_FRESHNESS_MAX_BLOCKS`, `GIT_FRESHNESS_CONFIG` (config path).

**Opt a repo out** (vendored copy, release branch you keep pinned):
`touch <repo>/.claude-freshness-ignore`

## How it works

A `PreToolUse` hook on `Read`, `Edit`, `Write`, `Grep`, `Glob` and `NotebookEdit`:

1. Takes the path the tool is about to touch and finds its git repo.
2. Reads `behind` for that repo from `~/.cache/claude-git-freshness/`, compared against the
   branch's upstream (or `origin/HEAD` when there is none).
3. If the cache is older than `fetch_ttl`, recounts from local refs and starts one detached
   `git fetch` to refresh it.
4. Denies, warns via `additionalContext`, or stays silent.

`Bash` is deliberately not matched: guessing a path out of shell syntax is worse than not
checking.

## Test

```
tests/run.sh
```

Builds real repos at known distances behind, feeds the hook real stdin, and checks the
decision. Runs on macOS and Linux in CI.

## License

MIT
