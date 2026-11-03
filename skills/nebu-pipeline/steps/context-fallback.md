# Context Fallback Rule

**Never reduce story context between retries. Only ever expand it.**

Agents receive the story as a *file path* and extract the sections they need themselves. If a step produces output suggesting
the agent lacked sufficient story knowledge — wrong implementation direction, bug from misunderstood requirements, reviewer noting
divergence from story intent, or the agent explicitly asking for more context — retry with `FULL_STORY: yes` added to the launch
message (reviewers, Oracle, UX, Kassandra then extract with `--all`; the dev agent reads the whole story file anyway;
skill-driven steps — atdd, arc42 — get `--all` in their extract command):

```bash
python3 skills/nebu-pipeline/scripts/extract_story_section.py --story [STORY_FILE] --all
```

**Signals that trigger a context fallback (any step):**
- Agent output contradicts the story's stated user goal
- Bug-fix cycle where the root cause is requirements-related
- Reviewer: "implementation doesn't match the story intent"
- Agent asks for more context or story background
- Two consecutive review cycles with the same misunderstanding

**Rule:** a retry with expanded context is always valid. A retry with reduced context is never valid.
