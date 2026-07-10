---
name: optout-mode-empty-degrades-to-permissive
description: An "exclude/opt-out" mode selected but with an EMPTY selection silently collapses to the permissive default (capture-all), defeating the feature's whole reason to exist
metadata:
  type: feedback
---

When a form offers an "exclusive"/"exclude these"/opt-out mode alongside an
inclusive default, verify what happens when the mode is selected but nothing is
actually checked/entered. Pattern seen in war-room-dedicated-page
(`LogsLive.WarRoom.start_war_room`): scope="exclusive" with no checkboxes and
blank "other" -> `merge_exclusive_scope/1` returns `nil` -> stored as
`scope:"all", exclusive_scope:nil` = capture EVERYTHING. The operator explicitly
chose "all except..." precisely to avoid the noisy full capture, and it silently
did the opposite with no warning/validation.

**Why:** opt-out UIs are chosen specifically to NARROW a permissive default; an
empty opt-out that falls back to the default is the one outcome the user did not
want, and it is invisible (no error, session just starts broad). Same shape-family
as [[conditional-field-wipe-on-unrelated-save]] and
[[client-server-filter-model-mismatch]] — a narrower/empty state silently maps to
the wrong broad behavior.

**How to apply:** for any exclude/opt-out selector, check the empty-selection path.
Flag MINOR if it silently reverts to the permissive default with no validation or
warning. Acceptable resolutions: require >=1 exclusion when the mode is active, OR
surface a visible "excluding nothing = capturing all" warning.
