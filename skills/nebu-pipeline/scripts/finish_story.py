#!/usr/bin/env python3
"""finish_story.py — Step 9 (commit) in ONE call, no LLM.

  finish_story.py --story ID [--epic NAME] [--bug] [--dry-run] [--no-commit]

Resolves all paths with pipeline_env.py, then runs in order:
  1. commit_summary.py            -> SUMMARY / COMPACT / SUBJECT / MESSAGE_FILE (writes commit-message.txt)
  2. update_sprint_status.py      -> sprint-status.yaml (+ story frontmatter status) ; git add both
  3. git commit -F commit-message.txt   (skipped with --no-commit; no Co-Authored-By line)
  4. generate_traceability.py     -> traceability matrix entry ; git add (silent for legacy stories)
  5. pipeline_gates.py baseline-store    (only if no `integration-stale` marker and ci-integration.log exists)
  6. pipeline_state.py --commit   -> zero YAML fields, journal line "committed ✓ (COMPACT)"

Prints one line per stage plus SUBJECT and the commit SHA. Stops with a non-zero exit at the first hard failure
(commit_summary / sprint-status / commit / state), prints `STAGE_FAILED: <name>` and the tail of its output.
Traceability and baseline problems are reported (`WARN:`) but never block.

--dry-run: only stage 1 and a list of what would run (no file changes except commit-message.txt).
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import pipeline_env  # noqa: E402
import pipeline_lib as pl  # noqa: E402


def run(cmd, name, hard=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0:
        tail = "\n".join(out.strip().splitlines()[-12:])
        if hard:
            print(f"STAGE_FAILED: {name}\n{tail}")
            sys.exit(2)
        print(f"WARN: {name} failed (exit {r.returncode}): {tail[-300:]}")
    return r.returncode, out


def py(script):
    return [sys.executable, "-B", str(HERE / script)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--story", required=True)
    ap.add_argument("--epic")
    ap.add_argument("--bug", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-commit", action="store_true", help="do everything except `git commit` (e.g. to review the message first)")
    a = ap.parse_args()

    root = pl.repo_root()
    os.chdir(root)
    env = pipeline_env.resolve(a.epic, a.story, root)
    story_file, results = env.get("STORY_FILE", ""), env["RESULTS"]
    if not story_file:
        print("STAGE_FAILED: resolve\nstory file not found for " + a.story)
        sys.exit(2)

    cmd = py("commit_summary.py") + ["--state-file", env["STATE_FILE"], "--story", a.story, "--story-file", story_file, "--results-dir", results]
    if a.epic:
        cmd += ["--epic", a.epic]
    if a.bug:
        cmd += ["--bug"]
    _, out = run(cmd, "commit_summary")
    kv = {}
    for line in out.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            kv[k.strip()] = v.strip()
    msg_file = kv.get("MESSAGE_FILE", f"{results}/commit-message.txt")
    print(f"SUBJECT: {kv.get('SUBJECT', '?')}")
    print(f"CYCLES: {kv.get('CYCLES', '?')}  DEFERRED_MINOR: {kv.get('DEFERRED_MINOR', '?')}  REQ_ID: {kv.get('REQ_ID', '-')}")
    if a.dry_run:
        print("DRY_RUN: would run sprint-status update, git commit -F " + msg_file + ", traceability, baseline-store, state --commit")
        return

    run(py("update_sprint_status.py") + ["--file", env["SPRINT_STATUS"], "--story", a.story, "--summary", kv.get("SUMMARY", ""), "--story-file", story_file],
        "update_sprint_status")
    run(["git", "add", "--", env["SPRINT_STATUS"], story_file], "git add")
    print("✓ sprint-status updated and staged")

    if a.no_commit:
        print("COMMIT: skipped (--no-commit)")
    else:
        run(["git", "commit", "-F", msg_file], "git commit")
        sha = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
        print(f"✓ committed {sha}")

    # traceability: never blocks; stays staged for the next commit (same as the manual flow)
    rc, tout = run(py("generate_traceability.py") + ["--story", story_file, "--commit", "HEAD", "--matrix", env["TRACEABILITY_MATRIX"]], "traceability", hard=False)
    if rc == 0 and Path(env["TRACEABILITY_MATRIX"]).exists():
        subprocess.run(["git", "add", "--", env["TRACEABILITY_MATRIX"]], capture_output=True)
        print("✓ traceability entry written and staged")

    log = Path(results) / "ci-integration.log"
    if (Path(results) / "integration-stale").exists():
        print("baseline: skipped (integration-stale)")
    elif log.exists():
        rc, _ = run(py("pipeline_gates.py") + ["baseline-store", "--src", str(log)], "baseline-store", hard=False)
        print("✓ baseline cached" if rc == 0 else "baseline: not cached")
    else:
        print("baseline: skipped (no ci-integration.log)")

    run(py("pipeline_state.py") + ["--file", env["STATE_FILE"], "--commit", "--log", f"[{a.story}] TIMESTAMP committed ✓ ({kv.get('COMPACT', '')})"], "pipeline_state")
    print("✓ Step 9: Committed. Pipeline state cleared.")
    print(f"CONTEXT_HINT: story {a.story} is done and everything is on disk. Every further turn re-reads the whole session context, so start the next story in a fresh session "
          f"(`/clear`, then `nebu-pipeline{' --epic ' + a.epic if a.epic else ''}`; the state file resumes) unless the user wants to continue here.")


if __name__ == "__main__":
    main()
