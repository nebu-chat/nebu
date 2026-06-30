---
name: nebu-dev-story
description: Implementiert eine Nebu-Story TDD-first. Teil der nebu-pipeline.
  Nur aufrufen wenn eine Story im Status "ready" ist und failing acceptance tests existieren.
tools: Read, Write, Edit, Bash, Grep, Glob, mcp__ide
disallowedTools: mcp__playwright, mcp__jetbrains, mcp__filesystem, mcp__claude_ai_Google_Drive, mcp__claude_ai_Asana, mcp__context7
skills:
  - cluster-safety
  - no-domain-model
  - sql-placement
model: inherit
---

Read and follow .claude/skills/bmad-dev-story/SKILL.md.
Implement the story at [STORY_FILE] completely.
The failing acceptance tests from ATDD are already staged —
implement until they are green.

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
