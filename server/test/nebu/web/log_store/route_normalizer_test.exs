defmodule Nebu.Web.LogStore.RouteNormalizerTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/operational-log-store` (AC5 —
  route template normalization), including the Oracle-gate MUST-fix edge
  cases for `state_key`, room aliases, and non-ASCII/historical-format user
  localparts.

  Story: docs/stories/enhanced-logging/operational-log-store.md

  ## Why these MUST FAIL right now

  `Nebu.Web.LogStore.RouteNormalizer` (server/lib/nebu/web/log_store/route_normalizer.ex)
  does not exist yet. Every test here fails at runtime with
  `UndefinedFunctionError`.

  ## The `state_key` edge case (Oracle gate — LAW area)

  `PUT /rooms/{roomId}/state/{eventType}/{stateKey}` — `state_key` is a path
  SEGMENT that may contain ARBITRARY/SENSITIVE content (plain text, empty
  string, punctuation), not just an opaque ID. A naive "opaque ID-shaped"
  regex (e.g. `[a-f0-9\\-]{32,}`, the dev-notes' own illustrative UUID-only
  heuristic) will fail to match a non-UUID-shaped state_key and leak it
  verbatim into route_template — exactly the class of bug this story's own
  `PayloadRedactor` module already had to fix for message bodies
  (`matrix-payload-debug-logging`'s "fixed field-name list can never be
  exhaustive" lesson, reapplied here to path segments instead of body
  fields).
  """
  use ExUnit.Case, async: true

  alias Nebu.Web.LogStore.RouteNormalizer

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — core normalization: room IDs, user IDs, opaque IDs, unchanged /sync
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC5: core segment normalization" do
    test "a Matrix room ID segment is replaced with a placeholder, not left raw" do
      result =
        RouteNormalizer.normalize_route("/rooms/!abc123:localhost/send/m.room.message/txn123")

      refute String.contains?(result, "!abc123:localhost"),
             "the raw room ID must not survive normalization, got: #{inspect(result)}"

      assert String.contains?(result, ":room_id"),
             "expected a :room_id placeholder in the normalized route, got: #{inspect(result)}"
    end

    test "a Matrix user ID segment is replaced with a placeholder, not left raw" do
      result = RouteNormalizer.normalize_route("/users/@alice:localhost/account")

      refute String.contains?(result, "@alice:localhost"),
             "the raw user ID must not survive normalization, got: #{inspect(result)}"

      assert String.contains?(result, ":user_id"),
             "expected a :user_id placeholder in the normalized route, got: #{inspect(result)}"
    end

    test "/sync (no path parameters) is returned unchanged" do
      assert RouteNormalizer.normalize_route("/sync") == "/sync"
    end

    test "the full unauthenticated sync path is returned unchanged (war-room-mode safety scoping depends on this matching exactly)" do
      assert RouteNormalizer.normalize_route("/_matrix/client/v3/sync") ==
               "/_matrix/client/v3/sync"
    end

    test "is a pure function: calling it twice on the same input yields the same output" do
      path = "/rooms/!room1:localhost/send/m.room.message/txn-a"
      assert RouteNormalizer.normalize_route(path) == RouteNormalizer.normalize_route(path)
    end

    test "is safe on nil input (does not raise)" do
      assert RouteNormalizer.normalize_route(nil) in [nil, ""]
    end

    test "is safe on empty-string input (does not raise)" do
      assert RouteNormalizer.normalize_route("") == ""
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Oracle gate — state_key MUST NOT leak, even when not ID-shaped
  # ══════════════════════════════════════════════════════════════════════════

  describe "Oracle gate: PUT .../state/{eventType}/{stateKey} never leaks a non-ID-shaped state_key" do
    test "a plain-text, non-UUID-shaped state_key does not appear verbatim in the normalized route" do
      result =
        RouteNormalizer.normalize_route(
          "/rooms/!abc:localhost/state/m.room.topic/my-custom-state-key"
        )

      refute String.contains?(result, "my-custom-state-key"),
             "a naive opaque-ID-shaped regex (e.g. [a-f0-9\\-]{32,}) would NOT match this " <>
               "plain-text state_key and would leak it verbatim — got: #{inspect(result)}"
    end

    test "an empty state_key segment (trailing slash) does not raise and is handled" do
      result = RouteNormalizer.normalize_route("/rooms/!abc:localhost/state/m.room.topic/")

      assert is_binary(result)
    end

    test "a state_key containing punctuation/whitespace-shaped text does not appear verbatim" do
      result =
        RouteNormalizer.normalize_route(
          "/rooms/!abc:localhost/state/m.room.member/some sensitive; text!"
        )

      refute String.contains?(result, "some sensitive; text!"),
             "punctuation/whitespace-shaped state_key content must not survive normalization, " <>
               "got: #{inspect(result)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Oracle gate — room alias segments (#localpart:domain, percent-encoded)
  # ══════════════════════════════════════════════════════════════════════════

  describe "Oracle gate: room alias segments do not fail-open" do
    test "a literal room alias (#localpart:domain) is not left raw in the normalized route" do
      result =
        RouteNormalizer.normalize_route("/directory/room/%23project-team%3Amatrix.org")

      refute String.contains?(result, "project-team"),
             "the human-readable alias localpart must not survive normalization, " <>
               "got: #{inspect(result)}"
    end

    test "a percent-encoded room alias variant (%23...%3A) is not left raw in the normalized route" do
      result =
        RouteNormalizer.normalize_route(
          "/_matrix/client/v3/directory/room/%23secret-support-room%3Alocalhost"
        )

      refute String.contains?(result, "secret-support-room"),
             "a percent-encoded #room:domain alias must not survive normalization " <>
               "(fail-open), got: #{inspect(result)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # code-review M2 — txn_id, device_id, event_type must not leak raw for
  # realistic (non-hex) client-chosen values, not just hex/UUID-shaped ones
  # ══════════════════════════════════════════════════════════════════════════

  describe "code-review M2: txn_id/device_id/event_type do not leak for realistic non-hex values" do
    test "a short, non-hex txn_id on a send-event route does not survive normalization" do
      result =
        RouteNormalizer.normalize_route(
          "/_matrix/client/v3/rooms/!abc:localhost/send/m.room.message/m1234567890"
        )

      refute String.contains?(result, "m1234567890"),
             "the realistic, non-hex client-chosen txn_id must not leak verbatim, " <>
               "got: #{inspect(result)}"

      refute String.contains?(result, "m.room.message"),
             "the event_type segment must also be replaced with a placeholder for " <>
               "consistent endpoint-level grouping, got: #{inspect(result)}"

      assert String.contains?(result, ":txn_id")
      assert String.contains?(result, ":event_type")
    end

    test "a short, non-hex device_id on /devices/{deviceId} does not survive normalization" do
      result = RouteNormalizer.normalize_route("/_matrix/client/v3/devices/ABCDEFGHIJ")

      refute String.contains?(result, "ABCDEFGHIJ"),
             "the realistic, non-hex device_id must not leak verbatim, got: #{inspect(result)}"

      assert String.contains?(result, ":device_id")
    end

    test "a redact route's txn_id does not survive normalization (event_id keeps its sigil-based placeholder)" do
      result =
        RouteNormalizer.normalize_route(
          "/_matrix/client/v3/rooms/!abc:localhost/redact/$event123:localhost/m9876543210"
        )

      refute String.contains?(result, "m9876543210"),
             "the redact route's txn_id must not leak verbatim, got: #{inspect(result)}"

      assert String.contains?(result, ":event_id")
      assert String.contains?(result, ":txn_id")
    end

    test "an account_data type segment does not survive normalization" do
      result =
        RouteNormalizer.normalize_route(
          "/_matrix/client/v3/user/@alice:localhost/account_data/com.example.custom_type"
        )

      refute String.contains?(result, "com.example.custom_type"),
             "the account-data type segment must not leak verbatim, got: #{inspect(result)}"

      assert String.contains?(result, ":type")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Oracle gate — Unicode / "+" / historical-format user localparts
  # ══════════════════════════════════════════════════════════════════════════

  describe "Oracle gate: non-ASCII / historical-format user localparts do not fail-open" do
    test "a Unicode localpart is not left raw in the normalized route" do
      result = RouteNormalizer.normalize_route("/users/@böyle_kullanıcı:example.org/account")

      refute String.contains?(result, "böyle_kullanıcı"),
             "a Unicode user localpart must not survive normalization (an ASCII-only " <>
               "character class like [^:]+ combined with byte-oriented matching can still " <>
               "silently pass this through), got: #{inspect(result)}"
    end

    test "a historical-format localpart containing '+' is not left raw in the normalized route" do
      result = RouteNormalizer.normalize_route("/users/@user+tag:example.org/account")

      refute String.contains?(result, "user+tag"),
             "a '+'-containing historical-format localpart must not survive normalization, " <>
               "got: #{inspect(result)}"
    end

    test "a percent-encoded historical-format localpart containing an encoded '/' is not left raw" do
      result =
        RouteNormalizer.normalize_route(
          "/rooms/!room:localhost/state/m.room.member/%40historical%2Buser%2Fname%3Adomain"
        )

      refute String.contains?(result, "historical"),
             "a percent-encoded historical-format user identifier (containing an encoded " <>
               "'/') must not survive normalization when it appears as a state_key segment, " <>
               "got: #{inspect(result)}"
    end
  end
end
