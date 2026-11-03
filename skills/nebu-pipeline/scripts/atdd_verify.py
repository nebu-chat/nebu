#!/usr/bin/env python3
"""atdd_verify.py — deterministic check of the ATDD output (no LLM).

Checks, per Gherkin scenario of the story:
  * covered by a test: ExUnit `@tag ac: "<slug>"` (or the scenario title in a test name) / feature `@ac-<slug>` (or title)
  * no leftover `ATDD-PLACEHOLDER` bodies (agent must have replaced them)
  * test body contains an assertion (assert / refute / assert_receive / assert_raise / ...)
  * RED for the right reason: the focused run must fail — green before implementation = MAJOR, compile/syntax errors = MAJOR,
    placeholder failures = MAJOR, failures in `setup` instead of an assertion = MINOR
Runs only the story's test files (`make test-unit-elixir TEST_ARGS="…"` through test_digest.py's parser).

Usage:
  python3 atdd_verify.py --story STORY.md [--files F ...] [--no-run] [--run-cmd "CMD {args}"] [--report PATH] [--allow-placeholder]
Output: 4-line digest on stdout (VERDICT/COUNTS/REPORT/TOP), full findings in --report (one per line: SEV | where | issue | fix).
Exit: 1 if VERDICT is MAJOR, else 0.
"""
from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_lib as pl  # noqa: E402
import test_digest as td  # noqa: E402

ASSERT_RE = re.compile(r"\b(assert|refute|assert_receive|refute_receive|assert_raise|assert_received|refute_received|assert_in_delta|assert_enqueued|expect|flunk)\b")


def changed_test_files(root: Path) -> list:
    out = pl.git("status", "--porcelain", "-uall").stdout.splitlines()
    files = []
    for line in out:
        path = line[3:].strip().split(" -> ")[-1]
        if (path.startswith("server/test/") and path.endswith(".exs")) or (path.startswith("e2e/") and path.endswith((".feature", ".ts"))):
            files.append(path)
    return files


def parse_exunit(text: str) -> list:
    """[{name, slug, line, body}] — slug from the closest preceding `@tag ac: "…"`."""
    lines = text.splitlines()
    tests, pending = [], None
    for i, l in enumerate(lines):
        m = re.match(r'^\s*@tag\s+ac:\s*"([^"]+)"', l)
        if m:
            pending = m.group(1)
            continue
        m = re.match(r'^(\s*)test\s+"(.*)"(?:,\s*.*)?\s+do\s*$', l)
        if m:
            indent = m.group(1)
            body = []
            for j in range(i + 1, len(lines)):
                if lines[j].rstrip() == indent + "end":
                    break
                body.append(lines[j])
            tests.append({"name": m.group(2), "slug": pending, "line": i + 1, "body": "\n".join(body)})
            pending = None
        elif l.strip() and not l.strip().startswith(("#", "@")):
            pending = None if not re.match(r"^\s*(describe|setup|test)\b", l) else pending
    return tests


