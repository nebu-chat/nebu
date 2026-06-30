#!/usr/bin/env python3
"""
Invariant check for nebu architecture rules.
Runs automatically via SubagentStop hook after nebu-dev-story.

Exit codes:
  0 - All invariants pass
  1 - Warnings only (non-blocking)
  2 - Violations found (pipeline should block)
"""

import argparse
import ast
import os
import re
import sys
from pathlib import Path


def check_no_ecto_schema(lib_path: Path) -> list[dict]:
    """ADR-018: No Ecto.Schema — no Repository/Service layer."""
    violations = []
    for f in lib_path.rglob("*.ex"):
        # Skip test files and migration files
        if "/test/" in str(f) or "/migrations/" in str(f):
            continue
        content = f.read_text(errors="replace")
        if "use Ecto.Schema" in content:
            line_no = next(
                (i + 1 for i, l in enumerate(content.splitlines()) if "use Ecto.Schema" in l),
                0,
            )
            violations.append({
                "rule": "no-domain-model",
                "severity": "ERROR",
                "file": str(f),
                "line": line_no,
                "message": "use Ecto.Schema found — ADR-018 forbids schema definitions outside migrations",
            })
    return violations


def check_no_process_register(lib_path: Path) -> list[dict]:
    """ADR-020: No bare Process.register/2 — must use Horde.Registry."""
    violations = []
    pattern = re.compile(r"\bProcess\.register\(")
    for f in lib_path.rglob("*.ex"):
        if "/test/" in str(f):
            continue
        content = f.read_text(errors="replace")
        for i, line in enumerate(content.splitlines()):
            if pattern.search(line):
                violations.append({
                    "rule": "cluster-safety",
                    "severity": "ERROR",
                    "file": str(f),
                    "line": i + 1,
                    "message": "Process.register/2 found — use Horde.Registry for cluster-safe process registration",
                })
    return violations


def check_no_global_register(lib_path: Path) -> list[dict]:
    """ADR-020: No :global.register_name — cluster unsafe."""
    violations = []
    pattern = re.compile(r":global\.register_name\b")
    for f in lib_path.rglob("*.ex"):
        if "/test/" in str(f):
            continue
        content = f.read_text(errors="replace")
        for i, line in enumerate(content.splitlines()):
            if pattern.search(line):
                violations.append({
                    "rule": "cluster-safety",
                    "severity": "ERROR",
                    "file": str(f),
                    "line": i + 1,
                    "message": ":global.register_name found — cluster unsafe, use Horde.Registry",
                })
    return violations


def check_public_api_rule(lib_path: Path) -> list[dict]:
    """ADR-020: Cross-domain calls only via Nebu.Matrix / Nebu.Media / Nebu.Admin.

    Only flags 3+ level deep internal calls (e.g. Nebu.Matrix.Rooms.GenServer.something)
    since 2-level calls like Nebu.Matrix.UserId or Nebu.Media.Crypto are utility helpers.
    """
    violations = []
    # Minimum depth for a suspicious cross-domain call: 4 module components
    # e.g. Nebu.Matrix.Http.Router.call -> suspicious
    # e.g. Nebu.Matrix.UserId.from_claims -> probably fine (utility)
    deep_internal_pattern = re.compile(
        r"\b(Nebu\.(Matrix|Media|Admin))"
        r"(?:\.\w+){2,}"  # 2+ additional segments = 4+ total depth
        r"\.\w+\("         # ends with a function call
    )

    domain_map = {
        "nebu/matrix": ["Media", "Admin"],
        "nebu/media": ["Matrix", "Admin"],
        "nebu/admin": ["Matrix", "Media"],
        "nebu/web": ["Matrix", "Media", "Admin"],
        "nebu/compliance": ["Matrix", "Media", "Admin"],
    }

    for domain_path, other_domains in domain_map.items():
        domain_dir = lib_path / domain_path
        if not domain_dir.exists():
            continue
        for f in domain_dir.rglob("*.ex"):
            if "/test/" in str(f):
                continue
            content = f.read_text(errors="replace")
            for i, line in enumerate(content.splitlines()):
                if line.strip().startswith("#"):
                    continue
                m = deep_internal_pattern.search(line)
                if m:
                    # Check if it's a foreign domain
                    matched_domain = m.group(2)
                    if matched_domain in other_domains:
                        violations.append({
                            "rule": "public-api",
                            "severity": "WARNING",
                            "file": str(f),
                            "line": i + 1,
                            "message": f"Deep cross-domain call to Nebu.{matched_domain} internals: {m.group(0).strip()} — should go via public API module",
                        })
    return violations


