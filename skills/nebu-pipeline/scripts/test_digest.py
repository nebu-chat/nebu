#!/usr/bin/env python3
"""test_digest.py — run a (test) command, keep the full output on disk, print only a digest.

Why: raw ExUnit / `make test-*` output (dots, warnings, stack traces) lands in the agent context and is re-read on
every following turn. The digest has the counts, each failure's name + location + the first lines of its body,
warnings and the first compile error. Exit code = exit code of the command (never of this wrapper).

Usage:
  python3 test_digest.py [--log FILE] [--max-failures N] [--lines N] [--timeout SEC] -- <command ...>
  python3 test_digest.py --parse FILE            # digest an existing log instead of running something
  python3 test_digest.py --baseline BASE.log -- make test-integration   # lists only failures that are new vs. the baseline log

Examples:
  python3 skills/nebu-pipeline/scripts/test_digest.py -- make test-unit-elixir
  python3 skills/nebu-pipeline/scripts/test_digest.py -- make test-unit-elixir TEST_ARGS="test/nebu/foo_test.exs:42"
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
FAIL_RE = re.compile(r"^\s{1,4}(\d+)\) (test|doctest|property) (.*) \((.*)\)\s*$")
SUMMARY_RE = re.compile(r"^(?:(\d+) doctests?, )?(?:(\d+) propert(?:y|ies), )?(\d+) tests?, (\d+) failures?(?:, (\d+) excluded)?(?:, (\d+) skipped)?")
TIME_RE = re.compile(r"^Finished in ([0-9.]+) seconds")
WARN_RE = re.compile(r"^\s*warning: (.*)")
COMPILE_RE = re.compile(r"\*\* \((CompileError|SyntaxError|TokenMissingError|Mix\.Error)\)|^\s*error: ")


def parse(lines):
    lines = [ANSI.sub("", l.rstrip("\n")) for l in lines]
    res = {"tests": None, "failures": None, "excluded": 0, "skipped": 0, "time": None, "failed": [], "warnings": [], "compile": None}
    cur = None
    seen_run = False
    for i, l in enumerate(lines):
        m = FAIL_RE.match(l)
        if m:
            cur = {"n": int(m.group(1)), "name": f"{m.group(2)} {m.group(3)}", "mod": m.group(4), "body": []}
            res["failed"].append(cur)
            continue
        sm = SUMMARY_RE.match(l)
        if sm:
            res["tests"], res["failures"] = int(sm.group(3)), int(sm.group(4))
            res["excluded"], res["skipped"] = int(sm.group(5) or 0), int(sm.group(6) or 0)
            cur = None
            continue
        tm = TIME_RE.match(l)
        if tm:
            res["time"] = float(tm.group(1))
            cur = None
            continue
        wm = WARN_RE.match(l)
        if wm and len(res["warnings"]) < 50:
            ctx = next((x.strip() for x in lines[i + 1:i + 6] if re.search(r"\.exs?:\d+", x)), "")
            res["warnings"].append(f"{wm.group(1)[:110]} @ {ctx[:90]}")
        if l.startswith("Running ExUnit"):
            seen_run = True
        if res["compile"] is None and not seen_run and not res["failed"] and COMPILE_RE.search(l):
            res["compile"] = [x for x in lines[i:i + 8] if x.strip()][:8]
        if cur is not None:
            if l.startswith("Finished in") or l.startswith("Randomized with seed"):
                cur = None
            else:
                cur["body"].append(l)
    return res


def render(res, rc, log, max_failures, nlines):
    out = []
    t = f"tests={res['tests']} failures={res['failures']}" if res["tests"] is not None else "tests=? (no ExUnit summary found)"
    extra = []
    if res["excluded"]:
        extra.append(f"excluded={res['excluded']}")
    if res["skipped"]:
        extra.append(f"skipped={res['skipped']}")
    if res["time"] is not None:
        extra.append(f"time={res['time']}s")
    out.append(f"EXIT={rc} {t} {' '.join(extra)} log={log}".replace("  ", " "))
    for f in res["failed"][:max_failures]:
        body = [b for b in f["body"] if b.strip()]
        loc = next((b.strip() for b in body if re.search(r"\.exs?:\d+", b)), "")
        rest = [b for b in body if b.strip() != loc][:nlines]
        out.append(f"FAIL {f['n']}) {f['name']} ({f['mod']}) {loc}")
        out.extend("    " + r.strip()[:200] for r in rest)
    if len(res["failed"]) > max_failures:
        out.append(f"... {len(res['failed']) - max_failures} more failures (see log)")
    if res["warnings"]:
        out.append(f"WARNINGS: {len(res['warnings'])}")
        out.extend("  " + w for w in res["warnings"][:3])
    if res["compile"]:
        out.append("COMPILE/ERROR:")
        out.extend("  " + c[:200] for c in res["compile"])
    if rc != 0 and not res["failed"] and not res["compile"] and res["tests"] is None:
        out.append("(no parsable test output — last lines of the log follow)")
    return out


def compare_baseline(res, base_lines):
    """Failure-set diff against a baseline log: keeps only NEW failures in res['failed'] and returns summary info."""
    base = parse(base_lines)
    key = lambda f: (f["name"], f["mod"])
    bset = {key(f) for f in base["failed"]}
    cur = {key(f) for f in res["failed"]}
    new = [f for f in res["failed"] if key(f) not in bset]
    info = {"new": len(new), "fixed": len(bset - cur), "same": len(cur & bset), "base_failures": base["failures"], "base_tests": base["tests"]}
    res["failed"] = new
    return info


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log")
    ap.add_argument("--max-failures", type=int, default=8)
    ap.add_argument("--lines", type=int, default=12)
    ap.add_argument("--timeout", type=int, default=0)
    ap.add_argument("--parse", help="digest an existing log file")
    ap.add_argument("--baseline", help="baseline log: list only failures that are NOT in it (pre-existing failures are counted, not listed)")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()

    if a.parse:
        lines = Path(a.parse).read_text(errors="replace").splitlines()
        res, rc, log = parse(lines), "-", a.parse
    else:
        cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
        if not cmd:
            ap.error("no command given (use: -- <command>)")
        log = a.log or os.path.join(os.environ.get("CLAUDE_PROJECT_DIR", "."), ".claude", "test-logs", f"run-{int(time.time())}.log")
        Path(log).parent.mkdir(parents=True, exist_ok=True)
        try:
            with open(log, "w", encoding="utf-8", errors="replace") as fh:
                p = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT, timeout=a.timeout or None)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            rc = 124
        except FileNotFoundError as exc:
            print(f"EXIT=127 command not found: {exc}")
            sys.exit(127)
        lines = Path(log).read_text(errors="replace").splitlines()
        res = parse(lines)

    cmp_info = None
    if a.baseline and Path(a.baseline).exists():
        cmp_info = compare_baseline(res, Path(a.baseline).read_text(errors="replace").splitlines())
    out = render(res, rc, log, a.max_failures, a.lines)
    if cmp_info:
        out.insert(1, f"VS_BASELINE: new={cmp_info['new']} fixed={cmp_info['fixed']} same(pre-existing)={cmp_info['same']} "
                      f"(baseline: {cmp_info['base_failures']} failures of {cmp_info['base_tests']} tests) — only NEW failures are listed below")
    if rc != 0 and res["tests"] is None and not res["compile"]:
        out.extend("  | " + ANSI.sub("", l)[:200] for l in lines[-15:])
    print("\n".join(out))
    sys.exit(rc if isinstance(rc, int) else 0)


if __name__ == "__main__":
    main()