def parse_feature(text: str) -> list:
    out, tags = [], []
    for l in text.splitlines():
        s = l.strip()
        if s.startswith("@"):
            tags = s.split()
        m = re.match(r"^(Scenario Outline|Scenario):\s*(.+)$", s)
        if m:
            slugs = [t[4:] for t in tags if t.startswith("@ac-")]
            out.append({"title": m.group(2).strip(), "slug": slugs[0] if slugs else None})
            tags = []
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--story", required=True)
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--no-run", action="store_true")
    ap.add_argument("--run-cmd", help='custom run command; "{args}" is replaced by the test paths relative to server/')
    ap.add_argument("--report")
    ap.add_argument("--allow-placeholder", action="store_true", help="scaffold stage: placeholders are expected")
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()

    root = pl.repo_root()
    text = pl.read_text(a.story)
    scs = pl.scenarios(text)
    fm = pl.frontmatter(text)
    F = []  # findings (sev, where, issue, fix)

    if not scs:
        F.append(("MAJOR", a.story, "no Gherkin scenarios found in the story", "write Scenario: blocks in Acceptance Criteria"))
    cand = a.files if a.files else changed_test_files(root)
    slugs = {s["slug"] for s in scs}
    ex_files, ft_files = {}, {}
    for f in cand:
        p = root / f if not os.path.isabs(f) else Path(f)
        t = pl.read_text(p)
        if not t:
            continue
        if f.endswith(".exs"):
            tests = parse_exunit(t)
            if a.files or any(x["slug"] in slugs for x in tests) or any(sc["title"].lower() in x["name"].lower() for x in tests for sc in scs):
                ex_files[f] = tests
        elif f.endswith(".feature"):
            fs = parse_feature(t)
            if a.files or any(x["slug"] in slugs for x in fs) or any(sc["title"].lower() == x["title"].lower() for x in fs for sc in scs):
                ft_files[f] = fs

    all_tests = [(f, t) for f, ts in ex_files.items() for t in ts]
    covered = {}
    for sc in scs:
        hits = [(f, t["line"]) for f, t in all_tests if t["slug"] == sc["slug"] or sc["title"].lower() in t["name"].lower()]
        hits += [(f, 0) for f, fs in ft_files.items() for x in fs if x["slug"] == sc["slug"] or x["title"].lower() == sc["title"].lower()]
        covered[sc["slug"]] = hits
        if not hits:
            F.append(("MAJOR", a.story, f'scenario without test: "{sc["title"]}"', f'add a test tagged `@tag ac: "{sc["slug"]}"`'))
    known = slugs
    for f, t in all_tests:
        if t["slug"] and t["slug"] not in known:
            F.append(("MINOR", f"{f}:{t['line']}", f'tag ac: "{t["slug"]}" matches no scenario of the story', "rename the tag or add the scenario"))

    n_placeholder = 0
    for f, t in all_tests:
        if PLACEHOLDER in t["body"]:
            n_placeholder += 1
            if not a.allow_placeholder:
                F.append(("MAJOR", f"{f}:{t['line']}", f'test body is still the scaffold placeholder: "{t["name"][:60]}"', "replace with real assertions"))
        elif t["slug"] and not ASSERT_RE.search(t["body"]):
            F.append(("MINOR", f"{f}:{t['line']}", f'test without any assertion: "{t["name"][:60]}"', "assert the observable outcome of the Then step"))

    # ---- run
    run_info = "not run"
    n_tests = n_fail = 0
    if ex_files and not a.no_run:
        rel = [("test/" + f.split("server/test/", 1)[1]) for f in ex_files if f.startswith("server/test/")]
        log = str(root / ".claude" / "test-logs" / "atdd-verify.log")
        Path(log).parent.mkdir(parents=True, exist_ok=True)
        if a.run_cmd:
            cmd = shlex.split(a.run_cmd.replace("{args}", " ".join(rel)))
        else:
            cmd = ["make", "test-unit-elixir", "TEST_ARGS=" + " ".join(rel)]
        try:
            with open(log, "w", errors="replace") as fh:
                rc = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT, timeout=a.timeout, cwd=str(root)).returncode
            res = td.parse(Path(log).read_text(errors="replace").splitlines())
            n_tests, n_fail = res["tests"] or 0, res["failures"] or 0
            run_info = f"rc={rc} tests={res['tests']} failures={res['failures']} log={log}"
            if res["compile"]:
                F.append(("MAJOR", "run", "tests do not compile: " + res["compile"][0].strip()[:140], "fix the compile error; see " + log))
            elif res["tests"] is None:
                F.append(("MAJOR", "run", "no ExUnit summary — test run failed before executing tests", "see " + log))
            else:
                if n_fail == 0 and rc == 0 and not a.allow_placeholder:
                    F.append(("MAJOR", "run", f"all {n_tests} tests are GREEN before implementation", "tests must fail until the story is implemented (assert the new behaviour)"))
                elif n_tests > n_fail:
                    passing = n_tests - n_fail
                    F.append(("MAJOR" if not a.allow_placeholder else "INFO", "run", f"{passing} of {n_tests} tests pass before implementation", "a test that is green without the implementation tests nothing"))
                for fl in res["failed"]:
                    body = "\n".join(fl["body"])
                    if PLACEHOLDER in body and not a.allow_placeholder:
                        continue  # already reported statically
                    if re.search(r"failure on (setup|setup_all)", body):
                        F.append(("MINOR", f"{fl['mod']}", f'red in setup, not in an assertion: "{fl["name"][:60]}"', "fix setup so the failure is the missing behaviour"))
        except subprocess.TimeoutExpired:
            F.append(("MAJOR", "run", f"focused test run timed out after {a.timeout}s", "see log"))
        except FileNotFoundError as exc:
            run_info = f"run skipped: {exc}"
            F.append(("INFO", "run", f"focused run skipped — {exc}", "run `make test-unit-elixir TEST_ARGS=…` manually"))
    elif not ex_files and scs:
        F.append(("INFO", "files", "no ExUnit test files found for this story (feature-only?)", ""))

    major = sum(1 for f in F if f[0] == "MAJOR")
    minor = sum(1 for f in F if f[0] == "MINOR")
    info = sum(1 for f in F if f[0] == "INFO")
    verdict = "MAJOR" if major else ("MINOR" if minor else "CLEAN")
    rep = a.report or str(root / ".claude" / "test-logs" / "atdd-verify.md")
    Path(rep).parent.mkdir(parents=True, exist_ok=True)
    head = f"# atdd-verify — {pl.story_slug(a.story)}: {len(scs)} scenarios, {len(all_tests)} ExUnit tests ({n_placeholder} placeholders), {len(ft_files)} feature files; {run_info}"
    Path(rep).write_text(head + "\n" + "\n".join(f"{s} | {w} | {i} | {x}" for s, w, i, x in F) + "\n")
    top = [f"{w}: {i}"[:90] for s, w, i, x in F if s == "MAJOR"]
    print(pl.digest(verdict, major, minor, info, rep, top))
    sys.exit(1 if major else 0)


PLACEHOLDER = "ATDD-PLACEHOLDER"

if __name__ == "__main__":
    main()
