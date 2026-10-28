defmodule Nebu.Matrix.Room.JoinRulesTest do
  @moduledoc """
  Pure-decision unit tests for the join decision (`Nebu.Matrix.Room.JoinRules`): the MSC3083 `restricted` join rule
  (epic spaces-elixir, story s4-restricted-join) and, since story `create-room-presets-power-levels-topic` (epic
  oauth-broker, follow-up `ec`, decision D1), the enforcement of EVERY join rule and of bans.

  These tests inject the `space_member?` resolver, the `has_invite?` flag and the `banned?` flag, so they are Repo-less and
  do not start any GenServer. They exercise the decision table directly.

  Covers:
    AT1 - restricted + member of an allow-space          -> :ok
    AT2 - restricted + non-member, no invite             -> {:error, :forbidden}
    AT3 - restricted + pending invite (overrides)        -> :ok
    AT4 - allow[] validation: bad type / missing room_id / malformed -> no grant
    AT5 - (INVERTED by the story above; was "public / invite / default / absent / unknown -> :ok", the open-join hole `ec`)
          absent / invite / knock  -> :ok ONLY with a pending invite; public -> :ok;
          private / unknown / malformed -> {:error, :forbidden} with AND without invite (strict room v10)
    AT6 - no-leak: non-existent allow-room and existing-but-not-member allow-room deny identically
    AT7 - banned?: true -> {:error, :forbidden} for EVERY row (ban is decided before the rule)
    AT8 - knock_restricted decides like restricted

  The absent rule is treated as `invite` (Nebu / Synapse POLICY, not spec text: strict v10 would reject every join). An
  m.room.join_rules event that EXISTS but is malformed is not "absent": it denies always.
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

  # state helpers for the AT5 table
  defp state_with_content(raw_content), do: [%{type: "m.room.create", state_key: "", content: ~s({"room_version":"10"})}, %{type: "m.room.join_rules", state_key: "", content: raw_content}]
  defp absent_state, do: [%{type: "m.room.create", state_key: "", content: ~s({"room_version":"10"})}]

  defp decide(state, opts), do: JoinRules.check_join_allowed(state, @user, Keyword.merge([space_member?: never_member()], opts))

  describe "AT5 (inverted) - the join rule is enforced for every rule" do
    test "public -> :ok without an invite and with one" do
      state = join_rules_state(%{"join_rule" => "public"})
      assert :ok = decide(state, has_invite?: false)
      assert :ok = decide(state, has_invite?: true)
    end

    test "invite -> {:error, :forbidden} without an invite, :ok with a pending invite (was :ok without: the open-join hole)" do
      state = join_rules_state(%{"join_rule" => "invite"})
      assert {:error, :forbidden} = decide(state, has_invite?: false)
      assert :ok = decide(state, has_invite?: true)
    end

    test "knock -> {:error, :forbidden} without an invite, :ok with a pending invite (v10: invite / knock accept an existing invite)" do
      state = join_rules_state(%{"join_rule" => "knock"})
      assert {:error, :forbidden} = decide(state, has_invite?: false)
      assert :ok = decide(state, has_invite?: true)
    end

    test "absent m.room.join_rules (no event at all) -> invite POLICY: {:error, :forbidden} without an invite, :ok with one" do
      for {label, state} <- [create_only: absent_state(), empty_state: []] do
        assert {:error, :forbidden} = decide(state, has_invite?: false), to_string(label)
        assert :ok = decide(state, has_invite?: true), to_string(label)
      end
    end

    test "has_invite? defaults to false when the option is not given" do
      assert {:error, :forbidden} = JoinRules.check_join_allowed(join_rules_state(%{"join_rule" => "invite"}), @user, space_member?: never_member())
      assert {:error, :forbidden} = JoinRules.check_join_allowed(absent_state(), @user, [])
    end

    test "an m.room.join_rules event with a NON-EMPTY state_key is not the room's join rule: the room counts as absent (invite policy)" do
      state = [%{type: "m.room.join_rules", state_key: "x", content: ~s({"join_rule":"public"})}]
      assert {:error, :forbidden} = decide(state, has_invite?: false)
      assert :ok = decide(state, has_invite?: true)
    end

    test "private (reserved by the spec) -> {:error, :forbidden} WITHOUT and WITH a pending invite (strict v10: only invite / knock accept an invite)" do
      state = join_rules_state(%{"join_rule" => "private"})
      assert {:error, :forbidden} = decide(state, has_invite?: false)
      assert {:error, :forbidden} = decide(state, has_invite?: true)
    end

    test "an unknown join_rule string -> {:error, :forbidden} WITHOUT and WITH a pending invite" do
      for rule <- ["foo", "Public", "INVITE", " invite", "invite ", "publik", "restricted2"] do
        state = join_rules_state(%{"join_rule" => rule})
        assert {:error, :forbidden} = decide(state, has_invite?: false), inspect(rule)
        assert {:error, :forbidden} = decide(state, has_invite?: true), inspect(rule)
      end
    end

    test "a MALFORMED m.room.join_rules event (empty / non-string / missing join_rule, undecodable) -> forbidden WITHOUT and WITH an invite" do
      for {label, raw} <- [
            empty_string_rule: Jason.encode!(%{"join_rule" => ""}),
            number_rule: Jason.encode!(%{"join_rule" => 5}),
            null_rule: Jason.encode!(%{"join_rule" => nil}),
            list_rule: Jason.encode!(%{"join_rule" => ["public"]}),
            object_rule: Jason.encode!(%{"join_rule" => %{"x" => "public"}}),
            empty_content: "{}",
            content_without_rule: Jason.encode!(%{"allow" => []}),
            not_json: "this is not json",
            truncated_json: ~s({"join_rule":"pub),
            json_array: "[\"public\"]",
            json_string: ~s("public"),
            empty_binary: "",
            nil_content: nil
          ] do
        state = state_with_content(raw)
        assert {:error, :forbidden} = decide(state, has_invite?: false), "#{label} without an invite"
        assert {:error, :forbidden} = decide(state, has_invite?: true), "#{label} with an invite"
      end
    end

    test "a double-encoded content (a JSON string that holds the JSON, legacy writer) is read as the rule it holds; a string that is no JSON object stays malformed" do
      double = fn map -> map |> Jason.encode!() |> Jason.encode!() end

      assert :ok = decide(state_with_content(double.(%{"join_rule" => "public"})), has_invite?: false)
      assert {:error, :forbidden} = decide(state_with_content(double.(%{"join_rule" => "invite"})), has_invite?: false)
      assert :ok = decide(state_with_content(double.(%{"join_rule" => "invite"})), has_invite?: true)
      assert {:error, :forbidden} = decide(state_with_content(double.(%{"join_rule" => "private"})), has_invite?: true)
      assert {:error, :forbidden} = decide(state_with_content(double.(%{})), has_invite?: true)
      assert {:error, :forbidden} = decide(state_with_content(Jason.encode!(Jason.encode!("public"))), has_invite?: true), "a string that holds a string"
      assert {:error, :forbidden} = decide(state_with_content(Jason.encode!("not json")), has_invite?: true)
    end

    test "a decoded map as content is read like its JSON text (public -> :ok, malformed map -> denied)" do
      assert :ok = decide(state_with_content(%{"join_rule" => "public"}), has_invite?: false)
      assert {:error, :forbidden} = decide(state_with_content(%{"join_rule" => "private"}), has_invite?: true)
      assert {:error, :forbidden} = decide(state_with_content(%{}), has_invite?: true)
    end
  end

  # ── AT7: a ban is decided before the rule ───────────────────────────────────

  describe "AT7 - banned?: true is {:error, :forbidden} for every row of the table" do
    @restricted_allow [%{"type" => "m.room_membership", "room_id" => "!space:test.local"}]

    defp every_row do
      [
        {"absent", absent_state()},
        {"empty state", []},
        {"public", join_rules_state(%{"join_rule" => "public"})},
        {"invite", join_rules_state(%{"join_rule" => "invite"})},
        {"knock", join_rules_state(%{"join_rule" => "knock"})},
        {"restricted", join_rules_state(%{"join_rule" => "restricted", "allow" => @restricted_allow})},
        {"knock_restricted", join_rules_state(%{"join_rule" => "knock_restricted", "allow" => @restricted_allow})},
        {"private", join_rules_state(%{"join_rule" => "private"})},
        {"unknown", join_rules_state(%{"join_rule" => "foo"})},
        {"malformed", state_with_content("{}")},
        {"undecodable", state_with_content("not json")}
      ]
    end

    test "with AND without a pending invite, also for an allow-room member" do
      for {label, state} <- every_row(), invite? <- [false, true] do
        assert {:error, :forbidden} =
                 JoinRules.check_join_allowed(state, @user, banned?: true, has_invite?: invite?, space_member?: member_of([{"!space:test.local", @user}])),
               "#{label} (has_invite?: #{invite?})"
      end
    end

    test "banned?: false (and the option absent) decides exactly like the table: a public room and an invited user are :ok" do
      assert :ok = JoinRules.check_join_allowed(join_rules_state(%{"join_rule" => "public"}), @user, banned?: false, space_member?: never_member())
      assert :ok = JoinRules.check_join_allowed(join_rules_state(%{"join_rule" => "invite"}), @user, banned?: false, has_invite?: true, space_member?: never_member())
    end
  end

  # ── AT8: knock_restricted decides like restricted ───────────────────────────

  describe "AT8 - knock_restricted" do
    defp knock_restricted(allow), do: join_rules_state(%{"join_rule" => "knock_restricted", "allow" => allow})

    test "member of an allow-room -> :ok without an invite" do
      assert :ok = decide_with(knock_restricted(@restricted_allow), has_invite?: false, space_member?: member_of([{"!space:test.local", @user}]))
    end

    test "not a member of an allow-room and no invite -> {:error, :forbidden}" do
      assert {:error, :forbidden} = decide_with(knock_restricted(@restricted_allow), has_invite?: false, space_member?: never_member())
    end

    test "a pending invite -> :ok without any space membership" do
      assert :ok = decide_with(knock_restricted(@restricted_allow), has_invite?: true, space_member?: never_member())
    end

    test "invalid or missing allow[] behaves invite-only: {:error, :forbidden} without an invite even for a user the resolver calls a member, :ok with one" do
      for allow <- [[], "not-a-list", [%{"type" => "m.something.else", "room_id" => "!space:test.local"}], [%{"type" => "m.room_membership"}]] do
        state = knock_restricted(allow)
        assert {:error, :forbidden} = decide_with(state, has_invite?: false, space_member?: fn _r, _u -> true end), inspect(allow)
        assert :ok = decide_with(state, has_invite?: true, space_member?: never_member()), inspect(allow)
      end

      no_allow = join_rules_state(%{"join_rule" => "knock_restricted"})
      assert {:error, :forbidden} = decide_with(no_allow, has_invite?: false, space_member?: fn _r, _u -> true end)
    end

    test "the allow-room decision is no-leak here too: a ghost room and a real room the user is not in deny identically" do
      ghost = knock_restricted([%{"type" => "m.room_membership", "room_id" => "!ghost:test.local"}])
      real = knock_restricted([%{"type" => "m.room_membership", "room_id" => "!real:test.local"}])

      assert decide_with(ghost, has_invite?: false, space_member?: never_member()) == decide_with(real, has_invite?: false, space_member?: never_member())
      assert {:error, :forbidden} = decide_with(ghost, has_invite?: false, space_member?: never_member())
    end
  end

  defp decide_with(state, opts), do: JoinRules.check_join_allowed(state, @user, opts)

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
