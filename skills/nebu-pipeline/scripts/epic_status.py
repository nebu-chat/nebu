#!/usr/bin/env python3
"""epic_status.py — epic completeness, next open story and epic diff base, deterministically (no LLM).

  epic_status.py --epic NAME [--story-dir D]            named epic: story files in docs/stories/NAME/ (frontmatter `status:` or `Status:` line)
  epic_status.py --legacy N [--sprint FILE]             numbered epic N: keys `N-M-…` of sprint-status.yaml development_status

Output:
  EPIC / STORIES total=N done=N open=N / OPEN: slugs / NEXT: slug|- / COMPLETE: yes|no / BASE: <sha>|unclear / BASE_SOURCE: …
Finished statuses: done, superseded, cancelled, wontfix. Files without a status (reports, notes) are ignored.
BASE (named epic): parent of the first commit that added a file under the epic's story dir; fallback: unclear → ask the user.
"""
import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_lib as pl  # noqa: E402

FINISHED = {"done", "superseded", "cancelled", "canceled", "wontfix", "obsolete"}


def status_of(path: Path) -> str:
    text = pl.read_text(path)
    st = pl.frontmatter(text[:3000]).get("status", "")
    if not st:
        m = re.search(r"^\**Status:?\**:?\s*([A-Za-z-]+)", text[:4000], re.M | re.I)
        st = m.group(1) if m else ""
    return st.strip().lower()


def named(epic: str, sdir: str, root: Path) -> dict:
    d = root / (sdir or f"docs/stories/{epic}")
    sprint = pl.read_text(root / f"_bmad-output/nebu/epics/{epic}/sprint-status.yaml")
    sprint_done = set(re.findall(r"^\s+([\w.-]+):\s*done\s*$", sprint, re.M))
    rows = []
    for f in sorted(d.glob("*.md")):
        if f.name.startswith(("epic-", "retro")):
            continue
        st = status_of(f)
        if st:
            rows.append((f.stem, "done" if f.stem in sprint_done else st))
    base, src = "unclear", "no story commit found"
    r = pl.git("log", "--diff-filter=A", "--format=%H", "--reverse", "--", str(d.relative_to(root)))
    first = r.stdout.split()[0] if r.stdout.split() else ""
    if first:
        p = pl.git("rev-parse", first + "^")
        if p.returncode == 0:
            base, src = p.stdout.strip(), "parent of the first commit that added a story file"
    return {"rows": rows, "base": base, "src": src}


def legacy(n: str, sprint: str, root: Path) -> dict:
    text = pl.read_text(root / sprint)
    rows = []
    for m in re.finditer(r"^\s{2}(" + re.escape(n) + r"-[\w.-]+):\s*([\w-]+)", text, re.M):
        slug, st = m.group(1), m.group(2).lower()
        if "retrospective" in slug:
            continue
        rows.append((slug, "done" if st == "done" else st))
    base, src = "unclear", "ask the user"
    prev = int(n) - 1 if n.isdigit() else None
    if prev:
        r = pl.git("log", "--grep", f"epic-{prev}-retrospective\\|retrospektive", "--format=%H", "-1")
        if r.stdout.strip():
            base, src = r.stdout.strip(), f"epic-{prev} retrospective commit"
    return {"rows": rows, "base": base, "src": src}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--epic"); ap.add_argument("--legacy"); ap.add_argument("--story-dir", default="")
    ap.add_argument("--sprint", default="_bmad-output/implementation-artifacts/sprint-status.yaml")
    a = ap.parse_args()
    root = pl.repo_root()
    if a.epic:
        r, name = named(a.epic, a.story_dir, root), a.epic
    elif a.legacy:
        r, name = legacy(a.legacy, a.sprint, root), f"epic-{a.legacy}"
    else:
        ap.error("--epic or --legacy required")
    rows = r["rows"]
    open_ = [s for s, st in rows if st not in FINISHED]
    print(f"EPIC: {name}")
    print(f"STORIES: total={len(rows)} done={len(rows) - len(open_)} open={len(open_)}")
    print(f"OPEN: {', '.join(open_) or '-'}")
    print(f"NEXT: {open_[0] if open_ else '-'}")
    print(f"COMPLETE: {'yes' if rows and not open_ else 'no'}")
    print(f"BASE: {r['base']}")
    print(f"BASE_SOURCE: {r['src']}")


if __name__ == "__main__":
    main()
