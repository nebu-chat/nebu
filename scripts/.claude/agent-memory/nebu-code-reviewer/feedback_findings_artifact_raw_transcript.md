---
name: findings-artifact-raw-transcript
description: A pipeline step-results *-findings.md was committed as the raw JSONL agent session transcript instead of the readable report
metadata:
  type: feedback
---

A `_bmad-output/.../step-results/<story>/<step>-findings.md` artifact was staged containing the **entire raw JSONL session transcript** of the reviewing agent (one JSON event per line: thinking blocks with base64 signatures, tool_use/tool_result payloads, token-usage telemetry) — ~476KB — instead of the human-readable findings report the file name implies. The actual verdict/report was buried as the last assistant `text` block.

**Why:** The pipeline occasionally dumps the raw agent log to the findings path rather than the agent's final message. It defeats the purpose of the findings file (unreadable to humans, bloats the repo) and, subtly, means the next pipeline step / reviewer can't cheaply read the prior step's conclusions.

**How to apply:** When a staged `*-findings.md` (or similar report artifact) is huge / errors out on Read with a token-limit error, check whether it's raw JSONL (`head -c` / first char `{`). If so, flag MINOR (repo-hygiene: replace with the readable report). To extract the real verdict, parse JSONL and print the last assistant `text` content block. Not MAJOR (it's a `_bmad-output` artifact, not pipeline-protected source), but call it out — don't silently ignore. Related to [[bugfix-changeset-contamination]] (both are "wrong content in the staged diff" defects).

**Follow-on lesson (trace-map-zoom-pan, cycle 2):** A raw-JSONL findings artifact doesn't just bloat the repo — it can poison a later review. If you Read such an artifact and take its findings at face value, you may re-surface items that were a PRE-IMPLEMENTATION ATDD test-review report's MINORs (RED phase) already fixed by the ATDD author before dev-story began. Symptom: the report's file:line citations (e.g. `.steps.ts:304-337`) don't match the current tree's line numbers, and the feature/steps files carry inline `# test-review MINOR-1..N` comments explaining fixes already made. RULE: never classify a finding from any artifact/report file — always re-derive it from the CURRENT source. When a prior pass's findings are handed back, re-verify each against the live tree before re-flagging; a finding that the current tests already cover is resolved regardless of which phase fixed it. My own cycle-0/1 pass here made this error.
