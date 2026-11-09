#!/usr/bin/env python3
"""Hook latency: what each tool call pays, per version and scenario.

    bench/latency.py [runs] [old_ref]     defaults: 300 runs, old ref v1.0.0

Builds throwaway repos, runs the hook exactly as Claude Code does (JSON on stdin,
fresh process per call) and reports median / p95 wall time in milliseconds. A no-op
hook (`cat >/dev/null`) is the floor: the cost of Claude Code starting any hook.
"""
import json, os, statistics, subprocess, sys, tempfile

RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 300
OLD_REF = sys.argv[2] if len(sys.argv) > 2 else "v1.0.0"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = tempfile.mkdtemp()
ENV = {**os.environ, "XDG_CACHE_HOME": f"{T}/cache", "GIT_FRESHNESS_CONFIG": f"{T}/cfg.json",
       "GIT_AUTHOR_NAME": "b", "GIT_AUTHOR_EMAIL": "b@b", "GIT_COMMITTER_NAME": "b",
       "GIT_COMMITTER_EMAIL": "b@b", "GIT_FRESHNESS_MAX_BLOCKS": "0"}
open(f"{T}/cfg.json", "w").write('{"warn_behind": 5, "block_behind": 50, "fetch_ttl": 3600}')

def git(*a): subprocess.run(["git", *a], check=True, capture_output=True, env=ENV)

def repo(name, behind):
    up, cl = f"{T}/{name}-up", f"{T}/{name}"
    git("init", "-q", "-b", "main", up); git("-C", up, "commit", "-q", "--allow-empty", "-m", "0")
    git("clone", "-q", up, cl)
    for i in range(behind): git("-C", up, "commit", "-q", "--allow-empty", "-m", str(i))
    git("-C", cl, "fetch", "-q")
    os.makedirs(f"{cl}/src/deep/path", exist_ok=True)
    return cl

fresh, stale = repo("fresh", 0), repo("stale", 10)
os.makedirs(f"{T}/plain/dir", exist_ok=True)

old = f"{T}/old.sh"
open(old, "w").write(subprocess.run(["git", "-C", ROOT, "show", f"{OLD_REF}:scripts/git-freshness.sh"],
                                    check=True, capture_output=True, text=True).stdout)
os.chmod(old, 0o755)
noop = f"{T}/noop.sh"
open(noop, "w").write("#!/bin/bash\ncat >/dev/null\n"); os.chmod(noop, 0o755)
new = f"{ROOT}/scripts/git-freshness.sh"

def read(p):  return {"session_id": "b", "tool_name": "Read", "tool_input": {"file_path": p}, "cwd": "/"}
def bash(c):  return {"session_id": "b", "tool_name": "Bash", "tool_input": {"command": c}, "cwd": f"{T}/plain"}

SCENARIOS = [  # (label, payload, does v1.0 match this tool?)
    ("Read, repo up to date",           read(f"{fresh}/src/deep/path/f.rb"), True),
    ("Read, repo 10 behind (warns)",    read(f"{stale}/src/f.rb"),           True),
    ("Read, outside any repo",          read(f"{T}/plain/dir/f.txt"),        True),
    ("Bash, cd repo && grep",           bash(f"cd {fresh} && grep -rn foo src"), False),
    ("Bash, rg on absolute repo path",  bash(f"rg foo {fresh}/src/deep"),    False),
    ("Bash, outside any repo",          bash("ls -la /tmp"),                 False),
]

def ms(script, payload):
    data = json.dumps(payload).encode()
    for _ in range(5): subprocess.run([script], input=data, capture_output=True, env=ENV)  # warm cache
    out = []
    for _ in range(RUNS):
        t = __import__("time").perf_counter()
        subprocess.run([script], input=data, capture_output=True, env=ENV)
        out.append((__import__("time").perf_counter() - t) * 1000)
    out.sort()
    return statistics.median(out), out[int(len(out) * .95)]

floor = ms(noop, read(f"{fresh}/x"))
rows = []
for label, payload, old_matches in SCENARIOS:
    o = ms(old, payload) if old_matches else None
    n = ms(new, payload)
    rows.append((label, o, n))

f = lambda v: "not run" if v is None else f"{v[0]:.1f} / {v[1]:.1f}"
print(f"runs per cell: {RUNS}   bash: {subprocess.run(['/bin/bash','-c','echo $BASH_VERSION'],capture_output=True,text=True).stdout.strip()}   "
      f"floor (no-op hook): {f(floor)} ms\n")
print(f"| Scenario | {OLD_REF} median / p95 (ms) | new median / p95 (ms) |\n|---|---|---|")
for label, o, n in rows: print(f"| {label} | {f(o)} | {f(n)} |")
print(json.dumps({"floor": floor, "rows": rows}), file=open(f"{T}/../git-freshness-latency.json", "w"))
