#!/usr/bin/env python3
"""sec_prescan.py — grep-level security candidates on the staged diff, run BEFORE Kassandra (no LLM).

Produces CANDIDATES (file:line + category + why it matters); Kassandra verifies exploitability and rates them instead of
searching from scratch. Also suggests whether a security review is needed at all (SEC_SUGGEST), so the decision does not
depend on a hand-written frontmatter value alone.

Categories (CWE in brackets)
  sql-injection [89] · code-exec [94/78] · unsafe-deserialization [502] · atom-exhaustion [400] · xss [79] · open-redirect [601] ·
  timing-compare [208] · secret-in-log [532] · hardcoded-secret [798] · weak-crypto [327/338] · insecure-cookie [614/1004] ·
  ssrf [918] · new-route [306/352] · sensitive-migration [312]

Usage:
  python3 sec_prescan.py [--base REF] [--report PATH]
Output: digest-like block on stdout:
  CANDIDATES: N (high=H medium=M low=L)
  SEC_SUGGEST: required|optional|not-needed
  REPORT: <path>
Exit 0 always (candidates are input, not verdicts).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_lib as pl  # noqa: E402

SQL_WORD = re.compile(r"\b(SELECT\s|INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|WHERE\s)", re.I)
SECRETISH = r"(password|passwd|secret|secret_key|access_key|api_key|token|credential|code_verifier|csrf|hmac|signature|nonce)"
LOGGER = re.compile(r"\bLogger\.(debug|info|notice|warn|warning|error|critical)\(")

SECURITY_PATH_PATTERNS = [
    r"^server/lib/nebu/oauth/", r"^server/lib/nebu/web/(plugs/|secret_box|token_denylist|oidc|client_ip|router)",
    r"^server/lib/nebu/admin/", r"^server/lib/nebu/compliance/", r"^server/priv/migrations/", r"^server/config/runtime\.exs$",
    r"^deploy/", r"^server/lib/nebu/matrix/session/", r"^server/lib/nebu/media/",
]
ROUTE_FILES = ("server/lib/nebu/web/router.ex", "server/lib/nebu/admin/router.ex")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base")
    ap.add_argument("--report")
    a = ap.parse_args()
    root = pl.repo_root()
    C = []  # (rating, category, where, why)

    lines = pl.added_lines(a.base)
    by_file: dict = {}
    for path, ln, text in lines:
        by_file.setdefault(path, []).append((ln, text))

    for path, items in by_file.items():
        is_ex = path.startswith("server/lib/") and path.endswith(".ex")
        is_tpl = path.startswith("server/lib/") and path.endswith((".eex", ".heex", ".html.eex")) or "/templates/" in path
        for idx, (ln, text) in enumerate(items):
            code = re.sub(r"(?<!#)#(?!\{).*$", "", text) if is_ex else text
            w = f"{path}:{ln}"
            if is_ex:
                if SQL_WORD.search(code) and pl.sql_interpolations(code):
                    exprs = pl.sql_interpolations(code)
                    userish = any(re.search(r"param|input|body|query|user|name|filter|search|conn|arg|value|term", e, re.I) for e in exprs)
                    C.append(("HIGH" if userish else "MEDIUM", "sql-injection", w, "SQL interpolates " + ", ".join(exprs)[:50] + " — attacker-controlled? (module attributes are ignored)"))
                if re.search(r"\bCode\.eval\w*|\bSystem\.cmd\(|:os\.cmd\(|\bPort\.open\(", code):
                    C.append(("HIGH", "code-exec", w, "dynamic code / OS command — inputs and quoting"))
                if "binary_to_term" in code and ":safe" not in code:
                    C.append(("HIGH", "unsafe-deserialization", w, "binary_to_term without :safe on external data?"))
                if re.search(r"\bString\.to_atom\(", code):
                    C.append(("MEDIUM", "atom-exhaustion", w, "atom from external input never gets collected (DoS)"))
                mr = re.search(r"(?:Phoenix\.HTML\.raw|[^_a-zA-Z.]raw)\((.*)", code)
                if mr or "{:safe," in code:
                    arg = (mr.group(1) if mr else "").strip()
                    constant = arg.startswith("@") or (re.match(r'^(~s\(|~S\(|")', arg) and "#{" not in arg)
                    if not constant:
                        C.append(("MEDIUM", "xss", w, "raw/safe HTML with a non-constant argument — escaped upstream?"))
                if re.search(r"redirect\(.*(external:|to:\s*[a-z_]+\b)|put_resp_header\([^,]*\"location\"", code, re.I):
                    C.append(("MEDIUM", "open-redirect", w, "redirect target — validated against an allow-list?"))
                if re.search(rf"(\b{SECRETISH}\w*\s*(==|!=)\s*[A-Za-z_\"@])|([A-Za-z_\"@\]\)]\s*(==|!=)\s*\w*{SECRETISH}\b)", code, re.I) and not re.search(r"secure_compare|is_nil|\bnil\b|(==|!=)\s*\"\"|\"\"\s*(==|!=)|hash", code, re.I):
                    C.append(("MEDIUM", "timing-compare", w, "secret/token compared with ==; use Plug.Crypto.secure_compare/2"))
                if LOGGER.search(code) and re.search(rf"#\{{[^}}]*\b{SECRETISH}s?\b[^}}]*\}}", code, re.I):
                    C.append(("MEDIUM", "secret-in-log", w, "secret-like value interpolated into a log line"))
                if re.search(r"\b(password|passwd|secret|api_key|access_key|secret_key)\b\s*(?:=|:|=>)\s*\"[A-Za-z0-9+/_\-=]{12,}\"", code, re.I):
                    C.append(("MEDIUM", "hardcoded-secret", w, "literal that looks like a credential"))
                if re.search(r":crypto\.hash\(:(md5|sha)\b|:crypto\.hash\(:md4", code) or (re.search(r":rand\.|Enum\.random\(", code) and re.search(r"token|secret|nonce|session|state|code", code, re.I)):
                    C.append(("HIGH", "weak-crypto", w, "weak hash or non-cryptographic RNG for a security value (use :crypto.strong_rand_bytes)"))
                if "put_resp_cookie(" in code:
                    window = " ".join(t for _, t in items[idx:idx + 6])
                    missing = [o for o in ("http_only", "secure", "same_site") if o not in window]
                    if missing and not re.search(r"\bopts\b|\boptions\b", window):
                        C.append(("MEDIUM", "insecure-cookie", w, f"cookie without {', '.join(missing)} in the call"))
                if re.search(r"\b(Req\.(get|post|request)|HTTPoison\.\w+|:httpc\.request|Finch\.request|Mint\.HTTP\.connect)\(", code):
                    C.append(("MEDIUM", "ssrf", w, "outbound request — host validated / pinned (no user-controlled URL)?"))
                if path in ROUTE_FILES and re.match(r"^\s*(get|post|put|patch|delete|match|forward)\s+\"", code):
                    C.append(("MEDIUM", "new-route", w, "new route — auth, CSRF / fetch-metadata gate, rate limit, body-size cap?"))
            if is_tpl and re.search(r"<%=\s*raw\b|\braw\(", code):
                C.append(("MEDIUM", "xss", w, "raw() in a template — escaped upstream?"))
            if path.startswith("server/priv/migrations/") and path.endswith(".up.sql"):
                if re.search(rf"\b{SECRETISH}\w*\b\s+(text|varchar|bytea)", code, re.I):
                    C.append(("LOW", "sensitive-migration", w, "secret-like column — stored encrypted/hashed? erasure/retention covered?"))

    # ---- suggestion
    files = [p for _, p in pl.changed_status(a.base)] or list(by_file)
    path_hit = next((f for f in files for pat in SECURITY_PATH_PATTERNS if re.search(pat, f)), None)
    high = sum(1 for c in C if c[0] == "HIGH")
    med = sum(1 for c in C if c[0] == "MEDIUM")
    low = sum(1 for c in C if c[0] == "LOW")
    if high or any(c[1] in ("new-route", "xss", "open-redirect", "insecure-cookie", "ssrf") for c in C) or (path_hit and any(f.startswith("server/lib/nebu/") for f in files) and (path_hit.startswith(("server/lib/nebu/oauth/", "server/lib/nebu/web/", "server/lib/nebu/admin/")) or "migrations" in path_hit)):
        suggest = "required"
    elif C or path_hit:
        suggest = "optional"
    else:
        suggest = "not-needed"

    rep = a.report or str(root / ".claude" / "test-logs" / "sec-prescan.md")
    Path(rep).parent.mkdir(parents=True, exist_ok=True)
    rank = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}
    body = "\n".join(f"{r} | {w} | {cat}: {why} |" for r, cat, w, why in sorted(C, key=lambda c: rank[c[0]]))
    Path(rep).write_text(f"# sec-prescan — {len(lines)} added lines, {len(files)} files; path trigger: {path_hit or '-'}\n{body}\n")
    print(f"CANDIDATES: {len(C)} (high={high} medium={med} low={low})\nSEC_SUGGEST: {suggest}\nREPORT: {rep}")


if __name__ == "__main__":
    main()