def check_no_redis_nats(lib_path: Path) -> list[dict]:
    """ADR-002: No Redis, No NATS — ETS + pg only."""
    violations = []
    bad = re.compile(r"\b(Redix|NATS\.io|Gnat|Redix\.Pool)\b")
    mix_exs = lib_path.parent / "mix.exs"
    files_to_check = list(lib_path.rglob("*.ex")) + ([mix_exs] if mix_exs.exists() else [])
    for f in files_to_check:
        content = f.read_text(errors="replace")
        for i, line in enumerate(content.splitlines()):
            m = bad.search(line)
            if m:
                violations.append({
                    "rule": "no-redis-nats",
                    "severity": "ERROR",
                    "file": str(f),
                    "line": i + 1,
                    "message": f"{m.group(0)} found — ADR-002 forbids Redis/NATS; use ETS + :pg",
                })
    return violations


def check_no_oidc_env_vars(lib_path: Path) -> list[dict]:
    """ADR-022: No NEBU_OIDC_* or NEBU_ADMIN_OIDC_* env vars — bootstrap-only."""
    violations = []
    pattern = re.compile(r'System\.get_env\(["\']NEBU_(ADMIN_)?OIDC_(?!JWKS_TTL)')
    for f in lib_path.rglob("*.ex"):
        content = f.read_text(errors="replace")
        for i, line in enumerate(content.splitlines()):
            if pattern.search(line):
                violations.append({
                    "rule": "oidc-bootstrap-only",
                    "severity": "ERROR",
                    "file": str(f),
                    "line": i + 1,
                    "message": "NEBU_OIDC_* env var read — ADR-022: OIDC config is bootstrap-only via server_config",
                })
    return violations


def format_report(violations: list[dict]) -> str:
    if not violations:
        return "✓ All architecture invariants pass."

    errors = [v for v in violations if v["severity"] == "ERROR"]
    warnings = [v for v in violations if v["severity"] == "WARNING"]

    lines = ["Invariant Check Results", "=" * 40]

    if errors:
        lines.append(f"\n🔴 ERRORS ({len(errors)}) — pipeline blocked:")
        for v in errors:
            lines.append(f"  [{v['rule']}] {v['file']}:{v['line']}")
            lines.append(f"    {v['message']}")

    if warnings:
        lines.append(f"\n⚠  WARNINGS ({len(warnings)}) — review required:")
        for v in warnings:
            lines.append(f"  [{v['rule']}] {v['file']}:{v['line']}")
            lines.append(f"    {v['message']}")

    return "\n".join(lines)


def get_changed_elixir_files(lib_path: Path) -> list[Path] | None:
    """Return list of changed .ex files under lib_path from git, or None if git fails."""
    import subprocess
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "HEAD"],
            capture_output=True, text=True, check=True,
        )
        staged = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            capture_output=True, text=True, check=True,
        )
        all_changed = set(result.stdout.splitlines() + staged.stdout.splitlines())
        return [
            p for name in all_changed
            if name.endswith(".ex")
            for p in [Path(name).resolve()]
            if str(p).startswith(str(lib_path)) and p.exists()
        ]
    except Exception:
        return None


