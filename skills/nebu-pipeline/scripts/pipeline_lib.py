#!/usr/bin/env python3
"""pipeline_lib.py — shared helpers of the nebu-pipeline scripts (story parsing, git, small utilities).

Import from sibling scripts:  sys.path.insert(0, os.path.dirname(__file__)); import pipeline_lib as pl
No third-party dependencies, Python >= 3.9.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path


# ---------------------------------------------------------------- generic

def slugify(text: str, maxlen: int = 70) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if len(s) > maxlen:
        cut = s[:maxlen]
        s = cut[:cut.rfind("-")] if "-" in cut[20:] else cut  # cut at a word boundary
    return s.strip("-") or "scenario"


def camelize(slug: str) -> str:
    return "".join(p.capitalize() for p in re.split(r"[-_]+", slug) if p)


def git(*args: str, cwd: str | None = None) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(["git", *args], capture_output=True, text=True, timeout=60, cwd=cwd)
    except Exception as exc:  # git missing / timeout
        return subprocess.CompletedProcess(args, 1, "", str(exc))


def repo_root() -> Path:
    r = git("rev-parse", "--show-toplevel")
    return Path(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip() else Path.cwd()


def staged_files(status: bool = False) -> list:
    """Staged paths; with status=True a list of (status_letter, path)."""
    out = git("diff", "--staged", "--name-status").stdout.splitlines()
    res = []
    for line in out:
        parts = line.split("\t")
        if len(parts) >= 2:
            res.append((parts[0][0], parts[-1]))
    return res if status else [p for _, p in res]


def read_text(path) -> str:
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


# ---------------------------------------------------------------- story files

def frontmatter(text: str) -> dict:
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    fm = {}
    if m:
        for line in m.group(1).splitlines():
            kv = re.match(r"^([A-Za-z0-9_]+):\s*(.*?)\s*$", line)
            if kv:
                fm[kv.group(1)] = kv.group(2).strip("\"'")
    return fm


def section(text: str, name: str) -> str:
    """Body of the first level-2 section whose heading equals `name` (case-insensitive)."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        m = re.match(r"^(#{1,6})\s+(.+?)\s*$", line)
        if m and m.group(2).lower() == name.lower():
            start, level = i, len(m.group(1))
            break
    if start is None:
        return ""
    end = len(lines)
    for j in range(start + 1, len(lines)):
        m = re.match(r"^(#{1,6})\s+", lines[j])
        if m and len(m.group(1)) <= level:
            end = j
            break
    return "\n".join(lines[start + 1:end])


STEP_RE = re.compile(r"^\s*(Given|When|Then|And|But|\*)\s+(.*\S)\s*$")


def scenarios(text: str) -> list:
    """Gherkin scenarios of a story: [{title, slug, outline, steps:[(keyword, text)], tags}].

    Looks in the sections 'Acceptance Criteria' and 'Acceptance Tests' (fenced ```gherkin blocks or plain text),
    falls back to the whole document.
    """
    body = "\n".join(section(text, n) for n in ("Acceptance Criteria", "Acceptance Tests")).strip() or text
    out, cur, tags = [], None, []
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("@"):
            tags = s.split()
            continue
        m = re.match(r"^(Scenario Outline|Scenario|Example):\s*(.+)$", s)
        if m:
            cur = {"title": m.group(2).strip(), "outline": m.group(1) == "Scenario Outline", "steps": [], "tags": tags}
            cur["slug"] = slugify(cur["title"])
            out.append(cur)
            tags = []
            continue
        if cur is not None:
            sm = STEP_RE.match(line)
            if sm:
                cur["steps"].append((sm.group(1), sm.group(2)))
            elif s.startswith(("Feature:", "Background:", "```")) and not s.startswith("```gherkin"):
                if s.startswith(("Feature:", "Background:")):
                    cur = None
    # unique slugs
    seen: dict = {}
    for sc in out:
        n = seen.get(sc["slug"], 0)
        seen[sc["slug"]] = n + 1
        if n:
            sc["slug"] = f'{sc["slug"]}-{n + 1}'
    return out


def story_slug(path) -> str:
    fm = frontmatter(read_text(path))
    return fm.get("story_id") or Path(path).stem


def matrix_codes(text: str) -> list:
    """Matrix error codes (M_FORBIDDEN, ...) mentioned in `text`, sorted, unique."""
    return sorted(set(re.findall(r"\bM_[A-Z][A-Z_]+\b", text)))


def http_codes(text: str) -> list:
    return sorted(set(re.findall(r"\b(?:HTTP\s*)?([1-5]\d\d)\b", text)))


# ---------------------------------------------------------------- output helpers

def finding(sev: str, where: str, issue: str, fix: str = "") -> str:
    """One report line in the pipeline's finding format."""
    return f"{sev} | {where} | {issue} | {fix}".rstrip(" |") if not fix else f"{sev} | {where} | {issue} | {fix}"


def digest(verdict: str, major: int = 0, minor: int = 0, info: int = 0, report: str = "", top=()) -> str:
    top_s = "; ".join(list(top)[:3]) or "-"
    return f"VERDICT: {verdict}\nCOUNTS: major={major} minor={minor} info={info}\nREPORT: {report}\nTOP: {top_s}"


# ---------------------------------------------------------------- diffs

def added_lines(base: str | None = None) -> list:
    """Added lines of the staged diff (or of `git diff <base>`): [(path, lineno, text)]. Binary/deleted files skipped."""
    args = ["diff", "--no-color", "-U0"] + ([base] if base else ["--staged"])
    out = git(*args).stdout.splitlines()
    res, path, ln = [], None, 0
    for line in out:
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", line)
            ln = int(m.group(1)) if m else 0
        elif line.startswith("+") and not line.startswith("+++") and path:
            res.append((path, ln, line[1:]))
            ln += 1
    return res


def changed_status(base: str | None = None) -> list:
    """[(status_letter, path)] of the staged diff (or `git diff <base>`)."""
    args = ["diff", "--name-status"] + ([base] if base else ["--staged"])
    res = []
    for line in git(*args).stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            res.append((parts[0][0], parts[-1]))
    return res


def sql_interpolations(code: str) -> list:
    """Interpolated expressions of a line, minus module attributes (`#{@sql_fragment}` are compile-time constants)."""
    return [e.strip() for e in re.findall(r"#\{([^}]*)\}", code) if not e.strip().startswith("@")]


# ---------------------------------------------------------------- digests

def parse_digest(text: str) -> dict:
    """Parse an agent's 4-line digest (VERDICT/COUNTS/REPORT/TOP, plus dev: TESTS/FILES/BLOCKER).

    Returns {'verdict': 'MINOR'|None, 'major': int, 'minor': int, 'info': int, 'report': str, 'top': str, 'raw': {KEY: value}}.
    Tolerant: case-insensitive keys, markdown bold/backticks around keys, extra prose lines are ignored.
    """
    raw: dict = {}
    for line in text.splitlines():
        m = re.match(r"^\W*([A-Za-z_]+)\W*:\s*(.*?)\s*$", line)
        if m and m.group(1).upper() in {"VERDICT", "COUNTS", "REPORT", "TOP", "TESTS", "FILES", "BLOCKER"}:
            raw.setdefault(m.group(1).upper(), m.group(2).strip("` *"))
    verdict = raw.get("VERDICT", "")
    vm = re.match(r"^([A-Z]+)", verdict.upper())
    counts = {k: int(v) for k, v in re.findall(r"(major|minor|info)\s*=\s*(\d+)", raw.get("COUNTS", ""), re.I) for k in [k.lower()]}
    return {"verdict": vm.group(1) if vm else None,
            "major": counts.get("major", 0), "minor": counts.get("minor", 0), "info": counts.get("info", 0),
            "report": raw.get("REPORT", ""), "top": raw.get("TOP", "-"), "raw": raw}
