#!/usr/bin/env python3
"""
token_metrics.py — Token- und Laufzeit-Messung pro Subagent der nebu-pipeline.

Wird als SubagentStart/SubagentStop-Hook aufgerufen (siehe install/settings-hooks.json):

    python3 skills/nebu-pipeline/scripts/token_metrics.py hook

Pro beendetem Subagent wird EINE Zeile (JSON) an <projekt>/.claude/metrics/usage.jsonl
angehängt: Tokens (input / cache_creation / cache_read / output, je Modell), Dauer,
Anzahl Nachrichten und Tool-Aufrufe, aktiver Epic/Story/Schritt aus pipeline-state.yaml
sowie ein Snapshot der kumulierten Hauptsession (= Orchestrator-Kontext).

Der Hook ist best-effort: er gibt nichts aus und endet immer mit Exit 0, damit er die
Pipeline nie stört. Fehler landen in .claude/metrics/errors.log.

Auswertung:

    python3 skills/nebu-pipeline/scripts/token_metrics.py report                 # je Schritt/Agent
    python3 skills/nebu-pipeline/scripts/token_metrics.py report --by story
    python3 skills/nebu-pipeline/scripts/token_metrics.py report --by label --since 2026-11-01
    python3 skills/nebu-pipeline/scripts/token_metrics.py parse <transcript.jsonl>

Label für Vorher/Nachher-Vergleiche: Umgebungsvariable NEBU_METRICS_LABEL
(z. B. "baseline", "phase1-routing"), wird in jede Zeile geschrieben.

Hinweis zum "Index": gewichtet Tokens nach den üblichen Preisverhältnissen
(output 5x, cache_creation 1,25x, cache_read 0,1x des Inputs) und nach Modellfamilie
(haiku 0,33 / sonnet 1,0 / opus 1,67). Das ist eine Näherung zum VERGLEICHEN von
Läufen; wie die Subscription-Limits tatsächlich gewichten, ist nicht öffentlich.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

W_CACHE_CREATE = 1.25
W_CACHE_READ = 0.1
W_OUTPUT = 5.0
MAX_MAIN_TRANSCRIPT_BYTES = 80 * 1024 * 1024

STEP_BY_AGENT = {
    "nebu-lean-story": "create-story",
    "nebu-create-story": "create-story",
    "nebu-test-reviewer": "test-review",
    "nebu-dev-story": "dev-story",
    "nebu-code-reviewer": "code-review",
    "nebu-kassandra": "security-review",
    "nebu-oracle": "oracle-gate",
    "nebu-ux-reviewer": "ux-gate",
}


# ---------------------------------------------------------------- Hilfsfunktionen

def model_weight(name: str) -> float:
    n = (name or "").lower()
    if "haiku" in n:
        return 0.33
    if "opus" in n:
        return 1.67
    return 1.0


def effective(tok: dict, model: str) -> float:
    base = (
        tok.get("input", 0)
        + W_CACHE_CREATE * tok.get("cache_creation", 0)
        + W_CACHE_READ * tok.get("cache_read", 0)
        + W_OUTPUT * tok.get("output", 0)
    )
    return base * model_weight(model)


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def find_project_root(hint: str | None = None) -> Path:
    for cand in (os.environ.get("CLAUDE_PROJECT_DIR"), hint, os.getcwd()):
        if not cand:
            continue
        p = Path(cand).resolve()
        for _ in range(10):
            if (p / ".git").exists() or (p / "_bmad").exists():
                return p
            p = p.parent
    return Path(os.getcwd()).resolve()


def metrics_dir(root: Path) -> Path:
    d = root / ".claude" / "metrics"
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------------------------------------------------------------- Transcript lesen

_BASH_WRAPPERS = ("rtk", "sudo", "time", "env")


STEP_BY_SKILL = {
    "bmad-testarch-atdd": "atdd",
    "bmad-testarch-test-review": "test-review",
    "nebu-lean-story": "create-story",
    "bmad-maintain-arc42": "arc42-update",
    "nebu-agent-arc42": "arc42-update",
    "bmad-code-review": "code-review",
    "nebu-agent-oracle": "oracle-gate",
}


def classify_bash(cmd: str) -> str:
    """Grobe Klasse eines Bash-Aufrufs (nur zur Profilbildung, kein Inhalt wird gespeichert)."""
    cmd = cmd.strip().lstrip("(").strip()
    while re.match(r"^(cd|export|set|source|\.)\s[^;&|]*(&&|;)", cmd):  # `cd server && mix test` -> classify `mix test`
        cmd = re.sub(r"^[^;&|]*(&&|;)\s*", "", cmd, count=1).lstrip("(").strip()
    seg = re.split(r"&&|\|\||;|\|", cmd, maxsplit=1)[0].strip()
    toks = [t for t in seg.split() if "=" not in t.split("/")[0] or t.startswith("-")]
    while toks and toks[0] in _BASH_WRAPPERS and len(toks) > 1:
        toks = toks[1:]
    if not toks:
        return "bash:?"
    t0 = os.path.basename(toks[0])
    if t0 in ("make", "git", "docker", "mix") and len(toks) > 1:
        return f"{t0} {toks[1]}"[:32]
    if t0.startswith("python") and len(toks) > 1:
        script = next((x for x in toks[1:] if not x.startswith("-")), "")
        return f"py:{os.path.basename(script)}"[:32]
    return t0[:24]


def _result_len(c) -> int:
    if isinstance(c, str):
        return len(c)
    if isinstance(c, list):
        return sum(len(x.get("text", "")) for x in c if isinstance(x, dict))
    return 0


def summarize_transcript(path: Path, skip_sidechain: bool = False) -> dict:
    """Summiert Nutzung eines Claude-Code-Transcripts (JSONL).

    Eine Antwort steht im Transcript mehrfach (je Content-Block ein Eintrag, gleiche
    message.id und gleiche usage) -> je message.id nur einmal zählen (größte output-Zahl).
    """
    msgs: dict[str, dict] = {}
    tool_ids: set[str] = set()
    tool_key: dict[str, str] = {}
    tool_n: dict[str, int] = {}
    result_chars: dict[str, int] = {}
    thinking_chars = text_chars = 0
    first = last = None
    n_lines = 0
    skill = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            n_lines += 1
            ts = parse_ts(o.get("timestamp"))
            if ts:
                first = ts if first is None or ts < first else first
                last = ts if last is None or ts > last else last
            if o.get("type") == "user" and not (skip_sidechain and o.get("isSidechain") is True):
                uc = (o.get("message") or {}).get("content")
                if skill is None:
                    txt = uc if isinstance(uc, str) else " ".join(
                        x.get("text", "") for x in uc if isinstance(x, dict) and x.get("type") == "text"
                    ) if isinstance(uc, list) else ""
                    mm = re.search(r"skills/([a-z0-9-]+)/SKILL\.md", txt[:3000])
                    if mm:
                        skill = mm.group(1)
                if isinstance(uc, list):
                    for b in uc:
                        if isinstance(b, dict) and b.get("type") == "tool_result":
                            k = tool_key.get(b.get("tool_use_id"), "?")
                            result_chars[k] = result_chars.get(k, 0) + _result_len(b.get("content"))
                continue
            if o.get("type") != "assistant":
                continue
            if skip_sidechain and o.get("isSidechain") is True:
                continue
            m = o.get("message")
            if not isinstance(m, dict):
                continue
            content = m.get("content")
            if isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    bt = b.get("type")
                    if bt == "tool_use" and b.get("id"):
                        if b["id"] not in tool_ids:
                            inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                            key = classify_bash(str(inp.get("command", ""))) if b.get("name") == "Bash" else str(b.get("name"))
                            tool_key[b["id"]] = key
                            tool_n[key] = tool_n.get(key, 0) + 1
                        tool_ids.add(b["id"])
                    elif bt == "thinking":
                        thinking_chars += len(b.get("thinking") or "")
                    elif bt == "text":
                        text_chars += len(b.get("text") or "")
            u = m.get("usage")
            if not isinstance(u, dict):
                continue
            mid = m.get("id") or o.get("uuid")
            cur = msgs.get(mid)
            if cur is None or u.get("output_tokens", 0) >= cur["u"].get("output_tokens", 0):
                msgs[mid] = {"u": u, "model": m.get("model") or "unknown"}

    tokens = {"input": 0, "cache_creation": 0, "cache_read": 0, "output": 0}
    models: dict[str, dict] = {}
    for rec in msgs.values():
        u, model = rec["u"], rec["model"]
        if model == "<synthetic>":
            continue
        mm = models.setdefault(
            model, {"messages": 0, "input": 0, "cache_creation": 0, "cache_read": 0, "output": 0}
        )
        mm["messages"] += 1
        for src, dst in (
            ("input_tokens", "input"),
            ("cache_creation_input_tokens", "cache_creation"),
            ("cache_read_input_tokens", "cache_read"),
            ("output_tokens", "output"),
        ):
            v = int(u.get(src) or 0)
            mm[dst] += v
            tokens[dst] += v
    return {
        "messages": sum(m["messages"] for m in models.values()),
        "tool_calls": len(tool_ids),
        "duration_s": round((last - first).total_seconds(), 1) if first and last else None,
        "tokens": tokens,
        "models": models,
        "first_ts": first.isoformat() if first else None,
        "last_ts": last.isoformat() if last else None,
        "skill": skill,
        "profile": {
            "tools": dict(sorted(tool_n.items(), key=lambda kv: -kv[1])[:14]),
            "result_chars": dict(sorted(result_chars.items(), key=lambda kv: -kv[1])[:10]),
            "thinking_chars": thinking_chars,
            "text_chars": text_chars,
        },
    }


# ---------------------------------------------------------------- Pipeline-Kontext

def _kv(text: str, key: str):
    m = re.search(rf"^{key}:\s*(.+?)\s*$", text, re.M)
    if not m:
        return None
    v = m.group(1).strip().strip("\"'")
    return None if v in ("", "null", "~") else v


def pipeline_context(root: Path, max_age_s: int = 12 * 3600) -> dict:
    base = root / "_bmad-output" / "nebu"
    cands = [base / "pipeline-state.yaml"] + [
        Path(p) for p in glob.glob(str(base / "epics" / "*" / "pipeline-state.yaml"))
    ]
    cands = [c for c in cands if c.exists()]
    if not cands:
        return {}
    newest = max(cands, key=lambda c: c.stat().st_mtime)
    if datetime.now().timestamp() - newest.stat().st_mtime > max_age_s:
        return {}
    text = newest.read_text(encoding="utf-8", errors="replace")
    cyc = _kv(text, "cycle_count")
    return {
        "epic": newest.parent.name if newest.parent.parent.name == "epics" else None,
        "story": _kv(text, "story"),
        "pipeline_step": _kv(text, "current_step"),
        "cycle": int(cyc) if cyc and cyc.isdigit() else None,
    }


# ---------------------------------------------------------------- Hook

def locate_agent_transcript(payload: dict) -> Path | None:
    p = payload.get("agent_transcript_path")
    if p and Path(p).exists():
        return Path(p)
    tp, sid, aid = payload.get("transcript_path"), payload.get("session_id"), payload.get("agent_id")
    if tp and aid:
        tp = Path(tp)
        for cand in (
            tp.with_suffix("") / "subagents" / f"agent-{aid}.jsonl",
            tp.parent / (sid or tp.stem) / "subagents" / f"agent-{aid}.jsonl",
        ):
            if cand.exists():
                return cand
        hits = glob.glob(str(tp.parent / "**" / f"agent-{aid}.jsonl"), recursive=True)
        if hits:
            return Path(hits[0])
    return None


def cmd_hook() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    root = find_project_root(payload.get("cwd") if isinstance(payload, dict) else None)
    try:
        if not isinstance(payload, dict) or not payload:
            with open(metrics_dir(root) / "errors.log", "a", encoding="utf-8") as fh:
                fh.write(f"{datetime.now(timezone.utc).isoformat()} leere/ungueltige Hook-Payload ignoriert\n")
            return
        event = str(payload.get("hook_event_name", "")).lower() or "subagentstop"
        if event not in ("subagentstart", "subagentstop"):
            return
        agent_type = payload.get("agent_type") or "unknown"
        rec = {
            "v": 1,
            "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "event": "start" if event == "subagentstart" else "stop",
            "label": os.environ.get("NEBU_METRICS_LABEL", ""),
            "session_id": payload.get("session_id"),
            "agent_id": payload.get("agent_id"),
            "agent_type": agent_type,
            "step": STEP_BY_AGENT.get(agent_type, agent_type),
        }
        rec.update(pipeline_context(root))
        if rec["event"] == "stop":
            at = locate_agent_transcript(payload)
            rec["transcript_found"] = at is not None
            if at is not None:
                rec.update(summarize_transcript(at))
                if agent_type in ("general-purpose", "unknown") and rec.get("skill") in STEP_BY_SKILL:
                    rec["step"] = STEP_BY_SKILL[rec["skill"]]
            else:
                rec["payload_keys"] = sorted(payload.keys())
                # Diagnose: welcher Pfad wurde geliefert, und existiert er? (nur Pfade, kein Inhalt)
                atp = payload.get("agent_transcript_path")
                rec["diag"] = {
                    "agent_transcript_path": atp or None,
                    "atp_exists": bool(atp) and Path(atp).exists(),
                    "transcript_path": payload.get("transcript_path") or None,
                    "raw_agent_type": payload.get("agent_type"),
                }
            tp = payload.get("transcript_path")
            if tp and Path(tp).exists() and Path(tp).stat().st_size < MAX_MAIN_TRANSCRIPT_BYTES:
                main = summarize_transcript(Path(tp), skip_sidechain=True)
                rec["main_cum"] = {**main["tokens"], "messages": main["messages"], "models": main["models"]}
        with open(metrics_dir(root) / "usage.jsonl", "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception as exc:  # best effort, never break the pipeline
        try:
            with open(metrics_dir(root) / "errors.log", "a", encoding="utf-8") as fh:
                fh.write(f"{datetime.now(timezone.utc).isoformat()} {type(exc).__name__}: {exc}\n")
        except Exception:
            pass


# ---------------------------------------------------------------- Report

def rec_effective(rec: dict) -> float:
    return sum(effective(t, m) for m, t in (rec.get("models") or {}).items())


def main_effective(rec: dict) -> float | None:
    mc = rec.get("main_cum")
    if not mc:
        return None
    return sum(effective(t, m) for m, t in (mc.get("models") or {}).items())


def load_records(files: list[str]) -> list[dict]:
    out = []
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                for line in fh:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
        except OSError as exc:
            print(f"! {f}: {exc}", file=sys.stderr)
    return out


def fmt_dur(s):
    if s is None:
        return "-"
    s = int(s)
    return f"{s // 60}m{s % 60:02d}s"


def cmd_report(args) -> None:
    root = find_project_root()
    files = args.file or [str(root / ".claude" / "metrics" / "usage.jsonl")]
    recs = [r for r in load_records(files) if r.get("event") == "stop"]
    if args.since:
        recs = [r for r in recs if (r.get("ts") or "") >= args.since]
    for key in ("label", "epic", "story"):
        v = getattr(args, key)
        if v:
            recs = [r for r in recs if r.get(key) == v]
    no_tr = [r for r in recs if r.get("transcript_found") is False]
    recs = [r for r in recs if r.get("transcript_found") is not False]
    if no_tr:
        print(
            f"! {len(no_tr)} Lauf/Läufe ohne auffindbares Subagent-Transcript (nicht mitgezählt). "
            f"Payload-Schlüssel des Hooks: {sorted({k for r in no_tr for k in r.get('payload_keys', [])})}\n"
        )
    if not recs:
        print("Keine auswertbaren Messdaten gefunden:", ", ".join(files))
        return

    keyf = {
        "step": lambda r: r.get("step") or "?",
        "story": lambda r: r.get("story") or "-",
        "epic": lambda r: r.get("epic") or "-",
        "label": lambda r: r.get("label") or "-",
        "session": lambda r: (r.get("session_id") or "?")[:8],
        "model": None,
    }[args.by]

    groups: dict[str, list[dict]] = {}
    if args.by == "model":
        for r in recs:
            for m in (r.get("models") or {}):
                groups.setdefault(m, []).append(r)
    else:
        for r in recs:
            groups.setdefault(keyf(r), []).append(r)

    rows = []
    for g, rs in groups.items():
        def tok(k):
            if args.by == "model":
                return sum((r.get("models") or {}).get(g, {}).get(k, 0) for r in rs)
            return sum((r.get("tokens") or {}).get(k, 0) for r in rs)
        eff = (
            sum(effective((r.get("models") or {}).get(g, {}), g) for r in rs)
            if args.by == "model" else sum(rec_effective(r) for r in rs)
        )
        durs = [r["duration_s"] for r in rs if r.get("duration_s") is not None]
        mains = [x for x in (main_effective(r) for r in rs) if x is not None]
        orch = (max(mains) - min(mains)) if len(mains) >= 2 else None
        by_model = args.by == "model"  # Dauer/Tool-Calls sind pro Lauf, nicht pro Modell messbar
        rows.append({
            "g": g, "n": len(rs),
            "dur": None if by_model else (sum(durs) / len(durs) if durs else None),
            "msgs": (sum((r.get("models") or {}).get(g, {}).get("messages", 0) for r in rs) / len(rs))
            if by_model else sum(r.get("messages", 0) for r in rs) / len(rs),
            "tools": None if by_model else sum(r.get("tool_calls", 0) for r in rs) / len(rs),
            "new_in": tok("input") + tok("cache_creation"),
            "cache": tok("cache_read"), "out": tok("output"),
            "eff": eff, "orch": orch,
        })
    rows.sort(key=lambda x: x["eff"], reverse=True)
    total = sum(x["eff"] for x in rows) or 1.0

    print(f"{len(recs)} Subagent-Läufe aus {len(files)} Datei(en); Gruppierung: {args.by}\n")
    head = f"{'Gruppe':34} {'n':>4} {'Ø Dauer':>8} {'Ø Msg':>6} {'Ø Tool':>6} {'neu-in k':>9} {'cache-rd k':>10} {'out k':>7} {'Index k':>8} {'Anteil':>6} {'Orch Δk':>8}"
    print(head)
    print("-" * len(head))
    for x in rows:
        orch = f"{x['orch'] / 1000:8.0f}" if x["orch"] is not None else f"{'-':>8}"
        print(
            f"{str(x['g'])[:34]:34} {x['n']:>4} {fmt_dur(x['dur']):>8} {x['msgs']:6.1f} {('-' if x['tools'] is None else format(x['tools'], '.1f')):>6} "
            f"{x['new_in'] / 1000:9.1f} {x['cache'] / 1000:10.1f} {x['out'] / 1000:7.1f} "
            f"{x['eff'] / 1000:8.0f} {100 * x['eff'] / total:5.0f}% {orch}"
        )
    print(
        "\nIndex = gewichtete Tokens (output 5x, cache-write 1,25x, cache-read 0,1x, Modellfaktor) — "
        "nur zum Vergleichen von Läufen.\nOrch Δ = Zuwachs der Hauptsession (Orchestrator) zwischen dem ersten und letzten "
        "Subagent-Ende der Gruppe."
    )


def cmd_parse(args) -> None:
    s = summarize_transcript(Path(args.transcript), skip_sidechain=args.skip_sidechain)
    s["index"] = round(sum(effective(t, m) for m, t in s["models"].items()))
    print(json.dumps(s, indent=2, ensure_ascii=False))


def cmd_profile(args) -> None:
    root = find_project_root()
    files = args.file or [str(root / ".claude" / "metrics" / "usage.jsonl")]
    recs = [r for r in load_records(files) if r.get("event") == "stop" and r.get("profile")]
    if not recs:
        print("Keine Profil-Daten (nur Läufe ab Hook-Version mit Profil, Stand Phase 2).")
        return
    groups: dict[str, list[dict]] = {}
    for r in recs:
        groups.setdefault(r.get("step") or "?", []).append(r)
    for g, rs in sorted(groups.items()):
        tools: dict[str, int] = {}
        res: dict[str, int] = {}
        think = text = out = 0
        for r in rs:
            pr = r["profile"]
            for k, v in pr["tools"].items():
                tools[k] = tools.get(k, 0) + v
            for k, v in pr["result_chars"].items():
                res[k] = res.get(k, 0) + v
            think += pr.get("thinking_chars", 0)
            text += pr.get("text_chars", 0)
            out += (r.get("tokens") or {}).get("output", 0)
        print(f"\n== {g}  ({len(rs)} Läufe, output {out/1000:.0f}k Tokens; Thinking {think/1000:.0f}k Zeichen, Text {text/1000:.0f}k Zeichen)")
        print("  Tools:  " + ", ".join(f"{k} {v}" for k, v in sorted(tools.items(), key=lambda kv: -kv[1])[:10]))
        print("  Ergebnisse im Kontext (k Zeichen): " + ", ".join(f"{k} {v/1000:.0f}" for k, v in sorted(res.items(), key=lambda kv: -kv[1])[:6]))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("hook", help="Hook-Eintrag (liest JSON von stdin)")
    r = sub.add_parser("report", help="Auswertung der gesammelten Messdaten")
    r.add_argument("--file", action="append", help="usage.jsonl (mehrfach möglich, z. B. mehrere Checkouts)")
    r.add_argument("--by", choices=["step", "story", "epic", "label", "session", "model"], default="step")
    r.add_argument("--since", help="nur Läufe ab Datum (YYYY-MM-DD)")
    r.add_argument("--label")
    r.add_argument("--epic")
    r.add_argument("--story")
    pf = sub.add_parser("profile", help="Tool-/Thinking-Profil je Schritt")
    pf.add_argument("--file", action="append")
    p = sub.add_parser("parse", help="Ein Transcript (JSONL) zusammenfassen")
    p.add_argument("transcript")
    p.add_argument("--skip-sidechain", action="store_true")
    args = ap.parse_args()

    if args.cmd in (None, "hook"):
        cmd_hook()
    elif args.cmd == "report":
        cmd_report(args)
    elif args.cmd == "parse":
        cmd_parse(args)
    elif args.cmd == "profile":
        cmd_profile(args)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass
