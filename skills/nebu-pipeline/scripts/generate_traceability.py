#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# ///
"""
generate_traceability.py — Generate an ISO traceability matrix entry after a story commit.

Reads the committed story file, extracts the traceability_id and Gherkin scenarios,
finds the test files changed in the commit, and appends a YAML entry to the
epic-level traceability matrix.

Usage:
  python3 generate_traceability.py \
    --story docs/stories/<epic>/<slug>.md \
    --commit HEAD \
    --matrix _bmad-output/nebu/epics/<epic>/traceability-matrix.yaml

Bulk mode (migrate legacy stories):
  python3 generate_traceability.py \
    --bulk docs/stories/<epic>/ \
    --matrix _bmad-output/nebu/epics/<epic>/traceability-matrix.yaml

  Scans all *.md files in the directory. For each story with Status: done
  (case-insensitive) and no traceability_id, assigns the next sequential
  REQ-<YYYY>-<NNN> ID (per-year counter, zero-padded 3 digits), injects it
  into the frontmatter, and generates a traceability entry. The commit SHA
  is resolved via `git log -1 --format=%h -- <story_file>`. Stories that are
  not done or already have a traceability_id are skipped.

  Use --dry-run to preview assignments without writing anything.

If the story has no traceability_id (legacy story), a warning is printed and
the script exits 0 without writing — legacy stories are not retroactively traced
(unless --bulk is used).

Output format (appended to the matrix file):

  REQ-2026-042:
    story: docs/stories/device-management/s3-matrix-device-endpoints.md
    commit: abc1234def
    date: 2026-10-23
    gherkin_scenarios: 5
    test_files:
      - server/test/nebu/matrix/device_endpoints_test.exs
    test_count: 12
    status: verified
"""

import argparse
import re
import subprocess
import sys
from datetime import date
from pathlib import Path


def is_done_story(content: str) -> bool:
    """Check if story frontmatter or body has status: done (case-insensitive)."""
    return bool(re.search(r"^[Ss]tatus:\s*done\s*$", content, re.MULTILINE))


