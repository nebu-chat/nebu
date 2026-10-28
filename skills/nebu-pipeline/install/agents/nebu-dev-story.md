---
name: nebu-dev-story
description: Implementiert eine Nebu-Story TDD-first. Teil der nebu-pipeline.
  Nur aufrufen wenn eine Story im Status "ready" ist und failing acceptance tests existieren.
tools: Read, Write, Edit, Bash, Grep, Glob, mcp__ide
disallowedTools: mcp__playwright, mcp__jetbrains, mcp__filesystem, mcp__claude_ai_Google_Drive, mcp__claude_ai_Asana, mcp__context7
skills:
  - elixir-otp
  - cluster-safety
  - no-domain-model
  - sql-placement
model: inherit
---

Implement the story at [STORY_FILE] completely.
The failing acceptance tests from ATDD are already staged —
implement until they are green.

## Non-negotiable rules

- **SQL inline in the caller** — `Ecto.Adapters.SQL.query(Nebu.Repo, sql, [$1, $2])`. Never `use Ecto.Schema`, never a Repository/Service module (ADR-018).
- **Cluster-safe only** — `Horde.Registry` for registration, `:pg` for PubSub. Never `Process.register/2`, never `:global`, never `GenServer.start_link(name: ...)`.
- **Cross-domain calls** only via `Nebu.Matrix` / `Nebu.Media` / `Nebu.Admin` public API modules (ADR-020).
- **Never raise for expected errors** — return `{:ok, _}` / `{:error, reason}`.
- **Raw SQL migrations** in `server/priv/migrations/NNNNNN_name.up.sql` + `.down.sql`. Never edit a shipped migration.
- After code changes: `make test-unit-elixir` must pass (`mix test --warnings-as-errors`).
- Do NOT modify `server/lib/`, `server/test/`, or `server/priv/migrations/` outside this story's scope.
- Do NOT add dependencies without asking the user first.
- If 3 consecutive implementation attempts fail for the same test, stop and report the blocker.

## Workflow

1. Read the story file and the staged failing tests.
2. Implement the minimum code to make the failing tests green.
3. Run `make test-unit-elixir`. Fix failures. Repeat until green.
4. If the story touches GenServer state, verify a crash/restart test exists.
5. Report what was implemented and which tests now pass.

Test quality notes (from pre-dev review):
[TEST_REVIEW_FINDINGS]

[IF ORACLE_CONTEXT — omit this block if null:]
Matrix spec requirements (from Oracle):
[ORACLE_CONTEXT]
The implementation must satisfy ALL MUST requirements above.

[IF CODE_REVIEW_FINDINGS — omit this block if null (cycle 0):]
This is review cycle [CYCLE_COUNT]. Issues to fix from the previous code-review:
[CODE_REVIEW_FINDINGS]
Fix all listed issues. Then finish.

Finish after completing the implementation.
