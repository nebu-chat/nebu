#!/usr/bin/env python3
"""commit_summary.py — derives the commit message draft and the pipeline summaries from state log + story (no LLM).

  commit_summary.py --state-file F --story ID --story-file F [--results-dir D] [--epic NAME] [--bug]

Reads the story's `# [ID] …` log lines in the state file, the story frontmatter (title, traceability_id) and the staged files.
Writes <results-dir>/commit-message.txt (default: next to the state file's step-results) and prints:

  SUMMARY:  sprint-status summary (update_sprint_status.py --summary)
  COMPACT:  compact log summary for `pipeline_state.py --commit --log "... committed ✓ (COMPACT)"`
  SUBJECT:  conventional-commit subject draft  <type>(<scope>): <title>
  MESSAGE_FILE: path  → `git commit -F <path>`  (no Co-Authored-By line; edit the file only if the subject is wrong)
  CYCLES / DEFERRED_MINOR / REQ_ID
"""
import argparse
import os
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_lib as pl  # noqa: E402

SCOPES = [(r"^server/lib/nebu/admin/", "admin"), (r"^server/lib/nebu/media", "media"), (r"^server/lib/nebu/matrix", "matrix"),
          (r"^server/lib/nebu/(oauth|oidc|auth)", "auth"), (r"^server/priv/migrations/", "db"), (r"^(deploy|docker)/", "deploy"),
          (r"^e2e/", "e2e"), (r"^docs/", "docs"), (r"^skills/|^\.claude/|^_bmad", "pipeline")]


def story_log(state_text: str, sid: str) -> list:
    """[(step, outcome)] oldest first for `# [sid] <ts> <step> → <outcome>` lines."""
    rows = []
    for line in state_text.splitlines():
        m = re.match(r"^#\s*\[" + re.escape(sid) + r"\]\s+\S+\s+(.+?)\s+(?:→|->)\s+(.*)$", line)
        if m:
            rows.append((m.group(1).strip().lower(), m.group(2)))
    return list(reversed(rows))  # file is newest-first


def last(rows, step_prefix):
    hits = [o for s, o in rows if s.startswith(step_prefix)]
    return hits[-1] if hits else ""


def verdict_of(text: str) -> str:
    m = re.search(r"\b(CLEAN|CRITICAL|HIGH|MAJOR|MINOR|PASS)\b", text)
    return m.group(1) if m else ""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--state-file", required=True); ap.add_argument("--story", required=True); ap.add_argument("--story-file", default="")
    ap.add_argument("--results-dir", default=""); ap.add_argument("--epic", default=""); ap.add_argument("--bug", action="store_true")
    a = ap.parse_args()

    state = pl.read_text(a.state_file)
    rows = story_log(state, a.story)
    fm = pl.frontmatter(pl.read_text(a.story_file)) if a.story_file else {}

    cycles = 0
    for s, o in rows:
        for m in re.finditer(r"cycle\s+(\d+)", o + " " + s):
            cycles = max(cycles, int(m.group(1)))
    ym = re.search(r"^cycle_count:\s*(\d+)", state, re.M)
    if ym:
        cycles = max(cycles, int(ym.group(1)))

    atdd = last(rows, "atdd")
    atdd_ran = bool(atdd) and "skipped" not in atdd
    tr = last(rows, "test-review")
    tr_major = int(m.group(1)) if (m := re.search(r"(\d+)\s*MAJOR", tr)) else 0
    cr = last(rows, "code-review")
    cr_v = verdict_of(cr)
    deferred = 0
    for s, o in rows:
        if s.startswith("code-review") and (m := re.search(r"(\d+)\s*MINOR deferred", o)):
            deferred = int(m.group(1))
    sec = last(rows, "security-review")
    sec_v = verdict_of(sec)
    sec_skipped = "skipped" in sec
    ux = last(rows, "ux-gate")

    parts = []
    if atdd_ran: parts.append("ATDD")
    if tr_major: parts.append(f"test-review {tr_major} MAJOR fixed")
    if cycles: parts.append(f"{cycles} fix cycle{'s' if cycles != 1 else ''}")
    if cr_v:
        parts.append(f"Code {cr_v if cycles == 0 or cr_v == 'CLEAN' else cr_v}")
    if deferred: parts.append(f"{deferred} MINOR deferred")
    if (m := re.search(r"([1-9]\d*)\s*violations?", ux)): parts.append(f"UX {m.group(1)} violation(s) fixed")
    if sec_v: parts.append(f"Kassandra {sec_v}")
    elif sec_skipped: parts.append("no security review")
    compact = "+".join(parts) or "pipeline complete"
    summary = ", ".join(parts) or "pipeline complete"

    # ---- commit message draft
    title = fm.get("title") or a.story
    title = re.split(r"\s+[—–-]\s+", title)[0].strip()
    title = title[:1].lower() + title[1:] if title and not title[:2].isupper() else title
    files = pl.staged_files()
    scope_c = Counter()
    for f in files:
        for pat, sc in SCOPES:
            if re.search(pat, f):
                scope_c[sc] += 1
                break
    scope = scope_c.most_common(1)[0][0] if scope_c else ""
    only_infra = bool(files) and all(re.match(r"^(skills/|\.claude/|_bmad|docs/|deploy/|docker/|Makefile|\.gitlab)", f) for f in files)
    is_bug = a.bug or bool(re.search(r"bug|fix", a.story + " " + a.epic, re.I))
    ctype = "fix" if is_bug else ("chore" if only_infra else "feat")
    subject = f"{ctype}({scope}): {title}" if scope else f"{ctype}: {title}"
    subject = subject[:100]
    req = fm.get("traceability_id", "")
    body = [subject, "", f"Pipeline: {summary}."]
    if deferred:
        body.append(f"{deferred} MINOR findings deferred (see deferred-minor.md in the step results).")
    if req:
        body.append(f"Refs: {req}")
    msg = "\n".join(body) + "\n"

    rdir = Path(a.results_dir) if a.results_dir else Path(a.state_file).parent / "step-results" / a.story
    rdir.mkdir(parents=True, exist_ok=True)
    mf = rdir / "commit-message.txt"
    mf.write_text(msg, encoding="utf-8")

    print(f"SUMMARY: {summary}")
    print(f"COMPACT: {compact}")
    print(f"SUBJECT: {subject}")
    print(f"MESSAGE_FILE: {mf}")
    print(f"CYCLES: {cycles}")
    print(f"DEFERRED_MINOR: {deferred}")
    print(f"REQ_ID: {req or '-'}")


if __name__ == "__main__":
    main()
