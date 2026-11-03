#!/usr/bin/env python3
"""pipeline_env.py — resolves the nebu-pipeline path variables (no LLM, no hand-built paths).

  pipeline_env.py [--epic NAME] [--story ID] [--mkdir] [--json]

Named epic (--epic NAME):  everything under _bmad-output/nebu/epics/NAME/ ; STORY_DIR = docs/stories/NAME/
Legacy numbered epic (story id like 14-4, no --epic): _bmad-output/nebu/... + docs/stories/mvp/epic-N/ | phase2/

Output: KEY=value lines (default) or one JSON object. With --story also RESULTS (= STEP_RESULTS_DIR/ID) and STORY_FILE
(first story file in STORY_DIR whose name/frontmatter id matches; empty if none). --mkdir creates STATE_FILE's dir, STEP_RESULTS_DIR (and RESULTS).
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_lib as pl  # noqa: E402


def resolve(epic: str | None, story: str | None, root: Path) -> dict:
    if epic:
        base = f"_bmad-output/nebu/epics/{epic}"
        env = {"EPIC": epic, "STATE_FILE": f"{base}/pipeline-state.yaml", "STEP_RESULTS_DIR": f"{base}/step-results/",
               "SPRINT_STATUS": f"{base}/sprint-status.yaml", "STORY_DIR": f"docs/stories/{epic}/",
               "TRACEABILITY_MATRIX": f"{base}/traceability-matrix.yaml"}
    else:
        n = None
        if story:
            m = re.match(r"^(\d+)", story)
            n = m.group(1) if m else None
        sdir = "docs/stories/phase2/"
        if n and (root / f"docs/stories/mvp/epic-{n}").is_dir():
            sdir = f"docs/stories/mvp/epic-{n}/"
        elif n and not (root / "docs/stories/phase2").is_dir():
            sdir = f"docs/stories/mvp/epic-{n}/"
        env = {"EPIC": f"epic-{n}" if n else "", "STATE_FILE": "_bmad-output/nebu/pipeline-state.yaml",
               "STEP_RESULTS_DIR": "_bmad-output/nebu/step-results/",
               "SPRINT_STATUS": "_bmad-output/implementation-artifacts/sprint-status.yaml", "STORY_DIR": sdir,
               "TRACEABILITY_MATRIX": "_bmad-output/nebu/traceability-matrix.yaml"}
    if story:
        env["STORY_ID"] = story
        env["RESULTS"] = env["STEP_RESULTS_DIR"].rstrip("/") + f"/{story}"
        env["STORY_FILE"] = find_story(root / env["STORY_DIR"], story, root)
    return env


def find_story(sdir: Path, story: str, root: Path) -> str:
    if not sdir.is_dir():
        return ""
    cands = []
    for f in sorted(sdir.glob("*.md")):
        fm = pl.frontmatter(pl.read_text(f)[:2000])
        sid = fm.get("story_id") or fm.get("id") or ""
        if f.stem == story or sid == story or f.stem.startswith(story + "-") or f.stem.startswith(story + "_"):
            cands.append(f)
    return str(cands[0].relative_to(root)) if cands else ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--epic"); ap.add_argument("--story"); ap.add_argument("--mkdir", action="store_true"); ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    root = pl.repo_root()
    env = resolve(a.epic, a.story, root)
    if a.mkdir:
        (root / env["STATE_FILE"]).parent.mkdir(parents=True, exist_ok=True)
        (root / env["STEP_RESULTS_DIR"]).mkdir(parents=True, exist_ok=True)
        if "RESULTS" in env:
            (root / env["RESULTS"]).mkdir(parents=True, exist_ok=True)
    if a.json:
        print(json.dumps(env, indent=1))
    else:
        for k, v in env.items():
            print(f"{k}={v}")


if __name__ == "__main__":
    main()
