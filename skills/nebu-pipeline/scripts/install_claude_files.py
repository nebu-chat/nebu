#!/usr/bin/env python3
"""
Install nebu .claude/ files from canonical sources in skills/nebu-pipeline/install/.

Copies agent definitions to .claude/agents/, path-scoped rules to .claude/rules/,
merges hook configuration into .claude/settings.json and adds the shared
skillOverrides (install/settings-skill-overrides.json) and permissions.deny rules
(install/settings-permissions.json) to .claude/settings.json.

Idempotent — safe to run multiple times. Always overwrites agents and rules with
the canonical versions from the install directory (source of truth is in git).
"""

import json
import shutil
import sys
from pathlib import Path


def find_project_root() -> Path:
    p = Path.cwd()
    for _ in range(10):
        if (p / ".git").exists() or (p / "_bmad").exists():
            return p
        p = p.parent
    return Path.cwd()


def install_agents(install_dir: Path, claude_dir: Path) -> list[str]:
    src = install_dir / "agents"
    dst = claude_dir / "agents"
    dst.mkdir(parents=True, exist_ok=True)

    lines = []
    for f in sorted(src.glob("nebu-*.md")):
        shutil.copy2(f, dst / f.name)
        lines.append(f"  ✓ .claude/agents/{f.name}")
    return lines


def install_rules(install_dir: Path, claude_dir: Path) -> list[str]:
    src = install_dir / "rules"
    dst = claude_dir / "rules"
    dst.mkdir(parents=True, exist_ok=True)

    lines = []
    for f in sorted(src.glob("*.md")):
        shutil.copy2(f, dst / f.name)
        lines.append(f"  ✓ .claude/rules/{f.name}")
    return lines


def merge_settings(install_dir: Path, claude_dir: Path) -> str:
    hooks_src = install_dir / "settings-hooks.json"
    settings_dst = claude_dir / "settings.json"

    new_hooks = json.loads(hooks_src.read_text())["hooks"]

    if settings_dst.exists():
        try:
            existing = json.loads(settings_dst.read_text())
        except json.JSONDecodeError:
            existing = {}
    else:
        existing = {}

    if "hooks" not in existing:
        existing["hooks"] = {}

    def ours(entry) -> bool:
        return any("skills/nebu-pipeline/scripts/" in h.get("command", "") for h in entry.get("hooks", []))

    for hook_type, hook_list in new_hooks.items():
        # replace our own entries, keep the user's own hooks of the same type
        kept = [e for e in existing["hooks"].get(hook_type, []) if not ours(e)]
        existing["hooks"][hook_type] = kept + hook_list

    settings_dst.write_text(json.dumps(existing, indent=2) + "\n")
    return "  ✓ .claude/settings.json (hooks merged)"


def merge_skill_overrides(install_dir: Path, claude_dir: Path) -> str:
    """Add shared skillOverrides to .claude/settings.json (additive, never overwrites).

    Existing keys are kept as-is, so a deliberate local choice in settings.json
    survives. settings.local.json takes precedence over settings.json anyway.
    """
    src = install_dir / "settings-skill-overrides.json"
    if not src.exists():
        return "  - skillOverrides: no template found, skipped"

    template = json.loads(src.read_text()).get("skillOverrides", {})
    settings_dst = claude_dir / "settings.json"
    try:
        existing = json.loads(settings_dst.read_text()) if settings_dst.exists() else {}
    except json.JSONDecodeError:
        existing = {}

    overrides = existing.setdefault("skillOverrides", {})
    added = 0
    for skill, mode in template.items():
        if skill not in overrides:
            overrides[skill] = mode
            added += 1

    settings_dst.write_text(json.dumps(existing, indent=2) + "\n")
    return f"  ✓ .claude/settings.json (skillOverrides: {added} added, {len(overrides)} total)"


def merge_permissions(install_dir: Path, claude_dir: Path) -> str:
    """Add shared permissions.deny rules to .claude/settings.json (additive; existing rules and other keys stay)."""
    src = install_dir / "settings-permissions.json"
    if not src.exists():
        return "  - permissions: no template found, skipped"
    template = json.loads(src.read_text()).get("permissions", {}).get("deny", [])
    settings_dst = claude_dir / "settings.json"
    try:
        existing = json.loads(settings_dst.read_text()) if settings_dst.exists() else {}
    except json.JSONDecodeError:
        existing = {}
    deny = existing.setdefault("permissions", {}).setdefault("deny", [])
    added = [r for r in template if r not in deny]
    deny.extend(added)
    settings_dst.write_text(json.dumps(existing, indent=2) + "\n")
    return f"  ✓ .claude/settings.json (permissions.deny: {len(added)} added, {len(deny)} total)"


def main():
    project_root = find_project_root()
    install_dir = project_root / "skills" / "nebu-pipeline" / "install"
    claude_dir = project_root / ".claude"

    if not install_dir.exists():
        print(f"Error: install directory not found: {install_dir}", file=sys.stderr)
        print("Ensure skills/nebu-pipeline/install/ exists in the project.", file=sys.stderr)
        sys.exit(1)

    print("Installing nebu .claude/ files...")

    results = []
    results.extend(install_agents(install_dir, claude_dir))
    results.extend(install_rules(install_dir, claude_dir))
    results.append(merge_settings(install_dir, claude_dir))
    results.append(merge_skill_overrides(install_dir, claude_dir))
    results.append(merge_permissions(install_dir, claude_dir))

    for line in results:
        print(line)

    print(f"\n✓ {len(results)} file(s) installed.")


if __name__ == "__main__":
    main()
