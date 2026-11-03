#!/usr/bin/env python3
"""
pipeline_gates.py — deterministische Helfer für die token-sparenden Gates der nebu-pipeline.

Unterbefehle (alle geben eine kurze, maschinenlesbare Antwort auf stdout aus, Exit 0):

  baseline-lookup --dest LOG [--max-age-h 72]
      Baseline-Integrationslog des aktuellen HEAD wiederverwenden statt neu zu testen.
      Antwort: "HIT <sha>" (Log nach --dest kopiert) oder "MISS <grund>".
      Nur bei sauberem Code-Stand (kein uncommitted Änderungen in server/, proto/, ...).

  baseline-store --src LOG
      Integrationslog als Baseline für den aktuellen HEAD ablegen (nach dem Commit einer Story,
      deren letzter voller Integrationslauf auf dem finalen Code lief).

  review-mark --file PATH
      Tree-Hash des gerade gereviewten Index (git write-tree) in PATH merken.

  review-delta --mark PATH [--max-lines 1500]
      Änderungen seit der letzten Review. Antwort: erste Zeile "DELTA" (danach der Diff),
      "EMPTY" (nichts geändert) oder "FULL" (keine Marke / Delta zu groß -> vollständig reviewen).

  arc42-relevant --story FILE
      Ist ein Arc42-Update nötig? Antwort: JSON {"run": bool, "reason": str}.
      Frontmatter "arc42: required|skip" der Story hat Vorrang; sonst Heuristik über die
      gestagten Dateien (Migrationen, proto, docker, deploy, Router, ADRs, neue Domänen-Ordner).

  decide --step STEP --digest FILE|- --cycle N --story ID [--max-minor 1] [--no-copy]
      Entscheidungslogik der Gates als Skript (kein LLM-Denken im Orchestrator). STEP: test-review | dev-story | code-review |
      ux-gate | security-review | epic-security | oracle. Antwort (key: value, eine Zeile je Feld):
        ACTION    NEXT | CYCLE | DEFER_MINOR | ASK_USER | STOP
        STATE     fertige Argumente für pipeline_state.py (ohne --file) — bei ASK_USER: der Fall "weitermachen"
        STATE_FIX / STATE_ACCEPT   (nur ASK_USER bei code-review) Argumente für "fix" bzw. "accept"
        MESSAGE   Statuszeile bzw. Frage an den User (inkl. TOP + REPORT)
        COPIED    (nur DEFER_MINOR) Pfad der deferred-minor.md, wird vom Skript selbst geschrieben

Cache-Ort für die Baseline: <repo>/.claude/pipeline-cache/baseline/<sha>.log (gitignored, pro Checkout).
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_lib as pl  # noqa: E402

CODE_PATHS = ["server", "proto", "docker", "deploy", "core", "e2e", "docker-compose.yml", "Makefile"]
ARC42_PATTERNS = [
    r"^server/priv/migrations/",
    r"^proto/",
    r"^docker/",
    r"^deploy/",
    r"^docker-compose[^/]*\.yml$",
    r"^\.gitlab-ci\.yml$",
    r"^server/config/",
    r"^server/lib/.*router[^/]*\.ex$",
    r"^docs/architecture/adr/",
]


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


def repo_root() -> Path:
    r = git("rev-parse", "--show-toplevel")
    return Path(r.stdout.strip()) if r.returncode == 0 else Path.cwd()


def head_sha() -> str:
    r = git("rev-parse", "HEAD")
    return r.stdout.strip() if r.returncode == 0 else ""


def cache_dir(args) -> Path:
    return Path(args.cache_dir) if getattr(args, "cache_dir", None) else repo_root() / ".claude" / "pipeline-cache" / "baseline"


def cmd_baseline_lookup(args):
    sha = head_sha()
    if not sha:
        return print("MISS kein-git-head")
    dirty = git("status", "--porcelain", "--", *[p for p in CODE_PATHS if (repo_root() / p).exists()])
    if dirty.stdout.strip():
        return print("MISS uncommitted-code-aenderungen")
    f = cache_dir(args) / f"{sha}.log"
    if not f.exists():
        return print("MISS kein-cache-fuer-head")
    age_h = (time.time() - f.stat().st_mtime) / 3600
    if age_h > args.max_age_h:
        return print(f"MISS cache-zu-alt-{age_h:.0f}h")
    Path(args.dest).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(f, args.dest)
    print(f"HIT {sha[:10]} (alter {age_h:.1f}h)")


def cmd_baseline_store(args):
    sha = head_sha()
    src = Path(args.src)
    if not sha or not src.exists():
        return print("SKIP kein-head-oder-log")
    d = cache_dir(args)
    d.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, d / f"{sha}.log")
    old = sorted(d.glob("*.log"), key=lambda p: p.stat().st_mtime, reverse=True)[10:]  # nur die letzten 10 behalten
    for p in old:
        p.unlink()
    print(f"STORED {sha[:10]}")


def cmd_review_mark(args):
    r = git("write-tree")
    if r.returncode != 0:
        return print("SKIP write-tree-fehlgeschlagen")
    Path(args.file).parent.mkdir(parents=True, exist_ok=True)
    Path(args.file).write_text(r.stdout.strip() + "\n")
    print("MARKED " + r.stdout.strip()[:10])


def cmd_review_delta(args):
    mark = Path(args.mark)
    if not mark.exists():
        return print("FULL")
    old = mark.read_text().strip()
    new = git("write-tree")
    if new.returncode != 0 or git("cat-file", "-e", old).returncode != 0:
        return print("FULL")
    new = new.stdout.strip()
    if old == new:
        return print("EMPTY")
    diff = git("diff", old, new).stdout
    if len(diff.splitlines()) > args.max_lines:
        return print("FULL")
    if args.out:
        Path(args.out).write_text(diff, encoding="utf-8")
        return print(f"DELTA {len(diff.splitlines())} lines -> {args.out}")
    print("DELTA")
    print(diff, end="")


def frontmatter_value(text: str, key: str):
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return None
    mm = re.search(rf"^{key}:\s*(\S+)\s*$", m.group(1), re.M)
    return mm.group(1).strip("\"'").lower() if mm else None


def cmd_arc42_relevant(args):
    try:
        text = Path(args.story).read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""
    forced = frontmatter_value(text, "arc42")
    if forced in ("required", "skip"):
        return print(json.dumps({"run": forced == "required", "reason": f"frontmatter arc42: {forced}"}))
    status = git("diff", "--staged", "--name-status").stdout.splitlines()
    files = []
    for line in status:
        parts = line.split("\t")
        if len(parts) >= 2:
            files.append((parts[0][0], parts[-1]))
    for _, path in files:
        for pat in ARC42_PATTERNS:
            if re.search(pat, path):
                return print(json.dumps({"run": True, "reason": f"architekturrelevanter Pfad: {path}"}))
    for st, path in files:
        if st == "A" and path.startswith("server/lib/nebu/"):
            domain = "/".join(path.split("/")[:4])
            if domain.count("/") >= 3 and not git("ls-tree", "-r", "--name-only", "HEAD", "--", domain).stdout.strip():
                return print(json.dumps({"run": True, "reason": f"neuer Baustein/Domänenordner: {domain}"}))
    print(json.dumps({"run": False, "reason": "keine architekturrelevanten Pfade gestaged"}))


def _security_blocking() -> str:
    """blocking_severity aus .claude/security-agent.yaml (Default CRITICAL)."""
    t = pl.read_text(repo_root() / ".claude" / "security-agent.yaml")
    m = re.search(r"^\s*blocking_severity:\s*([A-Za-z]+)", t, re.M)
    return m.group(1).upper() if m else "CRITICAL"


def _q(s: str) -> str:
    return '"' + s.replace('"', "'") + '"'


def cmd_decide(args):
    txt = sys.stdin.read() if args.digest == "-" else (pl.read_text(args.digest) if Path(args.digest).exists() else args.digest)
    d = pl.parse_digest(txt)
    v, sid, c = d["verdict"], args.story or "STORY", args.cycle
    rep, top = d["report"] or "-", d["top"] or "-"
    out = {}

    def log(msg):  # state-update log text; TIMESTAMP is replaced by pipeline_state.py
        return f"[{sid}] TIMESTAMP {msg}"

    def state(step=None, done=None, cycles=None, msg=""):
        parts = []
        if step: parts += ["--step", step]
        if done: parts += ["--done", done]
        if cycles is not None: parts += ["--cycles", str(cycles)]
        parts += ["--log", _q(log(msg))]
        return " ".join(parts)

    if v is None:
        out = {"ACTION": "ASK_USER", "MESSAGE": f"digest of {args.step} unparseable (no VERDICT line) — write the agent reply to REPORT_FILE once and ask the user",
               "STATE": state(msg=f"{args.step} → digest unparseable")}
    elif args.step == "test-review":
        if v == "MAJOR" or v == "CRITICAL":
            out = {"ACTION": "ASK_USER", "STATE": state("dev-story", "test-review", None, f"test-review → {d['major']} MAJOR [user continued]"),
                   "MESSAGE": f"Pre-dev test-review found {d['major']} MAJOR gaps: {top} — details: {rep}. Fix coverage before dev starts: 'continue' to proceed anyway, or fix and restart Step 2."}
        else:
            out = {"ACTION": "NEXT", "STATE": state("dev-story", "test-review", None, f"test-review → {v} (0 MAJOR, {d['minor']} MINOR)"),
                   "MESSAGE": "✓ Step 3: Pre-dev test quality verified."}
    elif args.step == "dev-story":
        if v == "DONE":
            out = {"ACTION": "NEXT", "STATE": state("ci-gate", "dev-story", None, f"dev-story → done (cycle {c})"),
                   "MESSAGE": f"✓ Step 4: Implementation complete. Cycle: {c}"}
        else:
            blocker = d["raw"].get("BLOCKER", "-")
            out = {"ACTION": "STOP", "STATE": state(None, None, None, f"dev-story → BLOCKED: {blocker[:120]}"), "MESSAGE": f"Dev agent BLOCKED: {blocker} — user decides."}
    elif args.step == "ux-gate":
        if v == "VIOLATIONS":
            out = {"ACTION": "ASK_USER", "STATE": state(None, None, None, f"ux-gate → {d['major']} violations [user continued]"),
                   "MESSAGE": f"UX Gate found {d['major']} accessibility violations: {top} — details: {rep}. Fix before code-review, or type 'continue'."}
        else:
            out = {"ACTION": "NEXT", "STATE": state(None, None, None, "ux-gate → CLEAN"), "MESSAGE": "✓ Step 5b: UX audit passed."}
    elif args.step == "oracle":
        out = {"ACTION": "NEXT", "STATE": state(None, None, None, "oracle-gate → spec context captured"), "MESSAGE": "✓ Step 1b: Oracle consulted — Matrix spec context captured."}
    elif args.step == "security-review":
        blocking = _security_blocking()
        if v == "CRITICAL" or (v == "HIGH" and blocking == "HIGH"):
            out = {"ACTION": "ASK_USER", "STATE": state("arc42-update", "security-review", None, f"security-review → {v} accepted by user"),
                   "STATE_FIX": state("dev-story", None, None, f"security-review → {v} → fix, restart at dev-story"),
                   "MESSAGE": f"Kassandra found {v} findings: {top} — report: {rep}. Pipeline stopped. (a) fix and restart from Step 4, (b) accept with written justification, (c) follow-up story in next epic; 'continue' commits with open findings (strongly discouraged)."}
        elif v == "HIGH":
            out = {"ACTION": "NEXT", "STATE": state("arc42-update", "security-review", None, f"security-review → Kassandra HIGH (non-blocking, {blocking} blocks)"),
                   "MESSAGE": f"⚠ Step 7: Kassandra HIGH (non-blocking): {top} — report: {rep}"}
        else:
            out = {"ACTION": "NEXT", "STATE": state("arc42-update", "security-review", None, "security-review → Kassandra CLEAN"), "MESSAGE": "✓ Step 7: Kassandra — clean."}
    elif args.step == "epic-security":
        if v in ("CRITICAL", "HIGH"):
            out = {"ACTION": "ASK_USER", "STATE": state(None, None, None, f"epic-security → {v}"),
                   "MESSAGE": f"SEC Gate 2: {v} — {top} — report: {rep}. Create follow-up stories in the next epic, or accept as risk with written justification."}
        else:
            out = {"ACTION": "NEXT", "STATE": state(None, None, None, "epic-security → CLEAN"), "MESSAGE": "✓ SEC Gate 2 clean — continue with the retrospective."}
    elif args.step == "code-review":
        if v == "CLEAN":
            out = {"ACTION": "NEXT", "STATE": state("security-review", "code-review", None, f"code-review → CLEAN (cycle {c})"), "MESSAGE": "✓ Step 6: Code-review clean."}
        elif v == "MINOR" and c < args.max_minor:
            out = {"ACTION": "CYCLE", "STATE": state("dev-story", None, c + 1, f"code-review → {d['minor']} MINOR → cycle {c + 1}"),
                   "MESSAGE": f"Code-review found {d['minor']} MINOR findings. Sending back to dev agent. Cycle {c + 1} starting..."}
        elif v == "MINOR":
            dest = ""
            if rep not in ("", "-") and not args.no_copy and Path(rep).exists():
                dest = str(Path(rep).with_name("deferred-minor.md"))
                shutil.copyfile(rep, dest)
            out = {"ACTION": "DEFER_MINOR", "STATE": state("security-review", "code-review", None, f"code-review → {d['minor']} MINOR deferred (cycle cap)"),
                   "MESSAGE": f"⚠ Step 6: {d['minor']} MINOR deferred ({dest or 'deferred-minor.md'}) — no further cycle. Mention in the commit summary."}
            if dest: out["COPIED"] = dest
        else:  # MAJOR / CRITICAL
            limit = c >= 3
            msg = (f"Review cycle limit reached (3 rounds), issues persist: {top} — report: {rep}. Type 'accept' to proceed with open findings, or 'stop' to investigate."
                   if limit else
                   f"Code-review found {d['major']} MAJOR/CRITICAL issues: {top} — full report: {rep}. Choose: (a) 'fix' — back to dev agent, (b) 'accept [reason]' — accept with justification, (c) 'stop' — pause.")
            out = {"ACTION": "ASK_USER", "STATE": state("security-review", "code-review", None, f"code-review → {d['major']} MAJOR accepted by user (cycle {c})"),
                   "STATE_ACCEPT": state("security-review", "code-review", None, f"code-review → {d['major']} MAJOR accepted by user (cycle {c})"),
                   "MESSAGE": msg}
            if not limit:
                out["STATE_FIX"] = state("dev-story", None, c + 1, f"code-review → {d['major']} MAJOR → fix cycle {c + 1}")
    else:
        out = {"ACTION": "ASK_USER", "MESSAGE": f"unknown step {args.step}", "STATE": ""}

    for k in ("ACTION", "STATE", "STATE_FIX", "STATE_ACCEPT", "COPIED", "MESSAGE"):
        if k in out:
            print(f"{k}: {out[k]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("baseline-lookup"); a.add_argument("--dest", required=True); a.add_argument("--max-age-h", type=float, default=72); a.add_argument("--cache-dir")
    b = sub.add_parser("baseline-store"); b.add_argument("--src", required=True); b.add_argument("--cache-dir")
    c = sub.add_parser("review-mark"); c.add_argument("--file", required=True)
    d = sub.add_parser("review-delta"); d.add_argument("--mark", required=True); d.add_argument("--max-lines", type=int, default=1500); d.add_argument("--out")
    f = sub.add_parser("decide"); f.add_argument("--step", required=True); f.add_argument("--digest", required=True); f.add_argument("--cycle", type=int, default=0)
    f.add_argument("--story", default=""); f.add_argument("--max-minor", type=int, default=1); f.add_argument("--no-copy", action="store_true")
    e = sub.add_parser("arc42-relevant"); e.add_argument("--story", required=True)
    args = ap.parse_args()
    {"baseline-lookup": cmd_baseline_lookup, "baseline-store": cmd_baseline_store, "review-mark": cmd_review_mark,
     "review-delta": cmd_review_delta, "arc42-relevant": cmd_arc42_relevant, "decide": cmd_decide}[args.cmd](args)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # Gates dürfen die Pipeline nie crashen -> konservativer Fallback
        print(f"ERROR {type(exc).__name__}: {exc}")
        sys.exit(0)