def get_last_commit_for_file(path: str) -> str:
    """Get the short SHA of the last commit that touched this file."""
    result = subprocess.run(
        ["git", "log", "-1", "--format=%h", "--", path],
        capture_output=True, text=True, timeout=10,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def next_traceability_id(matrix_path: Path, year: int) -> str:
    """Determine the next REQ-<year>-<NNN> ID from the matrix file."""
    prefix = f"REQ-{year}-"
    max_n = 0
    if matrix_path.exists():
        for m in re.finditer(rf"^{re.escape(prefix)}(\d{{3}}):", matrix_path.read_text(), re.MULTILINE):
            max_n = max(max_n, int(m.group(1)))
    return f"{prefix}{max_n + 1:03d}"


def inject_traceability_id(path: Path, traceability_id: str) -> None:
    """Insert traceability_id into story frontmatter (after 'created:' or at end of frontmatter)."""
    content = path.read_text(encoding="utf-8")
    match = re.match(r"^(---\s*\n)(.*?)(\n---)", content, re.DOTALL)
    if not match:
        return
    fm = match.group(2)
    if "traceability_id:" in fm:
        return
    # Insert after 'created:' line if present, otherwise at end of frontmatter
    lines = fm.splitlines()
    insert_at = len(lines)
    for i, line in enumerate(lines):
        if line.strip().startswith("created:"):
            insert_at = i + 1
            break
    lines.insert(insert_at, f"traceability_id: {traceability_id}")
    new_fm = "\n".join(lines)
    new_content = match.group(1) + new_fm + match.group(3) + content[match.end():]
    path.write_text(new_content, encoding="utf-8")


def bulk_migrate(story_dir: str, matrix_path: Path, dry_run: bool = False) -> None:
    """Assign traceability_ids to all done stories in a directory and generate entries."""
    year = date.today().year
    stories = sorted(Path(story_dir).glob("*.md"))
    migrated = 0
    skipped = 0

    # Collect all stories to migrate first, then assign sequential IDs.
    # In dry-run we simulate the matrix growing; in real run the matrix file
    # is appended to, so next_traceability_id sees previous entries.
    pending: list = []  # (story_path, commit_sha)
    for story_path in stories:
        content = story_path.read_text(encoding="utf-8")
        frontmatter = parse_frontmatter(content)

        # Skip if already has traceability_id
        if frontmatter.get("traceability_id", "").strip():
            skipped += 1
            continue

        # Skip if not done
        if not is_done_story(content):
            skipped += 1
            continue

        # Skip if no frontmatter at all (legacy format without --- block)
        if not re.match(r"^---\s*\n", content):
            skipped += 1
            continue

        commit_sha = get_last_commit_for_file(str(story_path))
        pending.append((story_path, commit_sha))

    # Assign IDs and process
    sim_max = 0
    if matrix_path.exists():
        for m in re.finditer(rf"^REQ-{year}-(\d{{3}}):", matrix_path.read_text(), re.MULTILINE):
            sim_max = max(sim_max, int(m.group(1)))

    for story_path, commit_sha in pending:
        sim_max += 1
        tid = f"REQ-{year}-{sim_max:03d}"

        if dry_run:
            print(f"  [dry-run] {story_path.name} → {tid} (commit: {commit_sha or 'unknown'})")
            migrated += 1
            continue

        # Inject traceability_id into the story file
        inject_traceability_id(story_path, tid)

        # Re-read for scenario counting
        content = story_path.read_text(encoding="utf-8")
        scenario_count = count_gherkin_scenarios(content)

        # Find test files from the commit
        commit_files = get_commit_files(commit_sha) if commit_sha else []
        test_files = filter_test_files(commit_files)
        test_count = count_test_functions(test_files)

        entry = (
            f"{tid}:\n"
            f"  story: {story_path}\n"
            f"  commit: {commit_sha or 'unknown'}\n"
            f"  date: {date.today().isoformat()}\n"
            f"  gherkin_scenarios: {scenario_count}\n"
            f"  test_files:\n"
        )
        if test_files:
            entry += "".join(f"    - {f}\n" for f in test_files)
        else:
            entry += "    []\n"
        entry += f"  test_count: {test_count}\n"
        entry += "  status: verified\n"

        append_entry(matrix_path, entry)
        print(f"  ✓ {story_path.name} → {tid} ({scenario_count} scenarios, {len(test_files)} test files)")
        migrated += 1

    print(f"\nBulk migration {'preview' if dry_run else 'complete'}: {migrated} migrated, {skipped} skipped")
    if not dry_run and migrated > 0:
        print(f"Matrix: {matrix_path}")


def read_story(path: str) -> str:
    p = Path(path)
    if not p.exists():
        print(f"Error: story file not found: {path}", file=sys.stderr)
        sys.exit(1)
    return p.read_text(encoding="utf-8")


def parse_frontmatter(content: str) -> dict:
    match = re.match(r"^---\s*\n(.*?)\n---", content, re.DOTALL)
    if not match:
        return {}
    fields = {}
    for line in match.group(1).splitlines():
        m = re.match(r"^(\w+):\s*(.+)$", line)
        if m:
            fields[m.group(1).strip()] = m.group(2).strip().strip('"')
    return fields


def count_gherkin_scenarios(content: str) -> int:
    """Count Scenario: blocks inside gherkin fenced code blocks."""
    return len(re.findall(r"^\s+Scenario(?: Outline)?:", content, re.MULTILINE))


def count_test_functions(test_files: list) -> int:
    """Count ExUnit test blocks (test "..." do) across test files."""
    total = 0
    for f in test_files:
        p = Path(f)
        if not p.exists():
            continue
        content = p.read_text(encoding="utf-8", errors="replace")
        # Match: test "description" do  or  test "desc", %{...} do
        total += len(re.findall(r'^\s*test\s+"', content, re.MULTILINE))
    return total


def get_commit_files(commit: str) -> list:
    """Get files changed in a commit."""
    result = subprocess.run(
        ["git", "show", "--name-only", "--format=", commit],
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 0:
        print(f"Warning: could not read commit {commit}: {result.stderr.strip()}",
              file=sys.stderr)
        return []
    return [l.strip() for l in result.stdout.splitlines() if l.strip()]


def get_commit_sha(commit: str) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "--short", commit],
        capture_output=True, text=True, timeout=10,
    )
    return result.stdout.strip() if result.returncode == 0 else commit


