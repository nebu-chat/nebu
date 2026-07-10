defmodule Nebu.Admin.WarRoomManagerExclusiveScopeTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/war-room-dedicated-page`
  (AC9/AC10 + Dev Notes item 7 — `Nebu.Admin.WarRoomManager.start_session/1`
  accepting and DEFENSE-IN-DEPTH validating an optional `:exclusive_scope`
  parameter).

  Story: docs/stories/enhanced-logging/war-room-dedicated-page.md

  ## Why these MUST FAIL right now

  `start_session/1` does not accept/persist `:exclusive_scope` at all yet,
  and the `war_room_sessions.exclusive_scope` column does not exist (see
  `war_room_exclusive_scope_test.exs` for the column's own schema-contract
  test). Every test below fails either with a Postgres
  `column "exclusive_scope" does not exist` error (once a naive
  implementation tries to persist it) or, for the pure-validation tests, a
  `FunctionClauseError`/wrong-return-shape because the validation branch does
  not exist in `Nebu.Admin.WarRoomManager` at all.

  ## Contract pinned by this file

    * `start_session/1` accepts an optional `:exclusive_scope` key: `nil`
      (default, unchanged) or a list of route-template strings.
    * Dev Notes item 7 (defense-in-depth): the LiveView form's own
      checkbox/dropdown UI is NOT the trust boundary — a caller invoking
      `Nebu.Admin.WarRoomManager.start_session/1` DIRECTLY (bypassing the
      LiveView form entirely, exactly like `war_room_manager_test.exs`'s own
      "F-1" describe block already does for `max_entries`/`max_duration_s`)
      must still be rejected for a malformed `exclusive_scope`.
    * AC9 explicitly allows a free-text "other" custom route (not just the
      canonical `long_polling_endpoints/0` members) — so validation here is
      SHAPE validation (every element is a non-empty string that looks like
      an absolute route path, i.e. starts with `/`), not a closed allowlist
      check. This still closes the "arbitrary non-string/injection payload"
      class of defense-in-depth gap Dev Notes item 7 asks for, without
      contradicting AC9's own free-text allowance.
    * Every member of `Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints/0`
      (amendment 5 — the canonical, reused off-list; NOT a hardcoded parallel
      list) is always accepted.
    * A rejected `exclusive_scope` returns `{:error, :invalid_params,
      message}` — same error shape the existing `max_entries`/
      `max_duration_s` bounds violations already use — and must NOT create
      any session row (all-or-nothing, mirrors the existing bounds-violation
      tests).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    Nebu.Release.migrate()

    on_exit(fn ->
      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE 'distinctive-wrm-excl-test-%'",
          []
        )
      end
    end)

    :ok
  end

  defp run_id, do: "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
  defp new_started_by, do: "distinctive-wrm-excl-test-#{run_id()}"

  defp end_all_active! do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' WHERE ended_at IS NULL",
      []
    )
  end

  defp active_session_count do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "SELECT count(*) FROM war_room_sessions WHERE ended_at IS NULL",
        []
      )

    [[count]] = result.rows
    count
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Amendment 5: long_polling_endpoints/0 is the canonical source, reused here
  # ══════════════════════════════════════════════════════════════════════════

  describe "amendment 5: every canonical long-polling endpoint is accepted as an exclusive_scope entry" do
    test "start_session/1 accepts exclusive_scope containing every long_polling_endpoints/0 member" do
      end_all_active!()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "exclusive scope with the canonical off-list",
          scope: "all",
          exclusive_scope: Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints(),
          max_entries: 100,
          max_duration_s: 300
        })

      assert session.exclusive_scope == Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints()
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3/optional param — persisted as given, omitted defaults to nil
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC9/AC10: exclusive_scope is optional and persisted as given" do
    test "omitted exclusive_scope defaults to nil, unchanged from the pre-existing contract" do
      end_all_active!()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "no exclusive_scope given",
          max_entries: 100,
          max_duration_s: 300
        })

      assert is_nil(session.exclusive_scope)
    end

    test "AC9's free-text 'other' custom route (not in the canonical off-list) is accepted when it has route-path shape" do
      end_all_active!()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "custom exclusive route via the 'other' input",
          scope: "all",
          exclusive_scope: ["/admin/very/custom/noisy-route"],
          max_entries: 100,
          max_duration_s: 300
        })

      assert session.exclusive_scope == ["/admin/very/custom/noisy-route"]
    end

    test "an empty list is accepted and persisted as an empty list (or nil), never an error" do
      end_all_active!()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "empty exclusive_scope list",
          scope: "all",
          exclusive_scope: [],
          max_entries: 100,
          max_duration_s: 300
        })

      assert session.exclusive_scope in [nil, []]
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Dev Notes item 7 — defense-in-depth shape validation, called DIRECTLY
  # ══════════════════════════════════════════════════════════════════════════

  describe "Dev Notes item 7: start_session/1 rejects a malformed exclusive_scope, called directly" do
    test "rejects a non-list exclusive_scope (e.g. a bare string)" do
      end_all_active!()

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "exclusive_scope is a bare string, not a list",
          scope: "all",
          exclusive_scope: "/_matrix/client/v3/sync",
          max_entries: 100,
          max_duration_s: 300
        })

      assert {:error, :invalid_params, message} = result
      assert message =~ "exclusive_scope"
      assert active_session_count() == 0,
             "a malformed exclusive_scope must NOT create a session"
    end

    test "rejects a list containing a non-string element" do
      end_all_active!()

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "exclusive_scope list has a non-string element",
          scope: "all",
          exclusive_scope: ["/health", 123],
          max_entries: 100,
          max_duration_s: 300
        })

      assert {:error, :invalid_params, message} = result
      assert message =~ "exclusive_scope"
      assert active_session_count() == 0
    end

    test "rejects an entry that does not look like an absolute route path (does not start with '/')" do
      end_all_active!()

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "exclusive_scope entry is not a route path — defense-in-depth shape check",
          scope: "all",
          exclusive_scope: ["not-a-route; DROP TABLE war_room_sessions;"],
          max_entries: 100,
          max_duration_s: 300
        })

      assert {:error, :invalid_params, message} = result
      assert message =~ "exclusive_scope"
      assert active_session_count() == 0,
             "the defense-in-depth shape check must reject this even though the LiveView's " <>
               "own checkbox/text-input UI would never produce it directly"
    end

    test "rejects an empty-string entry" do
      end_all_active!()

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "exclusive_scope contains a blank entry",
          scope: "all",
          exclusive_scope: [""],
          max_entries: 100,
          max_duration_s: 300
        })

      assert {:error, :invalid_params, _message} = result
      assert active_session_count() == 0
    end
  end
end
