defmodule Nebu.Media.MimeDenylistTest do
  @moduledoc """
  ATDD tests for story `9c-mime-denylist-enforcement` (epic
  `media-security-admin-control`), covering `Nebu.Media.mime_denylist_rejected?/1`.

  ## Scope adaptation (read before touching this file)

  Story 2b (`Nebu.Media.upload_async/3`, `PUT
  /_matrix/media/v3/upload/{serverName}/{mediaId}`) has NOT landed on this
  branch — no such route exists in `server/lib/nebu/web/router/media.ex`, no
  such function exists in `server/lib/nebu/media.ex`. The story's literal
  Acceptance Tests (full PUT request/response assertions against
  `upload_async/3`, storage-fake non-call assertions, state-machine
  transition assertions) therefore cannot be written against real production
  code — see
  `_bmad-output/nebu/epics/media-security-admin-control/step-results/9c-mime-denylist-enforcement/scope-adaptation.md`
  for the full authoritative decision.

  Instead, this file drives the standalone pure function directly:
  `Nebu.Media.mime_denylist_rejected?/1`.

    * Takes an ALREADY-RESOLVED `Content-Type` string. This function does no
      header parsing/defaulting — resolving/defaulting `Content-Type` (to
      `application/octet-stream` when absent) remains the caller's job,
      mirroring how `Nebu.Media.upload/1` resolves `Content-Type` once, up
      front, before checking it against `@blocked_upload_types` (see
      `server/lib/nebu/media.ex`, `upload/1` line ~56:
      `content_type = base_content_type(conn) || "application/octet-stream"`,
      THEN `content_type in @blocked_upload_types`).
    * Reads `Nebu.Media.Config.get/0` on EVERY call — no local caching in
      `Nebu.Media` itself (AC1/AC5). `Nebu.Media.Config`'s own ETS/`:pg`/TTL
      mechanism (story 9a) is what delivers "no restart needed" once this
      function is wired into a real handler by story 2b.
    * Parses `mime_denylist` (comma-separated, trim each token, drop empty
      tokens — `""` parses to `[]`. AC4).
    * Returns `true` if `content_type` `String.starts_with?/2` any parsed
      prefix, else `false` (AC2/AC3).

  `Nebu.Media.mime_denylist_rejected?/1` is now implemented in
  `server/lib/nebu/media.ex` and every test below passes (GREEN). This file
  originated as a RED-phase ATDD scaffold (written before the function
  existed, per the scope-adaptation note above) and was subsequently made to
  pass by dev-story without changing test assertions/behavior — the scope
  adaptation context above remains accurate and should be read before
  touching this file, but the function itself is no longer missing.

  ## Test seam

  Uses the EXISTING `Nebu.Media.Config` test seam (already built by story
  9a, see `server/lib/nebu/media/config.ex` `get/0` and
  `server/test/nebu/media/config_test.exs`'s own `setup` block for
  precedent): `Application.put_env(:nebu_http, :media_config_source, fn ->
  %{"mime_denylist" => "..."} end)` — a 0-arity fun returning a
  STRING-keyed override map, consulted by `Config.get/0` BEFORE the
  ETS/GenServer/DB path, bypassing all of that entirely. No new MediaFakes
  seam is needed for the config side (per the scope-adaptation note); no
  `Nebu.Media.Config` GenServer/ETS table/DB is started anywhere in this
  file.
  """

  use ExUnit.Case, async: false

  # ─── Setup / Teardown ─────────────────────────────────────────────────────

  setup do
    on_exit(fn ->
      Application.delete_env(:nebu_http, :media_config_source)
    end)

    :ok
  end

  # Installs the media_config_source seam with the given mime_denylist string,
  # merged over story 9a's other 9 catalog defaults (irrelevant to this
  # story, included only because Config.get/0's contract always returns the
  # full 10-key catalog).
  defp seed_denylist(mime_denylist) when is_binary(mime_denylist) do
    Application.put_env(:nebu_http, :media_config_source, fn ->
      %{"mime_denylist" => mime_denylist}
    end)
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC1/AC5 — reads Config.get/0 per call, no local caching
  # ════════════════════════════════════════════════════════════════════════

  describe "AC1/AC5: reads Nebu.Media.Config.get/0 on every call, no caching" do
    test "two calls bracketing a config-source change both reflect their own call's config (no memoization)" do
      seed_denylist("application/x-msdownload")

      # First call: "application/x-msdownload" is denied.
      assert Nebu.Media.mime_denylist_rejected?("application/x-msdownload") == true

      # Mutate the config source between calls — no process restart, no
      # extra step beyond re-pointing the app-env seam (mirrors how a real
      # admin upsert/1 changes what Config.get/0 returns on the very next
      # call, per AC5).
      seed_denylist("image/png")

      # Second call: "application/x-msdownload" is no longer in the
      # (new) denylist, so it must now be allowed. If mime_denylist_rejected?/1
      # cached the first call's parsed list (or Config.get/0's result) instead
      # of reading through on every call, this would incorrectly still return
      # true.
      assert Nebu.Media.mime_denylist_rejected?("application/x-msdownload") == false

      # And the newly-denied type from the second config is now rejected —
      # proving the second call genuinely read the NEW config, not a stale
      # cache of the first.
      assert Nebu.Media.mime_denylist_rejected?("image/png") == true
    end

    test "AC5: a config change takes effect on the very next call, no restart" do
      seed_denylist("")
      assert Nebu.Media.mime_denylist_rejected?("application/zip") == false

      seed_denylist("application/zip")
      assert Nebu.Media.mime_denylist_rejected?("application/zip") == true
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC2/AC3 — prefix match against the resolved header, no content sniffing
  # ════════════════════════════════════════════════════════════════════════

  describe "AC2/AC3: String.starts_with?/2 prefix matching, case-sensitive, no sniffing" do
    test "a Content-Type exactly matching a configured prefix is rejected" do
      seed_denylist("application/x-msdownload")

      assert Nebu.Media.mime_denylist_rejected?("application/x-msdownload") == true
    end

    test "a Content-Type NOT matching any configured prefix is allowed" do
      seed_denylist("application/x-msdownload")

      assert Nebu.Media.mime_denylist_rejected?("image/png") == false
    end

    test "matching is case-sensitive (no case-folding is performed)" do
      seed_denylist("application/x-msdownload")

      # mime_denylist_rejected?/1 itself does NO case-folding — it is
      # strictly case-sensitive String.starts_with?/2. Case-insensitive
      # behavior at the real call site does NOT come from Plug: Plug only
      # lowercases HTTP header *field names* ("Content-Type" vs
      # "content-type"), never header *values*. The insensitivity a real
      # caller sees comes entirely from routing the value through
      # `base_content_type/1` -> `base_type/1` first, which explicitly calls
      # `String.downcase()` (see server/lib/nebu/media.ex @doc on
      # mime_denylist_rejected?/1). This test exercises the pure function
      # directly with a raw, non-downcased string to lock in that it is the
      # caller's job — not this function's — to normalize case; passing an
      # un-normalized value here (as a real caller must not) deliberately
      # fails to match.
      assert Nebu.Media.mime_denylist_rejected?("APPLICATION/X-MSDOWNLOAD") == false
    end

    test "a Content-Type with trailing parameters (e.g. '; charset=utf-8') is checked AS GIVEN — this function does not strip params" do
      # Design decision, documented here rather than left implicit: AC3
      # states the caller (2b's upload_async/3) resolves Content-Type
      # BEFORE calling this function, and this function does "no header
      # parsing" of its own — stripping `; charset=...` params would be a
      # form of header parsing this story explicitly scopes OUT (see
      # scope-adaptation.md point 1 and the story's Technical Requirements
      # "MIME-detection mechanism" section, which says matching runs
      # against "the same Content-Type value 2b already resolves" with "no
      # new detection mechanism introduced"). Concretely:
      #
      #   * A denylist prefix "text/plain" DOES match a resolved
      #     Content-Type of "text/plain; charset=utf-8" (starts_with? is
      #     satisfied — the parameter is a SUFFIX, so the prefix check
      #     naturally succeeds without any stripping).
      #   * A denylist prefix "text/plain; charset=utf-8" is an unusual
      #     admin config choice but is likewise matched literally via
      #     starts_with?, with no leniency either way.
      #
      # This test locks in the "no params-stripping, no extra normalization"
      # behavior as a deliberate contract, not an oversight. Note this calls
      # the pure function directly with a param-suffixed literal to exercise
      # its own starts_with? semantics in isolation — it is NOT a claim about
      # what a real call site passes: the documented caller
      # (`base_content_type/1`) already strips `;`-parameters before this
      # function ever sees the value, so in production this exact
      # param-suffixed string would never actually reach
      # mime_denylist_rejected?/1. This is a boundary/unit-level test of the
      # function on its own terms, not of the production call path.
      seed_denylist("text/plain")

      assert Nebu.Media.mime_denylist_rejected?("text/plain; charset=utf-8") == true
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # AC4 — empty mime_denylist ("") never rejects, for any content_type
  # ════════════════════════════════════════════════════════════════════════

  describe "AC4: empty denylist is a no-op" do
    test "mime_denylist == '' allows every Content-Type, including ones that would obviously match a non-empty list" do
      seed_denylist("")

      for content_type <- [
            "application/x-msdownload",
            "application/zip",
            "text/html",
            "image/png",
            "application/octet-stream"
          ] do
        refute Nebu.Media.mime_denylist_rejected?(content_type),
               "expected #{inspect(content_type)} to be allowed under an empty denylist"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Multiple comma-separated prefixes / whitespace-tolerant parsing
  # ════════════════════════════════════════════════════════════════════════

  describe "multiple comma-separated prefixes" do
    test "only the matching prefix among several rejects; the others do not falsely match" do
      seed_denylist("application/x-msdownload,application/zip,application/x-sh")

      assert Nebu.Media.mime_denylist_rejected?("application/zip") == true
      assert Nebu.Media.mime_denylist_rejected?("image/png") == false
    end

    test "whitespace after the comma separator is trimmed per token before matching" do
      # "application/zip, application/x-msdownload" — note the space after
      # the comma. Per Technical Requirements ("Config read": split on ',',
      # trim whitespace per token, discard empty tokens), the second token
      # must parse to "application/x-msdownload" (no leading space), not
      # " application/x-msdownload" (which would never match anything via
      # starts_with? since real Content-Type headers do not carry a leading
      # space).
      seed_denylist("application/zip, application/x-msdownload")

      assert Nebu.Media.mime_denylist_rejected?("application/x-msdownload") == true
      assert Nebu.Media.mime_denylist_rejected?("application/zip") == true
      assert Nebu.Media.mime_denylist_rejected?("image/png") == false
    end

    # test-review MINOR (9c): "discard empty tokens" is a distinct parsing
    # rule from "trim whitespace per token" — a garbage/trailing-comma
    # config value (double comma, or a comma with nothing after it) must
    # parse to a list with the empty tokens DROPPED, not kept. This matters
    # because String.starts_with?(content_type, "") is ALWAYS true — if the
    # parser fails to discard an empty token, this bug would silently deny
    # EVERY upload regardless of content type, and no other test in this
    # file would catch it (none of them seed a value with a stray comma).
    test "a stray/trailing/double comma produces empty tokens that are DISCARDED, not matched" do
      seed_denylist("application/zip,,text/html,")

      # The real, non-empty tokens still match as configured.
      assert Nebu.Media.mime_denylist_rejected?("application/zip") == true
      assert Nebu.Media.mime_denylist_rejected?("text/html") == true

      # Critically: an unrelated content type must NOT be rejected. If the
      # empty tokens produced by the double/trailing comma were not
      # discarded, this would incorrectly return `true` for everything.
      assert Nebu.Media.mime_denylist_rejected?("image/png") == false
      assert Nebu.Media.mime_denylist_rejected?("application/octet-stream") == false
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # security-review 2026-07-13 (MEDIUM-1b) — mixed-case admin config
  # ════════════════════════════════════════════════════════════════════════

  describe "security-review MEDIUM-1b: mixed-case admin-configured prefixes are lowercased at parse time" do
    test "an admin-entered mixed-case prefix still matches a correctly-lowercased content_type" do
      # Kassandra's finding: an admin who types "Application/Zip" into the
      # mime_denylist config field would otherwise have that prefix NEVER
      # match a real (caller-normalized, lowercased) incoming content_type
      # of "application/zip" — the denylist would silently be a no-op with
      # no error/audit signal that the admin's policy isn't taking effect.
      # This is a distinct gap from the content_type-side caller-contract
      # (case-sensitivity is intentional there, per the story's "do not add
      # a second normalization step" directive) — here we lowercase the
      # denylist's OWN configured values, not the incoming content_type.
      seed_denylist("Application/Zip")

      assert Nebu.Media.mime_denylist_rejected?("application/zip") == true
    end

    test "mixed-case prefixes mixed with already-lowercase ones all match correctly" do
      seed_denylist("Application/X-MSDownload,text/html,IMAGE/SVG+XML")

      assert Nebu.Media.mime_denylist_rejected?("application/x-msdownload") == true
      assert Nebu.Media.mime_denylist_rejected?("text/html") == true
      assert Nebu.Media.mime_denylist_rejected?("image/svg+xml") == true
      assert Nebu.Media.mime_denylist_rejected?("image/png") == false
    end
  end
end