def filter_test_files(files: list) -> list:
    """Keep only test files (server/test/, e2e/tests/, e2e/features/)."""
    patterns = ("server/test/", "e2e/tests/", "e2e/features/")
    return sorted(f for f in files if f.startswith(patterns))


def entry_exists(matrix_path: Path, traceability_id: str) -> bool:
    if not matrix_path.exists():
        return False
    return bool(re.search(rf"^{re.escape(traceability_id)}:", matrix_path.read_text(), re.MULTILINE))


def append_entry(matrix_path: Path, entry_yaml: str) -> None:
    matrix_path.parent.mkdir(parents=True, exist_ok=True)
    if not matrix_path.exists():
        matrix_path.write_text(
            "# Nebu Traceability Matrix — ISO 9001 / IEC 25010\n"
            "# Generated by generate_traceability.py after each story commit.\n"
            "# One entry per REQ-<YYYY>-<NNN> ID.\n\n",
            encoding="utf-8",
        )
    with matrix_path.open("a", encoding="utf-8") as f:
        f.write(entry_yaml)


def main():
    parser = argparse.ArgumentParser(
        description="Generate ISO traceability matrix entry from a committed story."
    )
    parser.add_argument("--story", help="Path to the story file")
    parser.add_argument("--commit", default="HEAD", help="Commit SHA (default: HEAD)")
    parser.add_argument("--matrix", required=True, help="Path to traceability-matrix.yaml")
    parser.add_argument("--date", default=None, help="Date override (default: today)")
    parser.add_argument("--bulk", metavar="DIR",
                        help="Bulk mode: scan directory for done stories without traceability_id and migrate them")
    parser.add_argument("--dry-run", action="store_true",
                        help="Preview bulk migration without writing files")
    args = parser.parse_args()

    if args.bulk:
        bulk_migrate(args.bulk, Path(args.matrix), dry_run=args.dry_run)
        return

    if not args.story:
        parser.error("--story is required (or use --bulk DIR)")

    content = read_story(args.story)
    frontmatter = parse_frontmatter(content)

    traceability_id = frontmatter.get("traceability_id", "").strip()
    if not traceability_id:
        print(f"ℹ No traceability_id in {args.story} — legacy story, skipping traceability entry.",
              file=sys.stderr)
        sys.exit(0)

    matrix_path = Path(args.matrix)
    if entry_exists(matrix_path, traceability_id):
        print(f"ℹ Traceability entry for {traceability_id} already exists — skipping.")
        sys.exit(0)

    commit_files = get_commit_files(args.commit)
    test_files = filter_test_files(commit_files)
    scenario_count = count_gherkin_scenarios(content)
    test_count = count_test_functions(test_files)
    commit_sha = get_commit_sha(args.commit)
    date_str = args.date or date.today().isoformat()

    entry = (
        f"{traceability_id}:\n"
        f"  story: {args.story}\n"
        f"  commit: {commit_sha}\n"
        f"  date: {date_str}\n"
        f"  gherkin_scenarios: {scenario_count}\n"
        f"  test_files:\n"
    )
    if test_files:
        entry += "".join(f"    - {f}\n" for f in test_files)
    else:
        entry += "    []\n"
    entry += f"  test_count: {test_count}\n"
    entry += "  status: verified\n"

    append_entry(matrix_path, entry)
    print(f"✓ Traceability entry {traceability_id} → {matrix_path}")
    print(f"  scenarios: {scenario_count}, test files: {len(test_files)}, tests: {test_count}")


if __name__ == "__main__":
    main()
