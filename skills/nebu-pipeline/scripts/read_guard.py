#!/usr/bin/env python3
"""read_guard.py — PreToolUse hook: keeps huge files out of the agent context.

Hook mode (default, reads the hook payload from stdin):
  * `Read` of a file >= NEBU_READ_MAX_KB (default 40) without `limit` (or limit > 600 lines) is DENIED with a hint:
    Grep for the symbol, then Read with offset/limit. Images/PDFs and curated documents (*.md/yaml/toml under docs/, _bmad*, skills/, .claude/) are exempt.
  * `Bash` that is a plain `cat <file>` of such a file (no pipe/redirect) is denied the same way.
  * Every denial is appended to <root>/.claude/metrics/guard.log (JSON lines) so the effect can be measured.
  * Fails open: any error, unknown payload or missing file → allow silently (exit 0, no output).
  * NEBU_READ_GUARD=off disables it.

Summary mode:  read_guard.py --summary [--file guard.log]   → denials per agent and per file.
"""
import json
import os
import re
import sys
import time
from collections import Counter
from pathlib import Path

EXEMPT_SUFFIX = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf", ".ipynb"}
DOC_SUFFIX = {".md", ".yaml", ".yml", ".toml"}
DOC_DIRS = ("docs/", "_bmad/", "_bmad-output/", "skills/", ".claude/")
MAX_LIMIT = 600


def root_dir(payload) -> Path:
    return Path(os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or os.getcwd())


def over_limit(path: Path, root: Path, max_kb: int):
    try:
        if not path.is_file():
            return None
        size = path.stat().st_size
    except OSError:
        return None
    if size < max_kb * 1024 or path.suffix.lower() in EXEMPT_SUFFIX:
        return None
    try:
        rel = path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        rel = path.as_posix()
    if path.suffix.lower() in DOC_SUFFIX and rel.startswith(DOC_DIRS):
        return None
    return size


def deny(reason: str):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}))


def log_denial(root: Path, payload, path: Path, size: int):
    try:
        d = root / ".claude" / "metrics"
        d.mkdir(parents=True, exist_ok=True)
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "agent": payload.get("agent_type") or "main",
               "tool": payload.get("tool_name"), "path": str(path), "kb": size // 1024}
        with open(d / "guard.log", "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
    except OSError:
        pass


def hint(path: Path, size: int, bash: bool = False) -> str:
    kb, tok = size // 1024, size // 4000
    kind = "log" if path.suffix in (".log", ".out", ".txt") else "file"
    how = ("For logs use `grep -n '<pattern>' <file> | head -n 40` or `tail -n 40 <file>`; for test runs use `python3 skills/nebu-pipeline/scripts/test_digest.py -- <cmd>`."
           if kind == "log" else
           "Locate the part with Grep (symbol/heading), then Read with `offset` and `limit` (at most ~250 lines).")
    tail = "" if bash else f" Passing `limit` (<= {MAX_LIMIT}) lets the Read through."
    return f"read-guard: {path.name} is {kb} KB (~{tok}k tokens). {how}{tail}"


def hook():
    if os.environ.get("NEBU_READ_GUARD", "").lower() == "off":
        return
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    max_kb = int(os.environ.get("NEBU_READ_MAX_KB", "40") or 40)
    root = root_dir(payload)
    tool, inp = payload.get("tool_name"), payload.get("tool_input") or {}
    target = None
    if tool == "Read":
        fp = inp.get("file_path")
        lim = inp.get("limit")
        if not fp or (isinstance(lim, int) and 0 < lim <= MAX_LIMIT):
            return
        target = Path(fp) if os.path.isabs(fp) else root / fp
    elif tool == "Bash":
        cmd = (inp.get("command") or "").strip()
        cmd = re.sub(r"^(rtk\s+)", "", cmd)
        while re.match(r"^cd\s[^;&|]*&&", cmd):
            cmd = re.sub(r"^cd\s[^;&|]*&&\s*", "", cmd, count=1)
        m = re.fullmatch(r"cat\s+([^\s|;&<>$`]+)", cmd)
        if not m:
            return
        p = m.group(1).strip("'\"")
        target = Path(p) if os.path.isabs(p) else Path(payload.get("cwd") or root) / p
    else:
        return
    size = over_limit(target, root, max_kb)
    if size is None:
        return
    log_denial(root, payload, target, size)
    deny(hint(target, size, bash=(tool == "Bash")))


def summary(path: str):
    p = Path(path)
    if not p.exists():
        print(f"no guard log at {p}")
        return
    rows = [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
    print(f"{len(rows)} denials, ~{sum(r['kb'] for r in rows) // 4}k tokens kept out of the context (upper bound: the file would have been read once)")
    for title, key in (("by agent", "agent"), ("by file", "path")):
        print(f"-- {title}")
        for k, n in Counter(r[key] for r in rows).most_common(8):
            print(f"  {n:3d}  {k}")


if __name__ == "__main__":
    if "--summary" in sys.argv:
        f = sys.argv[sys.argv.index("--file") + 1] if "--file" in sys.argv else os.path.join(os.environ.get("CLAUDE_PROJECT_DIR", "."), ".claude", "metrics", "guard.log")
        summary(f)
    else:
        try:
            hook()
        except Exception:
            pass
