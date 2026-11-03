#!/usr/bin/env python3
"""review_prescan.py — deterministic convention checks on the staged diff, run BEFORE the LLM code review.

Hard findings (MAJOR/MINOR) are final: the reviewer copies them into its report without re-checking.
HINT lines are candidates: the reviewer confirms or dismisses each one. Only ADDED lines are scanned, so legacy code never counts.

Hard rules
  MAJOR  migration naming/pairing/contiguity · edit or delete of an existing migration · Code.eval* · binary_to_term without :safe
  MINOR  String.to_atom · IO.inspect / dbg left in lib · skipped/pending test added
Hints   SQL with an interpolated expression (module attributes ignored) · secret-like value interpolated into a Logger call · possible hardcoded secret · spec error codes (ORACLE_FILE) never produced in lib/ ·
         TODO/FIXME added

Usage:
  python3 review_prescan.py [--oracle-file F] [--base REF] [--report PATH]
Output: digest on stdout (+ HINTS=N); full lines in the report. Exit 1 on MAJOR.
(Architecture invariants — Ecto schema, Process.register, :global, public API, Redis/NATS, OIDC env — stay in invariant_check.py,
 which already runs as a SubagentStop hook after nebu-dev-story.)
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_lib as pl  # noqa: E402

MIG_RE = re.compile(r"^server/priv/migrations/(\d{6})_([a-z0-9_]+)\.(up|down)\.sql$")
SQL_WORD = re.compile(r"\b(SELECT\s|INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|WHERE\s|ALTER\s+TABLE|CREATE\s+TABLE)", re.I)
SECRET_INTERP = re.compile(r"#\{[^}]*\b(password|passwd|secret|secret_key|access_key|api_key|token|credential)s?\b[^}]*\}", re.I)
HARDCODED = re.compile(r"\b(password|passwd|secret|api_key|access_key|secret_key)\b\s*(?:=|:|=>)\s*\"[A-Za-z0-9+/_\-=]{12,}\"", re.I)
LOGGER = re.compile(r"\bLogger\.(debug|info|notice|warn|warning|error|critical)\(")


def is_lib(p): return p.startswith("server/lib/") and p.endswith((".ex", ".exs"))
def is_test(p): return p.startswith("server/test/") and p.endswith(".exs")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--oracle-file")
    ap.add_argument("--base")
    ap.add_argument("--report")
    a = ap.parse_args()
    root = pl.repo_root()
    F = []

    # ---- migrations
    st = pl.changed_status(a.base)
    mig_added = [p for s, p in st if s == "A" and p.startswith("server/priv/migrations/")]
    for s, p in st:
        if p.startswith("server/priv/migrations/") and s in ("M", "D", "R"):
            F.append(("MAJOR", p, "an existing (shipped) migration was modified/deleted/renamed", "never edit a shipped migration — add a new one"))
    existing = [Path(x).name for x in pl.git("ls-tree", "-r", "--name-only", a.base or "HEAD", "server/priv/migrations/").stdout.split() if x]
    nums = sorted({int(m.group(1)) for n in existing if (m := re.match(r"(\d{6})_", n))})
    top = nums[-1] if nums else 0
    new_nums = {}
    for p in mig_added:
        m = MIG_RE.match(p)
        if not m:
            F.append(("MAJOR", p, "migration file name does not match NNNNNN_name.up.sql / .down.sql", "rename"))
            continue
        new_nums.setdefault(int(m.group(1)), {"name": m.group(2), "kinds": set()})["kinds"].add(m.group(3))
    for n, d in sorted(new_nums.items()):
        if d["kinds"] != {"up", "down"}:
            F.append(("MAJOR", f"server/priv/migrations/{n:06d}_{d['name']}", f"migration has only {sorted(d['kinds'])} — up and down are both required", "add the missing file"))
    expect = top + 1
    for n in sorted(new_nums):
        if n != expect:
            F.append(("MAJOR", f"server/priv/migrations/{n:06d}_{new_nums[n]['name']}", f"migration number {n:06d} breaks contiguity (expected {expect:06d}, last shipped {top:06d})", "renumber"))
        expect = n + 1

    # ---- added lines
    lines = pl.added_lines(a.base)
    for path, ln, text in lines:
        code = re.sub(r"(?<!#)#(?!\{).*$", "", text) if path.endswith((".ex", ".exs")) else text
        where = f"{path}:{ln}"
        if is_lib(path):
            if re.search(r"\bCode\.(eval_string|eval_quoted|eval_file|compile_string)\b", code):
                F.append(("MAJOR", where, "Code.eval*/compile_string in lib", "remove — never evaluate dynamic code"))
            if "binary_to_term" in code and ":safe" not in code:
                F.append(("MAJOR", where, ":erlang.binary_to_term without [:safe]", "pass [:safe] or use a safe format (Jason)"))
            if SQL_WORD.search(code) and pl.sql_interpolations(code):
                F.append(("HINT", where, "SQL with interpolated expression: " + ", ".join(pl.sql_interpolations(code))[:60], "values must be $1/$2 parameters; only constants/identifiers from code may be interpolated (module attributes are ignored)"))
            if re.search(r"\bString\.to_atom\(", code):
                F.append(("MINOR", where, "String.to_atom/1 (atoms are never garbage collected)", "use String.to_existing_atom/1 or a map lookup"))
            if re.search(r"\bIO\.(inspect|puts)\(|\bdbg\(", code):
                F.append(("MINOR", where, "debug output left in lib", "remove or use Logger"))
            if LOGGER.search(code) and SECRET_INTERP.search(code):
                F.append(("HINT", where, "secret-like value interpolated into a Logger call", "confirm it is not the secret itself (ids are fine)"))
            if HARDCODED.search(code):
                F.append(("HINT", where, "possible hardcoded secret", "confirm it is a test/default value or move to config"))
        if is_test(path):
            if re.search(r"@(module)?tag\s+:(skip|pending)\b|@tag\s+skip:", code):
                F.append(("MINOR", where, "test skipped/pending", "enable the test or document why it stays skipped"))
        if re.search(r"\b(TODO|FIXME|XXX)\b", text) and (is_lib(path) or is_test(path)):
            F.append(("HINT", where, "TODO/FIXME added", "confirm it is tracked or remove it"))

    # ---- spec error codes never produced in lib/
    if a.oracle_file:
        codes = pl.matrix_codes(pl.read_text(a.oracle_file))
        blob = ""
        lib = root / "server" / "lib"
        if lib.is_dir():
            for f in lib.rglob("*.ex"):
                blob += f.read_text(errors="replace")
        for c in codes:
            if c not in blob:
                F.append(("HINT", a.oracle_file, f"spec error code {c} is never produced in server/lib", "check whether this story must return it (missing spec code = MAJOR)"))

    major = sum(1 for x in F if x[0] == "MAJOR")
    minor = sum(1 for x in F if x[0] == "MINOR")
    hints = sum(1 for x in F if x[0] == "HINT")
    verdict = "MAJOR" if major else ("MINOR" if minor else "CLEAN")
    rep = a.report or str(root / ".claude" / "test-logs" / "review-prescan.md")
    Path(rep).parent.mkdir(parents=True, exist_ok=True)
    order = {"MAJOR": 0, "MINOR": 1, "HINT": 2}
    head = f"# review-prescan — {len(lines)} added lines, {len(st)} changed files, last shipped migration {top:06d}"
    Path(rep).write_text(head + "\n" + "\n".join(f"{s} | {w} | {i} | {x}" for s, w, i, x in sorted(F, key=lambda r: order[r[0]])) + "\n")
    topl = [f"{w}: {i}"[:90] for s, w, i, x in F if s == "MAJOR"]
    print(pl.digest(verdict, major, minor, 0, rep, topl).replace(f"minor={minor} info=0", f"minor={minor} hints={hints}"))
    sys.exit(1 if major else 0)


if __name__ == "__main__":
    main()
