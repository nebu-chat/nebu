#!/usr/bin/env python3
"""spec_extract.py — draft of the Oracle context from the bundled Matrix spec (OpenAPI), without an LLM.

  spec_extract.py --story FILE --out FILE [--spec api.json]

1. Finds `/_matrix/...` / `/.well-known/matrix/...` paths (optionally with HTTP method) in the story,
   `:param`, `{param}`, `!room:srv`, `$event`, `@user:srv` segments act as wildcards, version segments (r0/v1/v3) are matched leniently.
2. Looks each endpoint up in skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/api.json and writes a compact
   requirements list: auth, rate limit, required params/body fields, response codes with errcodes, sentences containing "must".
3. Prints the digest (stdout):
     COVERAGE: full | partial | none     (full = every endpoint found and no event types / sync / e2ee concepts mentioned that the OpenAPI cannot answer)
     ENDPOINTS: matched=N unmatched=N · UNMATCHED: paths · EVENT_TYPES: m.room.* seen in the story · REPORT: <out>
   COVERAGE=full → the draft can be the final oracle-context.md; otherwise it is the head start for @nebu-oracle (SPEC_DRAFT_FILE).
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_lib as pl  # noqa: E402

SPEC = "skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/api.json"
PATH_RE = re.compile(r"(?:\b(GET|POST|PUT|DELETE|PATCH)\s+)?`?(/(?:_matrix|\.well-known/matrix)/[A-Za-z0-9_\-./{}:<>$!@%#=]*)")
SHORT_RE = re.compile(r"\b(GET|POST|PUT|DELETE)\s+`?(/[A-Za-z0-9_\-./{}:<>$!@]*)")
NON_MATRIX = ("/admin", "/api", "/oauth2", "/health", "/metrics", "/_nebu", "/live", "/ready")
SOFT_CONCEPTS = re.compile(r"\b(sync|/sync|to-device|to_device|e2ee|olm|megolm|cross-signing|federation|push rule|presence|room version)\b", re.I)


def norm_segment(seg: str) -> str:
    return "*" if re.match(r"^(\{.*\}|:[A-Za-z_]+|[!$@#].*|<.*>|\[.*\]|\{\{.*\}\})$", seg) else seg


def story_refs(text: str) -> list:
    """[(method|None, path)] unique, in order of appearance; trailing punctuation and query strings removed."""
    seen, out = set(), []
    for m in PATH_RE.finditer(text):
        method, path = m.group(1), m.group(2)
        path = re.sub(r"[?#].*$", "", path).rstrip(".,;:)`'\"")
        if path.count("/") < 3 and "_matrix" in path and not path.startswith("/.well-known"):
            continue
        key = (method, path)
        if key not in seen:
            seen.add(key)
            out.append(key)
    return out


def short_refs(text: str, explicit: list) -> list:
    """Shorthand `METHOD /devices/{id}` (no /_matrix prefix) -> [(method, path)] not already covered by an explicit path."""
    have = {p for _, p in explicit}
    seen, out = set(), []
    for m in SHORT_RE.finditer(text):
        method, path = m.group(1), re.sub(r"[?#].*$", "", m.group(2)).rstrip(".,;:)`'\"/")
        if not path or path.startswith(("/_matrix", "/.well-known")) or path.startswith(NON_MATRIX) or path in have:
            continue
        if (method, path) not in seen:
            seen.add((method, path))
            out.append((method, path))
    return out


def match_short(spec: dict, method: str, path: str) -> list:
    """Suffix match of a shorthand path against /_matrix/client/* paths (newest API version wins per distinct path shape)."""
    segs = [norm_segment(x) for x in path.strip("/").split("/")]
    hits = {}
    for sp, item in spec["paths"].items():
        if not sp.startswith("/_matrix/client/") or method.lower() not in item:
            continue
        ssegs = sp.strip("/").split("/")
        if len(ssegs) < len(segs) + 3:
            continue
        tail = ssegs[-len(segs):]
        if all((b.startswith("{") and (a == "*" or a.startswith("m."))) or a == b for a, b in zip(segs, tail)):
            shape = "/".join("{}" if x.startswith("{") else x for x in ssegs[3:])
            if shape not in hits or sp > hits[shape][1]:
                hits[shape] = (method.upper(), sp, item[method.lower()])
    return list(hits.values())


def match_prefix(spec: dict, method, path: str) -> list:
    """`/_matrix/client/v1/media/download/` style references (story abbreviates with a trailing slash or `...`)."""
    pre = path.rstrip(".")
    hits = [(m.upper(), sp, item[m]) for sp, item in spec["paths"].items() if sp.startswith(pre) or sp.startswith(pre.rstrip("/") + "/")
            for m in item if m.upper() in ("GET", "POST", "PUT", "DELETE") and (not method or m.upper() == method.upper())]
    return hits[:3]


def match_ops(spec: dict, method, path: str) -> list:
    if path.endswith(("/", "...")):
        return match_prefix(spec, method, path)
    segs = [norm_segment(s) for s in path.strip("/").split("/")]
    hits = []
    for sp, item in spec["paths"].items():
        ssegs = sp.strip("/").split("/")
        if len(ssegs) != len(segs):
            continue
        ok = True
        for a, b in zip(segs, ssegs):
            if b.startswith("{"):
                continue  # spec parameter matches anything
            if a == "*":
                ok = False
                break
            if a == b:
                continue
            if re.fullmatch(r"(r0|v\d+)", a) and re.fullmatch(r"(r0|v\d+)", b):
                continue  # lenient on the API version
            ok = False
            break
        if ok:
            for m in item:
                if m.upper() in ("GET", "POST", "PUT", "DELETE", "PATCH") and (not method or m.upper() == method.upper()):
                    hits.append((m.upper(), sp, item[m]))
    # prefer exact-version hits if several versions matched
    exact = [h for h in hits if h[1].strip("/").split("/")[:3] == path.strip("/").split("/")[:3]]
    return exact or hits


def musts(desc: str, limit: int = 5) -> list:
    flat = re.sub(r"\s+", " ", desc or "")
    sents = re.split(r"(?<=[.!?])\s+", flat)
    keep = [s.strip() for s in sents if re.search(r"\b(must|MUST|required|only|never|shall)\b", s)]
    return [s[:220] for s in keep[:limit]]


def required_fields(schema: dict) -> list:
    req = schema.get("required") or []
    props = schema.get("properties") or {}
    out = []
    for r in req:
        t = props.get(r, {}).get("type", "")
        out.append(f"{r}" + (f":{t}" if isinstance(t, str) and t else ""))
    return out


def render(method: str, path: str, op: dict) -> list:
    L = [f"## {method} {path} — {op.get('summary', '').strip()}"]
    sec = op.get("security")
    L.append(f"- Auth: {'required (access token)' if sec else 'none'} · Rate-limited: {'yes' if '429' in op.get('responses', {}) else 'no'}")
    reqp = [p["name"] + f"({p.get('in', '')})" for p in op.get("parameters", []) if p.get("required")]
    if reqp:
        L.append("- Required params: " + ", ".join(reqp))
    body = ((op.get("requestBody") or {}).get("content") or {}).get("application/json", {}).get("schema")
    if body:
        rf = required_fields(body)
        L.append("- Body required fields: " + (", ".join(rf) if rf else "none"))
        opt = [k for k in (body.get("properties") or {}) if k not in (body.get("required") or [])]
        if opt:
            L.append("- Body optional: " + ", ".join(opt[:12]) + (" …" if len(opt) > 12 else ""))
    codes = []
    for code, r in op.get("responses", {}).items():
        d = (r.get("description") or "").strip()
        ecs = sorted(set(re.findall(r"\bM_[A-Z_]+\b", d + json.dumps(r.get("content", {}))[:2000])))
        codes.append(f"{code}" + (f" [{', '.join(ecs)}]" if ecs else "") + f" {re.sub(chr(10), ' ', d)[:70]}")
    L.append("- Responses: " + " | ".join(codes))
    for s in musts(op.get("description", "")):
        L.append(f"- MUST: {s}")
    return L


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--story", required=True); ap.add_argument("--out", required=True); ap.add_argument("--spec", default=SPEC)
    ap.add_argument("--max-endpoints", type=int, default=8)
    a = ap.parse_args()

    root = pl.repo_root()
    spec_path = Path(a.spec) if Path(a.spec).is_absolute() else root / a.spec
    try:
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print("COVERAGE: none\nENDPOINTS: matched=0 unmatched=0\nUNMATCHED: -\nEVENT_TYPES: -\nREPORT: -\nERROR: spec file not readable")
        return
    text = pl.read_text(a.story)
    # only the story, AC and test sections matter — but fall back to the whole text
    body = "\n".join(pl.section(text, n) for n in ("Story", "Acceptance Criteria", "Acceptance Tests", "Tasks", "Dev Notes")).strip() or text
    refs = story_refs(body)
    if not refs:
        body = text
        refs = story_refs(body)
    shorts = short_refs(body, refs)
    matched, unmatched, lines = 0, [], ["# Oracle context (script draft from Matrix spec v1.18 api.json)", ""]
    used = set()
    for method, path in refs:
        hits = match_ops(spec, method, path)
        if not hits:
            unmatched.append(path)
            continue
        for m, sp, op in hits[: a.max_endpoints]:
            if (m, sp) in used:
                continue
            used.add((m, sp))
            matched += 1
            lines += render(m, sp, op) + [""]
    short_used = False
    for method, path in shorts:
        hits = match_short(spec, method, path)
        if not hits:
            unmatched.append(f"{method} {path}")
            continue
        for m, sp, op in hits[:3]:
            if (m, sp) in used:
                continue
            used.add((m, sp))
            matched += 1
            short_used = True
            lines += render(m, sp, op)[:1] + [f"- (matched from the shorthand `{method} {path}` — verify it is the intended endpoint)"] + render(m, sp, op)[1:] + [""]
    errs = pl.matrix_codes(body)
    etypes = sorted(set(e for e in re.findall(r"\bm\.[a-z_]+(?:\.[a-z_]+)+\b", body) if not e.startswith(("m.login.", "m.id.", "m.oauth", "m.megolm", "m.olm"))))
    if errs:
        lines.append("## Error codes named in the story")
        lines.append("- " + ", ".join(errs) + "  → every one needs a test with its HTTP status (see responses above)")
        lines.append("")
    if etypes:
        lines.append("## Event types named in the story (not covered by api.json — look up in client-server-api/index.html)")
        lines.append("- " + ", ".join(etypes))
        lines.append("")
    soft = bool(SOFT_CONCEPTS.search(body))
    if matched and not unmatched and not etypes and not soft and not short_used:
        coverage = "full"
    elif matched:
        coverage = "partial"
    else:
        coverage = "none"
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    print(f"COVERAGE: {coverage}")
    print(f"ENDPOINTS: matched={matched} unmatched={len(unmatched)}")
    print(f"UNMATCHED: {', '.join(unmatched) or '-'}")
    print(f"EVENT_TYPES: {', '.join(etypes) or '-'}")
    print(f"REPORT: {out}")


if __name__ == "__main__":
    main()
