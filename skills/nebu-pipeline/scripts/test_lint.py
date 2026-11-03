#!/usr/bin/env python3
"""test_lint.py — script-first pre-dev test review (replaces most of the LLM test-review).

Decides deterministically what the review prompt asks for; everything it cannot decide becomes a JUDGE item for the LLM.
  MAJOR  scenario without test · leftover ATDD placeholder · GenServer story without crash/restart test · ui story without e2e test
  MINOR  hard waits (Process.sleep, :timer.sleep, waitForTimeout) · brittle selectors · global state in async tests (Application.put_env,
         Logger level) · test without assertion · Matrix error code (M_*) from the Oracle file not referenced by any test
  JUDGE  scenario that cannot be mapped to a test automatically (legacy tests without `ac:` tags) · weak crash/restart hints

Usage:
  python3 test_lint.py --story STORY.md [--oracle-file F] [--files F ...] [--report PATH]
Output: digest on stdout (VERDICT: CLEAN|MINOR|MAJOR, COUNTS incl. judge=N, REPORT, TOP) + `LLM_NEEDED: yes|no`.
  LLM_NEEDED = yes when MINOR or JUDGE items exist (the reviewer then only judges those); MAJOR/CLEAN need no LLM.
Exit: 1 on MAJOR, else 0.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_lib as pl  # noqa: E402
import atdd_verify as av  # noqa: E402

PLACEHOLDER = "ATDD-PLACEHOLDER"
STRONG_PROC = re.compile(r"\bGenServer\b|Horde\.(Registry|DynamicSupervisor)|\bSupervisor\b|supervised process|process state", re.I)
WEAK_PROC = re.compile(r"\b(crash\w*|survive[sd]?|recover\w*)|\b(process|worker|node|supervisor)\s+restart", re.I)
CRASH_TEST = re.compile(r"Process\.exit\(|:kill\b|Process\.alive\?|terminate_child|restart_child|start_supervised|assert_receive\s*\{:DOWN|Process\.monitor\(")
HARD_WAIT = re.compile(r"Process\.sleep\(|:timer\.sleep\(|waitForTimeout\(|Thread\.sleep\(|\bsleep\s+\d")
BRITTLE = re.compile(r"nth-child|xpath=|//div\b|>\s*div\s*>|\.css-[a-z0-9]{4,}")
GLOBAL_STATE = re.compile(r"Application\.(put|delete)_env\(|Logger\.configure\(|System\.put_env\(")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--story", required=True)
    ap.add_argument("--oracle-file")
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--report")
    a = ap.parse_args()

    root = pl.repo_root()
    text = pl.read_text(a.story)
    fm = pl.frontmatter(text)
    scs = pl.scenarios(text)
    F = []
    cand = a.files if a.files else av.changed_test_files(root)
    slugs = {s["slug"] for s in scs}
    ex, ft, raw = {}, {}, {}
    for f in cand:
        p = Path(f) if os.path.isabs(f) else root / f
        t = pl.read_text(p)
        if not t:
            continue
        raw[f] = t
        if f.endswith(".exs"):
            tests = av.parse_exunit(t)
            if a.files or any(x["slug"] in slugs for x in tests) or any(sc["title"].lower() in x["name"].lower() for x in tests for sc in scs):
                ex[f] = tests
        elif f.endswith(".feature"):
            fs = av.parse_feature(t)
            if a.files or any(x["slug"] in slugs for x in fs) or any(sc["title"].lower() == x["title"].lower() for x in fs for sc in scs):
                ft[f] = fs
        elif f.endswith(".ts") and (a.files or "e2e/" in f):
            ft.setdefault(f, [])
    scope = list(ex) + list(ft)
    all_tests = [(f, t) for f, ts in ex.items() for t in ts]

    # 1. AC coverage
    tagged_any = any(t["slug"] for _, t in all_tests) or any(x["slug"] for fs in ft.values() for x in fs)
    for sc in scs:
        hit = any(t["slug"] == sc["slug"] or sc["title"].lower() in t["name"].lower() for _, t in all_tests) or any(
            x["slug"] == sc["slug"] or x["title"].lower() == sc["title"].lower() for fs in ft.values() for x in fs)
        if hit:
            continue
        if tagged_any:
            F.append(("MAJOR", a.story, f'scenario without test: "{sc["title"][:80]}"', f'add a test tagged `@tag ac: "{sc["slug"]}"`'))
        else:
            F.append(("JUDGE", a.story, f'cannot map scenario to a test automatically: "{sc["title"][:80]}"', "check by reading the tests"))
    if not scs:
        F.append(("JUDGE", a.story, "no Gherkin scenarios parsed from the story", "check AC coverage by reading story and tests"))
    if not scope:
        F.append(("MAJOR", "tests", "no test files found for this story (staged/changed under server/test or e2e)", "run the ATDD step"))

    # 2. placeholders / assertions
    for f, t in all_tests:
        if PLACEHOLDER in t["body"]:
            F.append(("MAJOR", f"{f}:{t['line']}", f'leftover ATDD placeholder: "{t["name"][:60]}"', "replace with real assertions"))
        elif not av.ASSERT_RE.search(t["body"]):
            F.append(("MINOR", f"{f}:{t['line']}", f'test without assertion: "{t["name"][:60]}"', "assert the observable outcome"))

    # 3. hard waits / brittle selectors / global state in async tests
    for f in scope:
        t = raw.get(f, "")
        for i, line in enumerate(t.splitlines(), 1):
            code = line.split("#", 1)[0] if f.endswith(".exs") else line
            if HARD_WAIT.search(code):
                F.append(("MINOR", f"{f}:{i}", "hard wait", "wait for an event (assert_receive / Playwright auto-wait) instead of sleeping"))
            if BRITTLE.search(code) and not f.endswith(".exs"):
                F.append(("MINOR", f"{f}:{i}", "brittle selector", "use role/label/test-id selectors"))
        if f.endswith(".exs") and re.search(r"use ExUnit\.Case,\s*async:\s*true", t):
            m = GLOBAL_STATE.search(t)
            if m:
                ln = t[:m.start()].count("\n") + 1
                F.append(("MINOR", f"{f}:{ln}", "global state mutated in an async: true test", "use async: false or scoped env helpers"))

    # 4. GenServer story -> crash/restart test
    all_text = "\n".join(raw[f] for f in ex)
    story_body = "\n".join(pl.section(text, n) for n in ("Story", "Acceptance Criteria", "Dev Notes")) or text
    if STRONG_PROC.search(story_body):
        if not CRASH_TEST.search(all_text):
            F.append(("MAJOR", a.story, "story involves process state but no crash/restart test exists", "add a test that kills the process and asserts the state after restart"))
    elif WEAK_PROC.search(story_body) and not CRASH_TEST.search(all_text):
        F.append(("JUDGE", a.story, "story mentions restart/crash/recovery but no crash/restart test found", "decide whether a crash/restart test is required"))

    # 5. ui story -> e2e tests
    if fm.get("ui", "").lower() == "true":
        if not any(f.startswith("e2e/") for f in scope):
            F.append(("MAJOR", a.story, "ui: true story without Playwright/feature tests under e2e/", "add e2e/features/<epic>/<story>.feature + steps"))

    # 6. Matrix error codes from the Oracle file
    if a.oracle_file:
        codes = pl.matrix_codes(pl.read_text(a.oracle_file))
        blob = "\n".join(raw.get(f, "") for f in scope)
        for c in codes:
            if c not in blob:
                F.append(("MINOR", a.oracle_file, f"spec error code {c} is not referenced by any test", "add a test for it or note why it does not apply"))

    major = sum(1 for x in F if x[0] == "MAJOR")
    minor = sum(1 for x in F if x[0] == "MINOR")
    judge = sum(1 for x in F if x[0] == "JUDGE")
    verdict = "MAJOR" if major else ("MINOR" if minor else "CLEAN")
    rep = a.report or str(root / ".claude" / "test-logs" / "test-lint.md")
    Path(rep).parent.mkdir(parents=True, exist_ok=True)
    head = f"# test-lint — {pl.story_slug(a.story)}: {len(scs)} scenarios, {len(all_tests)} ExUnit tests, {sum(1 for f in ft)} e2e files"
    order = {"MAJOR": 0, "MINOR": 1, "JUDGE": 2}
    Path(rep).write_text(head + "\n" + "\n".join(f"{s} | {w} | {i} | {x}" for s, w, i, x in sorted(F, key=lambda r: order[r[0]])) + "\n")
    top = [f"{w}: {i}"[:90] for s, w, i, x in F if s == "MAJOR"]
    d = pl.digest(verdict, major, minor, 0, rep, top).replace(f"minor={minor} info=0", f"minor={minor} judge={judge}")
    print(d)
    print(f"LLM_NEEDED: {'yes' if (minor or judge) else 'no'}")
    sys.exit(1 if major else 0)


if __name__ == "__main__":
    main()
