---
name: nebu-lean-story
description: Lean story creation — converts raw user input into an ISO-traceable story file with Gherkin acceptance criteria. No artifact loading, no web research, no git analysis.
---

# Lean Story Creation

**Input:** raw story description from the user + epic name.
**Output:** one story file at `<story-dir>/<slug>.md`.

## Strict Rules

- Do NOT load PRD, architecture, epics, UX docs, or any planning artifacts.
- Do NOT do web research. Do NOT analyze git history or previous stories.
- Do NOT load or follow any other skill.
- Work only from the user input below.
- If the input is too vague for meaningful Gherkin (no clear actor or goal), write the story anyway and add an `## Open Questions` section. Never block on questions.
- Match the user input's language for the story body. Frontmatter keys stay English.

## Input

- Epic: `[EPIC_NAME]`
- Story directory: `[STORY_DIR]`
- User input: `[USER_INPUT]`

## Steps

1. **Slug:** derive from the user input — lowercase, hyphen-separated, <=50 chars, describes the behavior (e.g. `typing-indicators`, `gdpr-erasure`).
2. **Traceability ID:** scan all `*.md` in the story directory for `traceability_id: REQ-<YYYY>-<NNN>`. Use the current year and `max(NNN) + 1`, zero-padded to 3 digits. If none exist: `REQ-<YYYY>-001`.
3. **Write the story file** with the exact structure below.
4. **Verify** the file exists in the story directory (create the directory if needed).
5. **Report** the file path and traceability ID. Finish.

## Story Template

The story file is a Markdown file with YAML frontmatter, followed by these level-2 sections in this exact order: `Story`, `Acceptance Criteria`, `Definition of Done`, and optionally `Open Questions`.

Frontmatter fields (in order): `story_id` (the slug), `title` (short quoted title), `epic`, `status: ready`, `security_review: optional`, `matrix: false`, `ui: false`, `traceability_id`, `created` (YYYY-MM-DD, today).

`## Story` section: a user-story paragraph in the form "**As** <role>, **I want** <goal>, **so that** <benefit>." Derived directly from the user input.

`## Acceptance Criteria` section: a single fenced code block with language tag `gherkin`. Inside: one `Feature:` line naming the feature, then 1-5 `Scenario:` blocks. Each scenario has exactly one `Given`, one `When`, one `Then` line, indented two spaces. Cover the happy path plus at least one edge case (error, empty state, or unauthorized access) whenever the input implies one. Do not invent scenarios the user did not ask for.

`## Definition of Done` section: a fixed checklist, exactly these four items:

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

`## Open Questions` (only if the input is vague): bullet list of the specific clarifications needed.

## Example

Given epic `matrix-presence`, story dir `docs/stories/matrix-presence/`, and user input "Users should see when other users are typing in a room":

The file `docs/stories/matrix-presence/typing-indicators.md` contains:

Frontmatter with story_id `typing-indicators`, title `"Typing indicators in rooms"`, epic `matrix-presence`, status `ready`, security_review `optional`, matrix `true`, ui `false`, traceability_id `REQ-2026-001`, created with today's date.

Then `## Story`: "**As** a user in a room, **I want** to see when other participants are typing, **so that** I know a response is coming."

Then `## Acceptance Criteria` with a gherkin block: Feature "Typing indicators", Scenario "User sees typing notification" (Given I am in a room with another user, When the other user starts typing, Then I see their typing indicator), Scenario "Typing indicator disappears" (Given another user's typing indicator is visible, When they stop typing, Then the indicator disappears).

Then `## Definition of Done` with the four fixed checklist items.
