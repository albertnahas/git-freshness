# git-freshness

[![test](https://github.com/albertnahas/git-freshness/actions/workflows/test.yml/badge.svg)](https://github.com/albertnahas/git-freshness/actions/workflows/test.yml) ![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-D97757) ![License: MIT](https://img.shields.io/badge/license-MIT-blue)

**Stop Claude Code from reasoning on a stale checkout.**

You ask Claude about a repo. It greps your local clone, which is 800 commits behind
`origin/main`, and confidently explains code that no longer exists, or writes a fix
against a function that was renamed last week. Nothing tells it the checkout is old.

`git-freshness` is a Claude Code plugin that catches this **before** the read happens,
in **any** repo the session wanders into, through file tools *and* shell commands.

| Commits behind upstream | What happens |
|---|---|
| 50 or more | **Blocked once.** Claude is told to run `git pull --ff-only` and retry. |
| 5 or more | Allowed, with a one-line warning: *"repo is N commits behind origin/main"*. |
| fewer | Silent. No output, no tokens. |

## Install

```
/plugin marketplace add albertnahas/git-freshness
/plugin install git-freshness@git-freshness
```

Needs `git`, `jq` and `bash` (macOS's stock bash 3.2 is fine). macOS and Linux.

## What it looks like

Claude runs `cat ~/dev/api/src/billing.rb` in a clone 60 commits behind. The call is
denied and Claude receives (paths are absolute in the real message):

```
~/dev/api is 60 commits behind origin/main — too stale to reason about.

Update it first, then retry:
  git -C ~/dev/api pull --ff-only
```

Claude pulls, retries, and reads the current code. If the pull is impossible (dirty
tree, diverged branch) it says so and asks you, instead of quietly reading the old copy.

## Why shell coverage matters: replay of 13,853 real tool calls

The first version only watched `Read`/`Grep`/`Glob`/`Edit`/`Write`. Replaying two months
of real sessions (`bench/replay.py`, 271 sessions) showed why that was not enough: agents
mostly read code through the shell (`cat`, `grep`, `rg`, `find`, `git -C`).

| Calls checked against a git repo | v1.0 | v1.1 |
|---|---|---|
| File tools | 744 | 744 |
| Bash, repo named in the command (`cd`, `git -C`, a path) | 0 | 4,405 |
| Bash, repo is the working directory | 0 | 7,273 |
| **Total** | **744 (6%)** | **12,422 (16.7×)** |

v1.0 saw 6% of the calls that touched a repo. On one heavily used monolith clone, 97% of
reads went through Bash, so v1.0 warned or blocked only on the remaining 3%. When it did
fire, it worked: both real blocks in that window were followed by Claude updating the
repo before reading on.

## Cost: cheaper per call than v1.0

Each tool call starts the hook as a fresh process, so every process it spawns is paid on
every call. v1.1 spawns exactly one (`jq`) on the hot path: the repo lookup, cache key
and config parse are pure bash, and `jq` also supplies the clock.

`bench/latency.py`, 300 runs per cell, macOS, bash 3.2. "Floor" is a hook that does
nothing but read stdin: the cost of having any hook at all.

| Scenario | v1.0 median / p95 | v1.1 median / p95 |
|---|---|---|
| Floor (no-op hook) | 16.0 / 24.7 ms | 16.0 / 24.7 ms |
| Read, repo up to date | 61.3 / 76.1 ms | **22.2 / 28.5 ms** |
| Read, repo 10 behind (warns) | 72.6 / 111.8 ms | **28.7 / 39.7 ms** |
| Read, outside any repo | 37.5 / 64.1 ms | **20.8 / 33.0 ms** |
| Bash, `cd repo && grep` | not covered | 23.3 / 37.4 ms |
| Bash, `rg` on a repo path | not covered | 21.7 / 29.2 ms |
| Bash, outside any repo | not covered | 19.6 / 26.5 ms |

On a file read in an up-to-date repo, the hook's own work above the floor went from
~45 ms to ~6 ms.

Inside a real Claude Code session (its own debug log, which includes Claude Code starting
the process) the medians were: no-op hook 81–91 ms, v1.0 146–155 ms, v1.1 105–128 ms.

**The honest trade-off.** Per call, v1.1 is cheaper than v1.0. But it now also runs on
Bash, which is most calls, so a session pays it more often. With the in-session medians and
the replayed mix (6 file-tool and 45 Bash calls per session):

| Hook time per session | v1.0 | v1.1 |
|---|---|---|
| Claude Code starting the hook (no-op floor) | ~0.5 s | ~4.4 s |
| git-freshness's own work | ~0.4 s | ~1.3 s |
| **Total** | **~0.9 s** | **~5.7 s** |

About 0.1 s per tool call, three-quarters of it the cost Claude Code charges for *any* hook
on Bash; if you already run one there, part of that overlaps, since Claude Code runs
matching hooks in parallel. Spread over a session of model turns that each take seconds,
it is a small, flat tax. What it buys is coverage of the 94% of reads v1.0 never saw.

**If you already run a Bash hook, the added wait can be zero.** Measured in a real session
alongside two existing Bash hooks (an output-rewriting hook and a status-line hook):
git-freshness took a median 86 ms and finished before the slowest existing hook (median
168 ms) on 8 of 8 calls, so the tool never waited longer than it already did.

**Why not filter Bash with an `if` rule?** Claude Code can skip starting a hook unless the
command matches a rule like `Bash(cat *)`. But read commands are everywhere: in the
replayed sessions `cd` appears in 56% of Bash calls, `grep` in 43%, `head` in 42%. A
filter would skip few calls, and a piped command matching several rules starts the hook
once per rule. One unconditional handler is the cheapest design.

**Never on the network.** The hook answers from a local cache and runs `git fetch`
detached in the background, at most once per `fetch_ttl` per repo, with credential and
SSH prompts disabled. A slow remote can never stall a tool call.

## Configure

`~/.claude/git-freshness.json` (all optional):

```json
{ "warn_behind": 5, "block_behind": 50, "fetch_ttl": 300, "max_blocks": 1 }
```

| Key | Default | Meaning |
|---|---|---|
| `warn_behind` | 5 | Commits behind before warning. |
| `block_behind` | 50 | Commits behind before blocking. |
| `fetch_ttl` | 300 | Seconds a repo's count is trusted before it is recounted and refetched in the background. Match it to how often your team pushes: raise it for slow-moving repos, lower it for busy monorepos. A pull or fetch you run yourself resets it immediately. |
| `max_blocks` | 1 | Blocks per repo per session before it only warns. `0` = never block. |

Env overrides: `GIT_FRESHNESS_WARN`, `GIT_FRESHNESS_BLOCK`, `GIT_FRESHNESS_TTL`,
`GIT_FRESHNESS_MAX_BLOCKS`, `GIT_FRESHNESS_CONFIG` (config path).

**Opt a repo out** (vendored copy, release branch you keep pinned):
`touch <repo>/.claude-freshness-ignore`

## How it works

A `PreToolUse` hook on `Read`, `Edit`, `Write`, `Grep`, `Glob`, `NotebookEdit` and `Bash`:

1. **Find the target.** For file tools, the path they are about to touch. For Bash, the
   first of: a `cd <dir>`, a `git -C <dir>`, an absolute path argument, the working
   directory. A file outside any repo is silent; it never falls back to the cwd.
2. **Find the repo** by walking up to the nearest `.git` (dir or file, so worktrees and
   submodules work). No process spawned.
3. **Read `behind`** from `~/.cache/claude-git-freshness/`, counted against the branch's
   upstream (or `origin/HEAD`). If older than `fetch_ttl`, recount from local refs and
   start one detached `git fetch` for next time.
4. **Decide**: deny once, warn via `additionalContext`, or stay silent.

Never in the way:

- **Git commands that update the repo pass straight through** (`pull`, `fetch`, `merge`,
  `rebase`, `reset`, `checkout`, `switch`), and they clear the cached count, so the next
  call does not warn about commits you just pulled.
- **One block per repo per session**, then warnings only. A repo that cannot be updated
  can never wedge a session.

## Reproduce the numbers

```
tests/run.sh                    # 21 end-to-end cases on real repos (CI: macOS + Linux)
bench/latency.py [runs] [ref]   # per-call latency, this tree vs a git ref
bench/replay.py [since] [ref]   # coverage over your own transcripts; aggregates only,
                                # no paths or commands printed, no network
```

## License

MIT
