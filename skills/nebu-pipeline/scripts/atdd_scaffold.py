#!/usr/bin/env python3
"""atdd_scaffold.py — turn the story's Gherkin scenarios into a red ATDD scaffold (no LLM).

Writes
  * an ExUnit file: one `test "Scenario: <title>"` per scenario, tagged `@tag ac: "<slug>"`, body = a placeholder
    `flunk("ATDD-PLACEHOLDER: …")` with the Given/When/Then steps as comments (the ATDD agent replaces the bodies);
  * for ui stories (frontmatter `ui: true`) or with --feature-dir: a `.feature` file with the Gherkin copied verbatim,
    every scenario tagged `@<REQ-ID> @ac-<slug>`.
Existing files are never overwritten: with --update only scenarios whose slug is not yet tagged are appended.

Usage:
  python3 atdd_scaffold.py --story docs/stories/<epic>/<slug>.md [--domain media] [--test-file PATH] [--module Nebu.Media.XTest]
                           [--feature-dir e2e/features/<dir>] [--async] [--update] [--dry-run]
  python3 atdd_scaffold.py --bug "short description" [--domain media]      # one regression test, tag ac: "bug-<slug>"

Output: JSON on stdout {"test_file", "feature_file", "scenarios": N, "added": [...], "skipped": [...]}.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_lib as pl  # noqa: E402

PLACEHOLDER = "ATDD-PLACEHOLDER"


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("#{", "\\#{")


def infer_domain(root: Path, slug: str, epic: str) -> str:
    base = root / "server" / "test" / "nebu"
    dirs = sorted(p.name for p in base.iterdir() if p.is_dir()) if base.is_dir() else []
    tokens = re.split(r"[-_]+", slug) + re.split(r"[-_]+", epic or "")
    for tok in tokens:
        if tok in dirs:
            return tok
    return "acceptance"


def test_block(sc: dict) -> str:
    steps = "\n".join(f"  #   {k} {t}" for k, t in sc["steps"])
    outline = "  # (Scenario Outline — cover every Examples row)\n" if sc.get("outline") else ""
    return (
        f"  # Scenario: {sc['title']}\n{outline}"
        f"{steps}\n"
        f'  @tag ac: "{sc["slug"]}"\n'
        f'  test "Scenario: {esc(sc["title"])}" do\n'
        f'    flunk("{PLACEHOLDER}: {esc(sc["title"])}")\n'
        f"  end\n"
    )


def module_text(module: str, story: str, req: str, title: str, blocks: list, async_: bool) -> str:
    head = (
        f"defmodule {module} do\n"
        f'  @moduledoc """\n'
        f"  ATDD for story `{story}`{f' ({req})' if req else ''} — {title}.\n\n"
        f'  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"`. Red until the story is implemented.\n'
        f'  """\n'
        f"  use ExUnit.Case, async: {'true' if async_ else 'false'}\n\n"
    )
    return head + "\n".join(blocks) + "end\n"


def feature_text(title: str, req: str, scs: list, raw_story: str) -> str:
    lines = [f"Feature: {title}", ""]
    for sc in scs:
        tags = f"@{req} " if req else ""
        lines.append(f"  {tags}@ac-{sc['slug']}")
        lines.append(f"  {'Scenario Outline' if sc.get('outline') else 'Scenario'}: {sc['title']}")
        for k, t in sc["steps"]:
            lines.append(f"    {k} {t}")
        lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--story")
    ap.add_argument("--bug")
    ap.add_argument("--domain")
    ap.add_argument("--test-file")
    ap.add_argument("--module")
    ap.add_argument("--feature-dir")
    ap.add_argument("--async", dest="async_", action="store_true")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if not a.story and not a.bug:
        ap.error("--story or --bug required")

    root = pl.repo_root()
    if a.story:
        text = pl.read_text(a.story)
        if not text:
            print(json.dumps({"error": f"story not found: {a.story}"}))
            sys.exit(1)
        fm = pl.frontmatter(text)
        slug = pl.story_slug(a.story)
        title = fm.get("title") or slug
        req = fm.get("traceability_id", "")
        scs = pl.scenarios(text)
        want_feature = fm.get("ui", "").lower() == "true" or bool(a.feature_dir)
        epic = fm.get("epic", "")
    else:
        slug = "bug-" + pl.slugify(a.bug, 40)
        title, req, epic = a.bug, "", ""
        scs = [{"title": a.bug, "slug": slug, "steps": [("Given", "the bug as reported"), ("When", "the failing action is repeated"), ("Then", "the correct behaviour is observed")], "outline": False, "tags": []}]
        want_feature = False
    if not scs:
        print(json.dumps({"error": "no Gherkin scenarios found in the story (expected 'Scenario:' lines in Acceptance Criteria)"}))
        sys.exit(1)

    domain = a.domain or infer_domain(root, slug, epic)
    test_file = Path(a.test_file) if a.test_file else root / "server" / "test" / "nebu" / domain / f"{slug.replace('-', '_')}_test.exs"
    module = a.module or f"Nebu.{pl.camelize(domain)}.{pl.camelize(slug)}Test"

    added, skipped = [], []
    if test_file.exists():
        if not a.update:
            print(json.dumps({"error": f"{test_file} exists — use --update to append missing scenarios", "test_file": str(test_file)}))
            sys.exit(1)
        existing = test_file.read_text()
        have = set(re.findall(r'@tag\s+ac:\s*"([^"]+)"', existing))
        blocks = []
        for sc in scs:
            (skipped if sc["slug"] in have else added).append(sc["slug"])
            if sc["slug"] not in have:
                blocks.append(test_block(sc))
        new = existing.rstrip()
        assert new.endswith("end"), "unexpected ExUnit file shape (last line is not `end`)"
        new = new[:-3].rstrip() + "\n\n" + "\n".join(blocks) + "end\n" if blocks else existing
    else:
        added = [sc["slug"] for sc in scs]
        new = module_text(module, slug, req, title, [test_block(sc) for sc in scs], a.async_)

    result = {"test_file": str(test_file), "module": module, "scenarios": len(scs), "added": added, "skipped": skipped, "feature_file": None}
    if not a.dry_run:
        if added:
            test_file.parent.mkdir(parents=True, exist_ok=True)
            test_file.write_text(new)
    if want_feature:
        fdir = Path(a.feature_dir) if a.feature_dir else root / "e2e" / "features" / (epic or "acceptance")
        ff = fdir / f"{slug}.feature"
        result["feature_file"] = str(ff)
        if not ff.exists() and not a.dry_run:
            ff.parent.mkdir(parents=True, exist_ok=True)
            ff.write_text(feature_text(title, req, scs, text))
        elif ff.exists():
            result["feature_file_note"] = "exists — left untouched"
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
