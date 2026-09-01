defmodule Nebu.Media.KeyPrefixTemplateTest do
  @moduledoc """
  RED-phase ATDD tests for story `11c-s3-key-prefix-template` (epic
  `media-security-admin-control`), covering
  `Nebu.Media.StorageConfig.validate_template/1` and
  `Nebu.Media.StorageConfig.compute_key/2`.

  ## Scope adaptation (read before touching this file)

  Story 2b (`Nebu.Media.upload_async/3`, the async PUT upload handler with
  its `store_and_quarantine/...` persist-transition-enqueue seam) has NOT
  landed on this branch — `server/lib/nebu/media.ex` currently only has the
  old, deprecated `Nebu.Media.upload/1` v3 handler, whose `store_upload/4`
  hardcodes `storage_key = media_id` (see `server/lib/nebu/media.ex` around
  line 195) with no `store_and_quarantine` seam, no `/create`+`PUT` async
  flow, and no `media_async_upload_test.exs` fixture to extend. This mirrors
  the exact situation story `9c-mime-denylist-enforcement` was in against the
  same missing dependency (see `server/test/nebu/media/mime_denylist_test.exs`'s
  own "Scope adaptation" note, which implemented its logic as a standalone
  unit against a moduledoc explaining exactly where Story 2b would wire it
  in) — the same adaptation approach is used here.

  Per the story's own Acceptance Tests section
  (`docs/stories/media-security-admin-control/11c-s3-key-prefix-template.md`),
  Acceptance Tests 1-6, 10, 11 are pure interpolation/validation tests and are
  written here exactly as specified — no adaptation needed, no DB/S3
  required.

  Acceptance Tests 8 and 9 assume a real PUT-upload pipeline
  (`media_async_upload_test.exs`-style fixture) that does not exist yet. They
  are adapted below to drive `compute_key/2` directly instead (see the
  "AT8/AT9 scope-adapted stand-ins" describe blocks at the bottom of this
  file):

    * **AT8 (adapted)** — instead of asserting a real PUT persists
      `media_files.storage_key` computed from the active template, this
      proves `compute_key/2` itself is what WOULD produce that value: given a
      fixed `media_id`/`server_name`/`uploaded_at` and the active template's
      string, `compute_key/2` returns the exact interpolated key Story 2b's
      seam would pass to `Storage.put/2`. This is the seam contract Story 2b
      must call verbatim once it lands (see this story's Technical
      Requirements "exactly one call site" text).
    * **AT9 (adapted)** — instead of uploading, changing the template, and
      re-downloading through a real handler, this proves `compute_key/2`'s
      determinism directly: computing a key for a fixed `media_id` under
      template A, then computing AGAIN for the SAME `media_id` under a
      DIFFERENT template B, produces two DIFFERENT strings — and critically,
      re-deriving from the ORIGINAL (template A, same inputs) arguments a
      second time reproduces the exact same first value, proving
      `compute_key/2` carries no hidden state a later template change could
      have perturbed. Nothing in `compute_key/2`/`validate_template/1` reads
      or writes any persisted state (no `media_files` row, no ETS, no
      process dictionary) — it is a pure function of its arguments alone,
      which is exactly the property that makes AC4's "already-uploaded files
      are unaffected by a later template change" true once Story 2b persists
      the FIRST call's return value once, at upload time, and never calls
      `compute_key/2` again for that row. Story 2b, once it lands, MUST add
      the real `media_async_upload_test.exs` integration test for AT8/AT9
      verbatim per the story text — this file's versions are a stand-in, not
      a replacement.

  ## Why this suite needs no DB/S3

  `validate_template/1` and `compute_key/2` are pure functions per the
  story's own Technical Requirements ("New function(s) in
  `Nebu.Media.StorageConfig`... no separate GenServer, no new table") — no
  `Nebu.Media.StorageConfig` GenServer/ETS/`:pg` machinery is started
  anywhere in this file, and no `Nebu.Repo`/`Ecto` call is made.
  Config-save-time enforcement (AC5, "Acceptance Test 7" in the story) is
  covered separately in `server/test/nebu/media/storage_config_test.exs`
  (see the `11c-AT7` test added there), which already has the
  `Nebu.Media.StorageConfig` test seams/setup this file deliberately does not
  need.

  ## RED-phase status

  Neither `validate_template/1` nor `compute_key/2` exists yet in
  `server/lib/nebu/media/storage_config.ex` as of this file's creation
  (confirmed by reading that module — it currently ends at `default_env_reader/0`
  with no reference to either name). Every test below calls one of these two
  functions directly, so every test in this file fails with
  `UndefinedFunctionError` (function `Nebu.Media.StorageConfig.validate_template/1`
  / `compute_key/2` is undefined or private) until the dev-story step adds
  them — the correct RED reason for a brand-new function, not a
  wrong-assertion red.
  """

  use ExUnit.Case, async: true

  alias Nebu.Media.StorageConfig

  # ════════════════════════════════════════════════════════════════════════
  # AT1 — AC2: all five placeholders interpolate correctly, zero-padded
  # ════════════════════════════════════════════════════════════════════════

  describe "AT1 (AC2): interpolates a template using all five supported placeholders" do
    test "produces the exact expected key, zero-padding {month}/{day} for single-digit values" do
      # January (01) and day 5 (05) are both single-digit calendar values —
      # picked deliberately so a naive Integer.to_string/1 (no zero-pad)
      # would produce "1"/"5" and this assertion would catch it.
      dt = ~U[2026-01-05 10:15:00Z]

      result =
        StorageConfig.compute_key("{year}/{month}/{day}/{server_name}/{media_id}", %{
          media_id: "abc123",
          server_name: "nebu.example.com",
          uploaded_at: dt
        })

      assert result == "2026/01/05/nebu.example.com/abc123"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT2 — AC2: a subset-placeholder template (the 11a default) is valid
  # ════════════════════════════════════════════════════════════════════════

  describe "AT2 (AC2): a template using only a subset of placeholders is valid" do
    test "{media_id} alone (the Story 11a default) interpolates correctly" do
      dt = ~U[2026-06-30 00:00:00Z]

      result =
        StorageConfig.compute_key("{media_id}", %{
          media_id: "flatkey789",
          server_name: "nebu.example.com",
          uploaded_at: dt
        })

      assert result == "flatkey789"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT3 — AC5: a template missing {media_id} is rejected at validation time
  # ════════════════════════════════════════════════════════════════════════

  describe "AT3 (AC5): a template missing {media_id} is rejected" do
    test "returns {:error, :invalid_key_prefix_template}, never reaching interpolation" do
      assert StorageConfig.validate_template("{year}/{month}/{server_name}") ==
               {:error, :invalid_key_prefix_template}
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT4 — AC5/AC2: an unrecognized placeholder is rejected
  # ════════════════════════════════════════════════════════════════════════

  describe "AT4 (AC5/AC2): a template containing an unrecognized placeholder is rejected" do
    test "each of {room_id}, {uploader_id}, {yeat} (typo) is rejected" do
      for bad <- [
            "{room_id}/{media_id}",
            "{uploader_id}/{media_id}",
            "{yeat}/{media_id}"
          ] do
        assert StorageConfig.validate_template(bad) == {:error, :invalid_key_prefix_template},
               "expected #{inspect(bad)} to be rejected"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT5 — AC5: unbalanced brace syntax is rejected
  # ════════════════════════════════════════════════════════════════════════

  describe "AT5 (AC5): a template with unbalanced braces is rejected" do
    test "a lone opening or closing brace not part of a recognized placeholder is rejected" do
      for bad <- ["{media_id", "media_id}", "{media_id}/{year"] do
        assert StorageConfig.validate_template(bad) == {:error, :invalid_key_prefix_template},
               "expected #{inspect(bad)} to be rejected"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT6 — AC5: path-escaping segments are rejected
  # ════════════════════════════════════════════════════════════════════════

  describe "AT6 (AC5): a template containing a path-escaping segment is rejected" do
    test "a leading '../' segment is rejected" do
      assert StorageConfig.validate_template("../{media_id}") ==
               {:error, :invalid_key_prefix_template}
    end

    test "a literal '//' produced by adjacent separators is rejected" do
      assert StorageConfig.validate_template("{year}//{media_id}") ==
               {:error, :invalid_key_prefix_template}
    end

    test "a leading '/' is rejected" do
      assert StorageConfig.validate_template("/{media_id}") ==
               {:error, :invalid_key_prefix_template}
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT10 — AC6: two uploads in the same second, same server, produce
  # distinct keys because {media_id} — not timestamp granularity — is what
  # prevents collision
  # ════════════════════════════════════════════════════════════════════════

  describe "AT10 (AC6): uniqueness/collision — two distinct media_ids under a frozen timestamp" do
    test "two computed keys differ solely because of {media_id}, given identical year/month/day/server_name" do
      frozen_dt = ~U[2026-07-12 23:59:59Z]
      template = "{year}/{month}/{day}/{server_name}/{media_id}"

      key_a =
        StorageConfig.compute_key(template, %{
          media_id: "media-id-aaa",
          server_name: "nebu.example.com",
          uploaded_at: frozen_dt
        })

      key_b =
        StorageConfig.compute_key(template, %{
          media_id: "media-id-bbb",
          server_name: "nebu.example.com",
          uploaded_at: frozen_dt
        })

      assert key_a != key_b
      assert key_a == "2026/07/12/nebu.example.com/media-id-aaa"
      assert key_b == "2026/07/12/nebu.example.com/media-id-bbb"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT11 — AC5: the Story 11a default template `{media_id}` alone is
  # accepted by validation (regression guard)
  # ════════════════════════════════════════════════════════════════════════

  describe "AT11 (AC5): the Story 11a default template is accepted" do
    test "\"{media_id}\" alone passes validation" do
      assert StorageConfig.validate_template("{media_id}") == :ok
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Regression (fix cycle 1, MINOR-1): hierarchical multi-placeholder
  # templates — including the story's own User Story example and the
  # template used by AT1/AT8/AT10 — must be ACCEPTED by validate_template/1.
  #
  # This guards against the MAJOR-1 bug found in code review, where
  # check_no_path_escape/1 stripped every placeholder to "" before checking
  # for path-escaping, which collapsed the legitimate "/" separators BETWEEN
  # adjacent placeholders into false "//"/"///" and rejected every
  # hierarchical template — including these two.
  # ════════════════════════════════════════════════════════════════════════

  describe "validate_template/1 accepts hierarchical multi-placeholder templates (AC5, regression)" do
    test "the AT1/AT8/AT10 template \"{year}/{month}/{day}/{server_name}/{media_id}\" is accepted" do
      assert StorageConfig.validate_template("{year}/{month}/{day}/{server_name}/{media_id}") ==
               :ok
    end

    test "the User Story example \"{year}/{month}/{server_name}/{media_id}\" is accepted" do
      assert StorageConfig.validate_template("{year}/{month}/{server_name}/{media_id}") == :ok
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AT8/AT9 — scope-adapted stand-ins for the real upload-pipeline
  # integration tests Story 2b must add once it lands (see moduledoc)
  # ════════════════════════════════════════════════════════════════════════

  describe "AT8 (adapted, AC3): compute_key/2 is what Story 2b's upload seam would call to produce storage_key" do
    test "computes the exact key that WOULD be persisted as media_files.storage_key for a non-default active template" do
      active_template = "{year}/{month}/{day}/{server_name}/{media_id}"
      dt = ~U[2026-03-09 08:00:00Z]

      storage_key =
        StorageConfig.compute_key(active_template, %{
          media_id: "upload-time-media-id",
          server_name: "nebu.example.com",
          uploaded_at: dt
        })

      assert storage_key == "2026/03/09/nebu.example.com/upload-time-media-id"

      refute storage_key == "upload-time-media-id",
             "must not fall back to the flat media_id-only key when a non-default template is active"
    end
  end

  describe "AT9 (adapted, AC4): non-regression — compute_key/2 is deterministic and has no memory of prior calls" do
    test "computing again under a DIFFERENT template for the same media_id produces a different value, and never alters the first call's result" do
      media_id = "already-uploaded-media-id"
      server_name = "nebu.example.com"
      dt = ~U[2026-01-01 00:00:00Z]

      template_a = "{media_id}"
      template_b = "{year}/{month}/{day}/{server_name}/{media_id}"

      # (a) "upload time": template A is active. compute_key/2 returns the
      # value that — in the real Story 2b pipeline — gets persisted ONCE as
      # media_files.storage_key, immediately before Storage.put/2.
      persisted_storage_key =
        StorageConfig.compute_key(template_a, %{
          media_id: media_id,
          server_name: server_name,
          uploaded_at: dt
        })

      assert persisted_storage_key == media_id

      # (b) "an admin later changes s3_key_prefix_template to B" — simulated
      # here simply by computing with template B for the SAME media_id. In
      # the real pipeline this call never actually happens for an
      # already-uploaded row: compute_key/2 has exactly ONE call site
      # (Story 2b's store_and_quarantine seam, at upload time only, per this
      # story's Dev Agent Guardrails). This second call exists ONLY to prove
      # template B would produce a DIFFERENT value than template A did — not
      # to claim the system re-invokes compute_key/2 for a file that already
      # has a persisted storage_key.
      recomputed_under_new_template =
        StorageConfig.compute_key(template_b, %{
          media_id: media_id,
          server_name: server_name,
          uploaded_at: dt
        })

      assert recomputed_under_new_template != persisted_storage_key

      # (c) The value captured in (a) — standing in for the already-
      # persisted media_files.storage_key column — is byte-identical when
      # re-derived from the SAME (template A, same inputs) arguments, proving
      # compute_key/2 has no hidden state that step (b)'s call could have
      # perturbed. This is the "non-regression" guarantee AC4 requires: it
      # holds here for the same reason it would hold in the real pipeline —
      # compute_key/2 is a pure function of its own arguments, never of any
      # ambient config/cache/prior-call history.
      assert StorageConfig.compute_key(template_a, %{
               media_id: media_id,
               server_name: server_name,
               uploaded_at: dt
             }) == persisted_storage_key
    end
  end
end
