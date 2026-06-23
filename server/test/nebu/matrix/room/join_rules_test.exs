defmodule Nebu.Matrix.Room.JoinRulesTest do
  @moduledoc """
  Pure-decision unit tests for the MSC3083 `restricted` join rule
  (epic spaces-elixir, story s4-restricted-join).

  These tests are written FIRST (ATDD gate) and inject the
  `space_member?` resolver + `has_invite?` flag, so they are Repo-less and
  do not start any GenServer. They exercise the decision table directly.

  Covers Acceptance Tests 1-6:
    AT1 — restricted + member of an allow-space          → :ok
    AT2 — restricted + non-member, no invite             → {:error, :forbidden}
    AT3 — restricted + pending invite (overrides)        → :ok
    AT4 — allow[] validation: bad type / missing room_id / malformed → no grant
    AT5 — public / invite / default / absent join_rule   → :ok (unchanged behaviour)
    AT6 — no-leak: non-existent allow-room and existing-but-not-member allow-room
          deny identically (both {:error, :forbidden})
  """

  use ExUnit.Case, async: true

  alias Nebu.Matrix.Room.JoinRules

  @user "@alice:test.local"

  # Build a minimal room_state shaped like build_state_events/2 output: a list of
  # %{type:, state_key:, content:} maps. content is a JSON string (as persisted)
  # so JoinRules must decode it (mirroring how the server reads join_rules).
  defp join_rules_state(content_map) do
    [
      %{type: "m.room.create", state_key: "", content: ~s({"room_version":"10"})},
      %{
        type: "m.room.join_rules",
        state_key: "",
        content: Jason.encode!(content_map)
      }
    ]
  end

  # space_member? resolver that returns true only for the given (room, user) pairs.
  defp member_of(pairs) do
    fn room_id, user_id -> {room_id, user_id} in pairs end
  end

  defp never_member, do: fn _room, _user -> false end

  describe "non-restricted join rules are unchanged (AT5)" do
    test "public → :ok" do
      state = join_rules_state(%{"join_rule" => "public"})

      assert :ok =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: never_member()
               )
    end

    test "invite → :ok (this story does not newly restrict invite)" do
      state = join_rules_state(%{"join_rule" => "invite"})

      assert :ok =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: never_member()
               )
    end

    test "absent m.room.join_rules (default) → :ok" do
      state = [%{type: "m.room.create", state_key: "", content: "{}"}]

      assert :ok =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: never_member()
               )
    end

    test "unknown join_rule → :ok (only `restricted` is gated by this story)" do
      state = join_rules_state(%{"join_rule" => "knock"})

      assert :ok =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: never_member()
               )
    end
  end

  describe "restricted join rule (AT1 / AT2 / AT3)" do
    test "AT1 — member of an allow-space → :ok" do
      state =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [%{"type" => "m.room_membership", "room_id" => "!space:test.local"}]
        })

      assert :ok =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: member_of([{"!space:test.local", @user}])
               )
    end

    test "AT2 — non-member of any allow-space and no invite → {:error, :forbidden}" do
      state =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [%{"type" => "m.room_membership", "room_id" => "!space:test.local"}]
        })

      assert {:error, :forbidden} =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: never_member()
               )
    end

    test "AT3 — pending invite overrides restricted (no space membership needed) → :ok" do
      state =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [%{"type" => "m.room_membership", "room_id" => "!space:test.local"}]
        })

      assert :ok =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: true,
                 space_member?: never_member()
               )
    end

    test "member of ANY one of several allow-spaces → :ok" do
      state =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [
            %{"type" => "m.room_membership", "room_id" => "!space-a:test.local"},
            %{"type" => "m.room_membership", "room_id" => "!space-b:test.local"}
          ]
        })

      assert :ok =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: member_of([{"!space-b:test.local", @user}])
               )
    end
  end

  describe "allow[] validation (AT4)" do
    test "entry without type m.room_membership is ignored → no grant (only invite)" do
      state =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [%{"type" => "m.something.else", "room_id" => "!space:test.local"}]
        })

      # Even though the user IS a member of that room_id, the malformed type means
      # the entry must be filtered out — only an invite could grant access.
      assert {:error, :forbidden} =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: member_of([{"!space:test.local", @user}])
               )
    end

    test "entry missing room_id is ignored → no grant" do
      state =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [%{"type" => "m.room_membership"}]
        })

      assert {:error, :forbidden} =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: fn _r, _u -> true end
               )
    end

    test "entry with non-binary / empty room_id is ignored → no grant" do
      state =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [
            %{"type" => "m.room_membership", "room_id" => ""},
            %{"type" => "m.room_membership", "room_id" => 123}
          ]
        })

      assert {:error, :forbidden} =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: fn _r, _u -> true end
               )
    end

    test "malformed allow (not a list) on restricted → behaves invite-only, no crash" do
      state =
        join_rules_state(%{"join_rule" => "restricted", "allow" => "not-a-list"})

      # No space can grant — only an invite.
      assert {:error, :forbidden} =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: fn _r, _u -> true end
               )

      assert :ok =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: true,
                 space_member?: never_member()
               )
    end

    test "empty allow array on restricted → invite-only" do
      state = join_rules_state(%{"join_rule" => "restricted", "allow" => []})

      assert {:error, :forbidden} =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: fn _r, _u -> true end
               )
    end

    test "missing allow key on restricted → invite-only" do
      state = join_rules_state(%{"join_rule" => "restricted"})

      assert {:error, :forbidden} =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: fn _r, _u -> true end
               )
    end

    test "non-map entries inside allow are ignored, valid ones still honoured" do
      state =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [
            "garbage",
            42,
            %{"type" => "m.room_membership", "room_id" => "!space:test.local"}
          ]
        })

      assert :ok =
               JoinRules.check_join_allowed(state, @user,
                 has_invite?: false,
                 space_member?: member_of([{"!space:test.local", @user}])
               )
    end
  end

  describe "no info leak (AT6)" do
    test "non-existent allow-room and existing-but-not-member allow-room deny identically" do
      # Case A: the allow-room does not exist → resolver returns false (no crash).
      state_nonexistent =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [%{"type" => "m.room_membership", "room_id" => "!ghost:test.local"}]
        })

      # Case B: the allow-room exists but the user is not a member → resolver false.
      state_not_member =
        join_rules_state(%{
          "join_rule" => "restricted",
          "allow" => [%{"type" => "m.room_membership", "room_id" => "!real:test.local"}]
        })

      result_a =
        JoinRules.check_join_allowed(state_nonexistent, @user,
          has_invite?: false,
          space_member?: never_member()
        )

      result_b =
        JoinRules.check_join_allowed(state_not_member, @user,
          has_invite?: false,
          space_member?: never_member()
        )

      assert result_a == {:error, :forbidden}
      assert result_b == {:error, :forbidden}
      assert result_a == result_b
    end
  end
end
