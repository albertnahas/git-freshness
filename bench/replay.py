#!/usr/bin/env python3
"""Coverage replay: how many of your real tool calls each version actually checks.

    bench/replay.py [since YYYY-MM-DD] [old_ref]     defaults: 2026-09-01, v1.0.0

Reads your Claude Code transcripts (~/.claude/projects/**/*.jsonl), pulls every
Read/Edit/Write/Grep/Glob/NotebookEdit/Bash call since <since>, and feeds each one
to both hook versions with warn_behind=0, so a version emits output exactly when it
resolved the call to a git repo with an upstream. Prints aggregates only: no paths,
no commands, nothing from your transcripts leaves this script.

Background fetches are disabled (GIT_ALLOW_PROTOCOL=none): the replay never touches
the network.
"""
import collections, glob, json, os, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

SINCE = sys.argv[1] if len(sys.argv) > 1 else "2026-09-01"
OLD_REF = sys.argv[2] if len(sys.argv) > 2 else "v1.0.0"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILE_TOOLS = {"Read", "Edit", "Write", "Grep", "Glob", "NotebookEdit"}
T = tempfile.mkdtemp()
old = f"{T}/old.sh"
open(old, "w").write(subprocess.run(["git", "-C", ROOT, "show", f"{OLD_REF}:scripts/git-freshness.sh"],
                                    check=True, capture_output=True, text=True).stdout)
os.chmod(old, 0o755)
new = f"{ROOT}/scripts/git-freshness.sh"
ENV = {**os.environ, "GIT_FRESHNESS_WARN": "0", "GIT_FRESHNESS_MAX_BLOCKS": "0",
       "GIT_FRESHNESS_TTL": "999999999", "GIT_FRESHNESS_CONFIG": f"{T}/none",
       "GIT_ALLOW_PROTOCOL": "none", "GIT_TERMINAL_PROMPT": "0"}

calls = []
for f in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
    for line in open(f, errors="ignore"):
        if '"tool_use"' not in line: continue
        try: d = json.loads(line)
        except ValueError: continue
        if d.get("timestamp", "") < SINCE: continue
        for b in (d.get("message") or {}).get("content") or []:
            if isinstance(b, dict) and b.get("type") == "tool_use" and (b["name"] in FILE_TOOLS or b["name"] == "Bash"):
                calls.append({"session_id": d.get("sessionId", "x"), "tool_name": b["name"],
                              "tool_input": b.get("input") or {}, "cwd": d.get("cwd", "")})

def run(script, call, cache):
    # v1.0 is only registered for file tools; Claude Code never starts it for Bash.
    if script == old and call["tool_name"] == "Bash": return False
    r = subprocess.run([script], input=json.dumps(call).encode(), capture_output=True,
                       env={**ENV, "XDG_CACHE_HOME": cache})
    return bool(r.stdout.strip())

def both(call):
    # Third run hides the cwd: what Bash coverage comes from paths named in the command.
    named = call["tool_name"] == "Bash" and run(new, {**call, "cwd": "/"}, f"{T}/c-named")
    return run(old, call, f"{T}/c-old"), run(new, call, f"{T}/c-new"), named

with ThreadPoolExecutor(8) as ex: results = list(ex.map(both, calls))

stat = collections.Counter()
for call, (o_hit, n_hit, named) in zip(calls, results):
    kind = "bash" if call["tool_name"] == "Bash" else "file"
    stat[f"{kind}_calls"] += 1
    stat[f"{kind}_old_hit"] += o_hit; stat[f"{kind}_new_hit"] += n_hit
    stat["bash_named"] += named

hit_old = stat["file_old_hit"] + stat["bash_old_hit"]
hit_new = stat["file_new_hit"] + stat["bash_new_hit"]
sessions = len({c["session_id"] for c in calls})
print(f"Replayed {len(calls)} real tool calls from {sessions} sessions since {SINCE} "
      f"({stat['file_calls']} file-tool, {stat['bash_calls']} Bash).\n")
print(f"| | {OLD_REF} | new |\n|---|---|---|")
print(f"| Calls checked against a git repo | {hit_old} | {hit_new} ({hit_new / max(hit_old, 1):.1f}x) |")
print(f"| ...file tools | {stat['file_old_hit']} | {stat['file_new_hit']} |")
print(f"| ...Bash, repo named in the command (cd, git -C, path) | 0 | {stat['bash_named']} |")
print(f"| ...Bash, repo is the working directory | 0 | {stat['bash_new_hit'] - stat['bash_named']} |")
print(f"| Share of repo-touching calls seen | {hit_old / max(hit_new, 1):.0%} | 100% (reference) |")
print(f"\nPer session: {stat['file_calls'] / sessions:.0f} file-tool calls, {stat['bash_calls'] / sessions:.0f} Bash calls. "
      "Multiply by bench/latency.py medians for hook time.")