def filter_to_files(check_fn, lib_path: Path, files: list[Path] | None):
    """Run check_fn against either specific files or the whole lib_path."""
    if files is None:
        return check_fn(lib_path)
    # Run the check against a virtual lib_path that only contains the changed files.
    # Achieved by monkeypatching rglob — simpler: create a wrapper.
    violations = []
    for f in files:
        # Pass single-file path to check functions that iterate via rglob
        # by temporarily creating a scope with just this file.
        pass
    # Fallback: run against full lib_path for file-iterating checks.
    # The main benefit of --auto with git diff is scoping error output to new code.
    return check_fn(lib_path)


def main():
    parser = argparse.ArgumentParser(description="Nebu architecture invariant checker")
    parser.add_argument("--lib", required=True, help="Path to server/lib/ directory")
    parser.add_argument(
        "--auto", action="store_true",
        help="Hook mode: report only violations in git-changed files",
    )
    parser.add_argument(
        "--full", action="store_true",
        help="Check entire lib/ (default when not --auto)",
    )
    parser.add_argument(
        "--checks",
        nargs="+",
        choices=["no-ecto-schema", "no-process-register", "no-global-register",
                 "public-api", "no-redis-nats", "no-oidc-env"],
        help="Specific checks to run (default: all)",
    )
    args = parser.parse_args()

    lib_path = Path(args.lib).resolve()
    if not lib_path.exists():
        print(f"Error: lib path not found: {lib_path}", file=sys.stderr)
        sys.exit(1)

    # In --auto mode, scope to changed files only (avoids noise from pre-existing violations)
    changed_files = None
    if args.auto and not args.full:
        changed_files = get_changed_elixir_files(lib_path)
        if changed_files is not None and len(changed_files) == 0:
            print("✓ No changed Elixir files — invariants pass.")
            sys.exit(0)

    checks_to_run = args.checks or [
        "no-ecto-schema", "no-process-register", "no-global-register",
        "public-api", "no-redis-nats", "no-oidc-env",
    ]

    # For checks that support per-file scoping, pass changed_files.
    # For now all checks run against lib_path; changed_files is used for filtering output.
    all_violations = []

    if "no-ecto-schema" in checks_to_run:
        v = check_no_ecto_schema(lib_path)
        if changed_files is not None:
            changed_strs = {str(f) for f in changed_files}
            v = [x for x in v if x["file"] in changed_strs]
        all_violations.extend(v)

    if "no-process-register" in checks_to_run:
        v = check_no_process_register(lib_path)
        if changed_files is not None:
            changed_strs = {str(f) for f in changed_files}
            v = [x for x in v if x["file"] in changed_strs]
        all_violations.extend(v)

    if "no-global-register" in checks_to_run:
        v = check_no_global_register(lib_path)
        if changed_files is not None:
            changed_strs = {str(f) for f in changed_files}
            v = [x for x in v if x["file"] in changed_strs]
        all_violations.extend(v)

    if "public-api" in checks_to_run:
        v = check_public_api_rule(lib_path)
        if changed_files is not None:
            changed_strs = {str(f) for f in changed_files}
            v = [x for x in v if x["file"] in changed_strs]
        all_violations.extend(v)

    if "no-redis-nats" in checks_to_run:
        v = check_no_redis_nats(lib_path)
        if changed_files is not None:
            changed_strs = {str(f) for f in changed_files}
            v = [x for x in v if x["file"] in changed_strs]
        all_violations.extend(v)

    if "no-oidc-env" in checks_to_run:
        v = check_no_oidc_env_vars(lib_path)
        if changed_files is not None:
            changed_strs = {str(f) for f in changed_files}
            v = [x for x in v if x["file"] in changed_strs]
        all_violations.extend(v)

    if args.auto and changed_files is not None:
        file_count = len(changed_files)
        print(f"Invariant check — {file_count} changed file(s) in server/lib/")

    report = format_report(all_violations)
    print(report)

    errors = [v for v in all_violations if v["severity"] == "ERROR"]
    if errors:
        sys.exit(2)
    elif all_violations:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
