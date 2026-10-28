defmodule Nebu.Web.RateLimitTiersTest do
  @moduledoc """
  Story `rate-limits-join-invite-create-room` (epic oauth-broker, follow-up `ey`), AC2 (unit, no DB): the tier configuration (D1, D4) and
  the pending-invitation cap defaults (D6).

  ## Names pinned by this suite (the story leaves them open; see the report of the ATDD step)

    * `Nebu.Web.RateLimitTiers` (plain module, no state, config accessors only):
        - `create_room/0`, `invite/0`, `join/0` -> `{rate_per_min, burst}`, read at REQUEST time from `Application.get_env(:nebu_http, ...)`
          (keys `:rate_limit_<tier>_per_min` / `:rate_limit_<tier>_burst`) with the D1 defaults `{10, 20}`, `{20, 50}`, `{12, 30}`;
        - a configured pair that breaks an invariant (`burst / rate_per_min > 60`: the sweeper's one-hour argument; for `invite`
          additionally `burst < invite_max_entries()`) falls back to the DEFAULT PAIR of that tier; a half-configured pair (one value
          absent) takes the default for the absent value and is checked as a pair;
        - `invalid_settings/0` -> a list of ENV VARIABLE NAMES (strings): for each rejected tier pair the names of the tier's two
          variables (`NEBU_RATE_LIMIT_<TIER>_PER_MIN`, `NEBU_RATE_LIMIT_<TIER>_BURST`), `[]` when nothing is rejected;
        - `warn_invalid_settings/0` -> `:ok`: ONE `Logger.warning` per entry of `invalid_settings/0`, naming the variable and the rule,
          NEVER the configured value; called by `Nebu.Application.start/2` (pinned statically below).
    * `Nebu.Matrix.EventDispatcher.Server` (the core): `invite_max_entries/0` -> 50 (the existing `@invite_max_entries`, made public so
      the invariant test reads it instead of copying the literal) and `invite_max_pending/0` ->
      `%{per_inviter: 500, per_invitee: 100, per_pair: 10}`, read at call time from `Application.get_env(:nebu, :invite_max_pending_per_inviter |
      _per_invitee | _per_pair)`.
    * `config/runtime.exs` parsing: tested with `Config.Reader.read!/2` of the real file (`env: :dev`) under a patched OS environment (there
      is no earlier parsing test for the room-account-data variables to copy: this is the pattern, recorded in the report).

  Story `moderation-routes-atomic-ban` (AC2, unit part, D5) extends this suite: the tier `moderation/0` (default `{30, 60}`, the env pair
  `NEBU_RATE_LIMIT_MODERATION_PER_MIN` / `_BURST`, the same invariants and `invalid_settings/0` as the other tiers) is pinned in the last describe
  block; `@tier_keys`, `@env_vars` and `@env_to_key` carry the two new variables, so every generic runtime.exs / junk test below covers them too.
  The `docker-compose.yml` names are pinned by `moderation_routes_docs_test.exs`.

  `async: false`: the OS environment and the application env are process-global; everything is snapshotted and restored in `on_exit`.
  The functions that do not exist yet are reached through `apply/3` with a variable name, so the file compiles without warnings.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @tiers Nebu.Web.RateLimitTiers
  @core Nebu.Matrix.EventDispatcher.Server
  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  @tier_keys for tier <- ~w(create_room invite join moderation members_read)a, suffix <- ~w(per_min burst)a, do: String.to_atom("rate_limit_#{tier}_#{suffix}")
  @cap_keys [:invite_max_pending_per_inviter, :invite_max_pending_per_invitee, :invite_max_pending_per_pair]
  @env_vars ~w(NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN NEBU_RATE_LIMIT_CREATE_ROOM_BURST NEBU_RATE_LIMIT_INVITE_PER_MIN NEBU_RATE_LIMIT_INVITE_BURST
               NEBU_RATE_LIMIT_JOIN_PER_MIN NEBU_RATE_LIMIT_JOIN_BURST NEBU_RATE_LIMIT_MODERATION_PER_MIN NEBU_RATE_LIMIT_MODERATION_BURST
               NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN NEBU_RATE_LIMIT_MEMBERS_READ_BURST
               NEBU_INVITE_MAX_PENDING_PER_INVITER NEBU_INVITE_MAX_PENDING_PER_INVITEE
               NEBU_INVITE_MAX_PENDING_PER_PAIR)
  @env_to_key %{
    "NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN" => {:nebu_http, :rate_limit_create_room_per_min},
    "NEBU_RATE_LIMIT_CREATE_ROOM_BURST" => {:nebu_http, :rate_limit_create_room_burst},
    "NEBU_RATE_LIMIT_INVITE_PER_MIN" => {:nebu_http, :rate_limit_invite_per_min},
    "NEBU_RATE_LIMIT_INVITE_BURST" => {:nebu_http, :rate_limit_invite_burst},
    "NEBU_RATE_LIMIT_JOIN_PER_MIN" => {:nebu_http, :rate_limit_join_per_min},
    "NEBU_RATE_LIMIT_JOIN_BURST" => {:nebu_http, :rate_limit_join_burst},
    "NEBU_RATE_LIMIT_MODERATION_PER_MIN" => {:nebu_http, :rate_limit_moderation_per_min},
    "NEBU_RATE_LIMIT_MODERATION_BURST" => {:nebu_http, :rate_limit_moderation_burst},
    "NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN" => {:nebu_http, :rate_limit_members_read_per_min},
    "NEBU_RATE_LIMIT_MEMBERS_READ_BURST" => {:nebu_http, :rate_limit_members_read_burst},
    "NEBU_INVITE_MAX_PENDING_PER_INVITER" => {:nebu, :invite_max_pending_per_inviter},
    "NEBU_INVITE_MAX_PENDING_PER_INVITEE" => {:nebu, :invite_max_pending_per_invitee},
    "NEBU_INVITE_MAX_PENDING_PER_PAIR" => {:nebu, :invite_max_pending_per_pair}
  }
  # runtime.exs in :dev needs these two (it raises without them); the values are throwaway and only live during the read
  @required_env %{"NEBU_DB_URL" => "postgresql://u:p@localhost:5432/atdd", "NEBU_PII_ENCRYPTION_KEY" => String.duplicate("ab", 32)}

  setup do
    app_snapshot =
      for {app, keys} <- [nebu_http: @tier_keys, nebu: @cap_keys], key <- keys, do: {app, key, Application.fetch_env(app, key)}

    for {app, key, _} <- app_snapshot, do: Application.delete_env(app, key)

    # EVERY NEBU_* variable is snapshotted: runtime.exs reads many of them (*_FILE paths, ports, keys) and an ambient one could change or
    # raise the read below
    env_snapshot = for {name, value} <- System.get_env(), String.starts_with?(name, "NEBU_"), do: {name, value}

    on_exit(fn ->
      for {app, key, previous} <- app_snapshot do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      for {name, _} <- System.get_env(), String.starts_with?(name, "NEBU_"), do: System.delete_env(name)
      for {name, value} <- env_snapshot, do: System.put_env(name, value)
    end)

    :ok
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp tiers(fun), do: apply(@tiers, fun, [])
  defp core(fun), do: apply(@core, fun, [])
  defp set(key, value), do: Application.put_env(:nebu_http, key, value)

  # the config `Config.Reader.read!/2` computes from the real runtime.exs with the given variables set (all others cleared)
  defp runtime_config(vars) do
    for {name, _} <- System.get_env(), String.starts_with?(name, "NEBU_"), do: System.delete_env(name)
    for {name, value} <- Map.merge(@required_env, vars), do: System.put_env(name, value)
    Config.Reader.read!(@runtime, env: :dev, target: :host)
  end

  defp config_value(config, {app, key}), do: config |> Keyword.get(app, []) |> Keyword.get(key, :unset)

  # ═══ defaults and the invariants ═══════════════════════════════════════════════════

  describe "AC2 - the defaults" do
    test "the tiers are exactly {10, 20} create_room, {20, 50} invite, {12, 30} join (rate per minute, burst)" do
      assert tiers(:create_room) == {10, 20}
      assert tiers(:invite) == {20, 50}
      assert tiers(:join) == {12, 30}
    end

    test "the pending caps are exactly 500 per inviter, 100 per invitee, 10 per inviter-invitee pair" do
      assert core(:invite_max_pending) == %{per_inviter: 500, per_invitee: 100, per_pair: 10}
    end

    test "nothing is rejected by default: invalid_settings/0 is empty" do
      assert tiers(:invalid_settings) == []
    end

    test "the sweeper invariant burst / rate_per_min <= 60 holds for every DEFAULT tier, read through the accessors (no copied literal)" do
      for fun <- [:create_room, :invite, :join] do
        {rate, burst} = tiers(fun)
        assert is_integer(rate) and rate > 0 and is_integer(burst) and burst > 0
        assert burst / rate <= 60, "#{fun}: burst #{burst} / rate #{rate} > 60 would let the sweeper grant budget"
      end
    end

    test "the invite burst is at least the createRoom invite cap, so a valid createRoom (50 invitees) is never unsatisfiable (both values read from the code)" do
      {_rate, burst} = tiers(:invite)
      assert core(:invite_max_entries) == 50
      assert burst >= core(:invite_max_entries)
    end
  end

  # ═══ configured pairs apply at request time ═════════════════════════════════════════

  describe "AC2 - configured values" do
    test "a valid pair applies at request time (no recompile, no restart), per tier, and does not leak into the other tiers" do
      set(:rate_limit_create_room_per_min, 5)
      set(:rate_limit_create_room_burst, 7)
      assert tiers(:create_room) == {5, 7}
      assert tiers(:invite) == {20, 50}
      assert tiers(:join) == {12, 30}

      set(:rate_limit_invite_per_min, 100)
      set(:rate_limit_invite_burst, 80)
      assert tiers(:invite) == {100, 80}

      set(:rate_limit_join_per_min, 1)
      set(:rate_limit_join_burst, 60)
      assert tiers(:join) == {1, 60}, "burst / rate == 60 is the boundary and is allowed"

      assert tiers(:invalid_settings) == []
    end

    test "a half-configured pair takes the default for the absent value and is checked as a pair" do
      set(:rate_limit_join_per_min, 30)
      assert tiers(:join) == {30, 30}

      set(:rate_limit_create_room_burst, 5)
      assert tiers(:create_room) == {10, 5}

      # rate 1 with the default invite burst 50: 50 / 1 <= 60, valid
      set(:rate_limit_invite_per_min, 1)
      assert tiers(:invite) == {1, 50}
    end

    test "a pair with burst / rate > 60 falls back to the DEFAULT PAIR of that tier (not to a mix), the other tiers are untouched" do
      set(:rate_limit_join_per_min, 1)
      set(:rate_limit_join_burst, 61)
      assert tiers(:join) == {12, 30}

      set(:rate_limit_create_room_per_min, 2)
      set(:rate_limit_create_room_burst, 500)
      assert tiers(:create_room) == {10, 20}

      assert tiers(:invite) == {20, 50}
    end

    test "an invite burst below the createRoom invite cap falls back to the default invite pair; exactly the cap is fine" do
      cap = core(:invite_max_entries)

      set(:rate_limit_invite_per_min, 30)
      set(:rate_limit_invite_burst, cap - 1)
      assert tiers(:invite) == {20, 50}

      set(:rate_limit_invite_burst, cap)
      assert tiers(:invite) == {30, cap}
    end

    test "the burst floor of the invite tier does not apply to the other tiers (a join burst of 1 is valid)" do
      set(:rate_limit_join_per_min, 1)
      set(:rate_limit_join_burst, 1)
      assert tiers(:join) == {1, 1}
    end
  end

  # ═══ invalid_settings/0 and the boot warning ═══════════════════════════════════════

  describe "AC2 - invalid_settings/0 and the boot warning" do
    test "invalid_settings/0 names each rejected pair by the ENV VARIABLE NAMES of its two settings" do
      set(:rate_limit_join_per_min, 1)
      set(:rate_limit_join_burst, 100)
      assert Enum.sort(tiers(:invalid_settings)) == ["NEBU_RATE_LIMIT_JOIN_BURST", "NEBU_RATE_LIMIT_JOIN_PER_MIN"]

      set(:rate_limit_invite_per_min, 100)
      set(:rate_limit_invite_burst, 10)

      assert Enum.sort(tiers(:invalid_settings)) ==
               ["NEBU_RATE_LIMIT_INVITE_BURST", "NEBU_RATE_LIMIT_INVITE_PER_MIN", "NEBU_RATE_LIMIT_JOIN_BURST", "NEBU_RATE_LIMIT_JOIN_PER_MIN"]
    end

    test "a valid configuration is not reported" do
      set(:rate_limit_join_per_min, 6)
      set(:rate_limit_join_burst, 12)
      assert tiers(:invalid_settings) == []
    end

    test "the boot warning is ONE line per rejected setting, names the variable and contains no configured value" do
      # distinctive values: any echo of them in the log would be visible
      set(:rate_limit_join_per_min, 3)
      set(:rate_limit_join_burst, 98_765)
      set(:rate_limit_invite_per_min, 4_321)
      set(:rate_limit_invite_burst, 7)

      log = capture_log([level: :warning], fn -> assert :ok = tiers(:warn_invalid_settings) end)

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "NEBU_RATE_LIMIT_"))

      for name <- tiers(:invalid_settings) do
        assert Enum.count(lines, &(&1 =~ name)) == 1, "exactly one warning line for #{name}, got #{inspect(lines)}"
      end

      assert length(lines) == length(tiers(:invalid_settings)), "no other line mentions a tier variable: #{inspect(lines)}"
      assert Enum.all?(lines, &(&1 =~ "warning")), "logged at warning level"

      for value <- ["98765", "98_765", "4321", "4_321"] do
        refute log =~ value, "the configured value #{value} must never be logged"
      end
    end

    test "a valid configuration logs nothing (no warning line without a rejected setting)" do
      set(:rate_limit_join_per_min, 6)
      set(:rate_limit_join_burst, 12)
      log = capture_log([level: :warning], fn -> assert :ok = tiers(:warn_invalid_settings) end)
      refute log =~ "NEBU_RATE_LIMIT_"
    end

    test "Nebu.Application calls the warning at boot (static pin: the log line exists only if start/2 runs the check)" do
      source = File.read!(Path.expand("../../../lib/nebu/application.ex", __DIR__))
      assert source =~ "RateLimitTiers.warn_invalid_settings"
    end
  end

  # ═══ config/runtime.exs: the nine variables ═══════════════════════════════════════

  describe "AC2 - config/runtime.exs parsing of every tier and cap variable" do
    test "each variable lands under its own key (app and name), distinct values prove the mapping" do
      vars = @env_vars |> Enum.with_index(11) |> Map.new(fn {name, n} -> {name, Integer.to_string(n)} end)
      config = runtime_config(vars)

      for {name, {app, key}} <- @env_to_key do
        assert config_value(config, {app, key}) == String.to_integer(vars[name]), "#{name} -> #{app}:#{key}"
      end
    end

    test "strictly positive int64 integers apply: 1, a plain number and the int64 maximum" do
      for value <- ["1", "42", "9223372036854775807"] do
        config = runtime_config(Map.new(@env_vars, &{&1, value}))

        for {name, target} <- @env_to_key do
          assert config_value(config, target) == String.to_integer(value), "#{name}=#{value} applies"
        end
      end
    end

    test "0, -1, abc, 1e3, the empty string, a decimal, trailing junk and a value above int64 are ignored (the default stays: no key is set, nothing crashes)" do
      # positive control: the same call with a valid value DOES set the keys (the parsing exists; "ignored" is not "never parsed")
      valid = runtime_config(Map.new(@env_vars, &{&1, "5"}))
      for {name, target} <- @env_to_key, do: assert(config_value(valid, target) == 5, "#{name}=5 applies")

      for value <- ["0", "-1", "abc", "1e3", "", "1.5", "12abc", "9223372036854775808", "99999999999999999999999"] do
        config = runtime_config(Map.new(@env_vars, &{&1, value}))

        for {name, target} <- @env_to_key do
          assert config_value(config, target) == :unset, "#{name}=#{inspect(value)} must be ignored"
        end
      end
    end

    test "unset variables set nothing (positive control: one valid variable next to eight unset ones sets exactly its own key)" do
      config = runtime_config(%{"NEBU_RATE_LIMIT_JOIN_PER_MIN" => "7"})
      assert config_value(config, {:nebu_http, :rate_limit_join_per_min}) == 7

      for {name, target} <- @env_to_key, name != "NEBU_RATE_LIMIT_JOIN_PER_MIN" do
        assert config_value(config, target) == :unset, name
      end
    end

    test "a value that passes the parsing but breaks the invariant is handled by the accessor, not by runtime.exs (the pair falls back, the boot warns)" do
      config = runtime_config(%{"NEBU_RATE_LIMIT_JOIN_PER_MIN" => "1", "NEBU_RATE_LIMIT_JOIN_BURST" => "100"})
      assert config_value(config, {:nebu_http, :rate_limit_join_per_min}) == 1
      assert config_value(config, {:nebu_http, :rate_limit_join_burst}) == 100

      for {{app, key}, value} <- [{{:nebu_http, :rate_limit_join_per_min}, 1}, {{:nebu_http, :rate_limit_join_burst}, 100}], do: Application.put_env(app, key, value)
      assert tiers(:join) == {12, 30}
      assert Enum.sort(tiers(:invalid_settings)) == ["NEBU_RATE_LIMIT_JOIN_BURST", "NEBU_RATE_LIMIT_JOIN_PER_MIN"]
    end
  end

  # ═══ the caps at call time ═════════════════════════════════════════════════════════

  describe "AC2 - the accessors never crash on junk in the application env" do
    test "0, a negative number, a float, a string and nil for a tier setting fall back to the DEFAULT pair of that tier (no division by zero)" do
      for junk <- [0, -1, 1.5, "20", nil, :on] do
        for key <- @tier_keys, do: Application.delete_env(:nebu_http, key)
        set(:rate_limit_join_per_min, junk)
        assert tiers(:join) == {12, 30}, "per_min #{inspect(junk)}"

        for key <- @tier_keys, do: Application.delete_env(:nebu_http, key)
        set(:rate_limit_join_burst, junk)
        assert tiers(:join) == {12, 30}, "burst #{inspect(junk)}"

        # the other tiers are untouched
        assert tiers(:create_room) == {10, 20}
        assert tiers(:invite) == {20, 50}
      end
    end

    test "0, a negative number, a float and a string for a cap fall back to its default" do
      for junk <- [0, -1, 1.5, "7", nil, :on], key <- @cap_keys do
        for k <- @cap_keys, do: Application.delete_env(:nebu, k)
        Application.put_env(:nebu, key, junk)
        assert core(:invite_max_pending) == %{per_inviter: 500, per_invitee: 100, per_pair: 10}, "#{key} #{inspect(junk)}"
      end
    end
  end

  describe "AC2 - the pending caps are read at call time" do
    test "Application.put_env(:nebu, :invite_max_pending_*) applies immediately and a delete restores the defaults" do
      Application.put_env(:nebu, :invite_max_pending_per_inviter, 5)
      Application.put_env(:nebu, :invite_max_pending_per_invitee, 2)
      Application.put_env(:nebu, :invite_max_pending_per_pair, 1)
      assert core(:invite_max_pending) == %{per_inviter: 5, per_invitee: 2, per_pair: 1}

      for key <- @cap_keys, do: Application.delete_env(:nebu, key)
      assert core(:invite_max_pending) == %{per_inviter: 500, per_invitee: 100, per_pair: 10}
    end
  end
  # ═══ story moderation-routes-atomic-ban (AC2, D5): the moderation tier ═══════════════════════════════

  describe "AC2 (moderation-routes-atomic-ban) - the moderation tier" do
    test "the default is exactly {30, 60} and the sweeper invariant burst / rate_per_min <= 60 holds for it" do
      assert tiers(:moderation) == {30, 60}
      {rate, burst} = tiers(:moderation)
      assert burst / rate <= 60
      assert tiers(:invalid_settings) == []
    end

    test "the other tiers keep their defaults next to it" do
      assert {tiers(:create_room), tiers(:invite), tiers(:join)} == {{10, 20}, {20, 50}, {12, 30}}
    end

    test "a valid pair applies at request time and does not leak into the other tiers (burst / rate == 60 is the boundary and allowed)" do
      set(:rate_limit_moderation_per_min, 1)
      set(:rate_limit_moderation_burst, 60)
      assert tiers(:moderation) == {1, 60}
      assert {tiers(:create_room), tiers(:invite), tiers(:join)} == {{10, 20}, {20, 50}, {12, 30}}

      set(:rate_limit_moderation_per_min, 120)
      set(:rate_limit_moderation_burst, 7)
      assert tiers(:moderation) == {120, 7}
      assert tiers(:invalid_settings) == []
    end

    test "a half-configured pair takes the default for the absent value and is checked as a pair" do
      set(:rate_limit_moderation_per_min, 100)
      assert tiers(:moderation) == {100, 60}

      Application.delete_env(:nebu_http, :rate_limit_moderation_per_min)
      set(:rate_limit_moderation_burst, 5)
      assert tiers(:moderation) == {30, 5}
    end

    test "a pair with burst / rate > 60 falls back to the DEFAULT pair {30, 60} and is named by invalid_settings/0 with both variable names" do
      set(:rate_limit_moderation_per_min, 1)
      set(:rate_limit_moderation_burst, 61)
      assert tiers(:moderation) == {30, 60}
      assert Enum.sort(tiers(:invalid_settings)) == ["NEBU_RATE_LIMIT_MODERATION_BURST", "NEBU_RATE_LIMIT_MODERATION_PER_MIN"]
    end

    test "the moderation burst has no invite-style floor: a burst of 1 is valid" do
      set(:rate_limit_moderation_per_min, 1)
      set(:rate_limit_moderation_burst, 1)
      assert tiers(:moderation) == {1, 1}
    end

    test "0, a negative number, a float, a string and nil fall back to the default pair (no division by zero)" do
      for junk <- [0, -1, 1.5, "20", nil, :on] do
        for key <- @tier_keys, do: Application.delete_env(:nebu_http, key)
        set(:rate_limit_moderation_per_min, junk)
        assert tiers(:moderation) == {30, 60}, "per_min #{inspect(junk)}"

        for key <- @tier_keys, do: Application.delete_env(:nebu_http, key)
        set(:rate_limit_moderation_burst, junk)
        assert tiers(:moderation) == {30, 60}, "burst #{inspect(junk)}"
      end
    end

    test "the boot warning names the two moderation variables once each and never the configured values" do
      set(:rate_limit_moderation_per_min, 2)
      set(:rate_limit_moderation_burst, 43_210)
      log = capture_log([level: :warning], fn -> assert :ok = tiers(:warn_invalid_settings) end)
      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "NEBU_RATE_LIMIT_MODERATION_"))
      assert length(lines) == 2
      refute log =~ "43210"
      refute log =~ "43_210"
    end

    test "config/runtime.exs: the two variables land under :rate_limit_moderation_per_min / _burst; junk is ignored; unset sets nothing" do
      config = runtime_config(%{"NEBU_RATE_LIMIT_MODERATION_PER_MIN" => "45", "NEBU_RATE_LIMIT_MODERATION_BURST" => "90"})
      assert config_value(config, {:nebu_http, :rate_limit_moderation_per_min}) == 45
      assert config_value(config, {:nebu_http, :rate_limit_moderation_burst}) == 90

      for junk <- ["0", "-3", "abc", "", "9223372036854775808"] do
        config = runtime_config(%{"NEBU_RATE_LIMIT_MODERATION_PER_MIN" => junk, "NEBU_RATE_LIMIT_MODERATION_BURST" => junk})
        assert config_value(config, {:nebu_http, :rate_limit_moderation_per_min}) == :unset, "junk #{inspect(junk)}"
        assert config_value(config, {:nebu_http, :rate_limit_moderation_burst}) == :unset
      end

      config = runtime_config(%{})
      assert config_value(config, {:nebu_http, :rate_limit_moderation_per_min}) == :unset
    end
  end
  # ═══ story membership-state-model (security cycle 1, Kassandra M-1): the members_read tier ═════════════

  describe "members_read tier (membership-state-model) - GET /members and GET /initialSync" do
    test "the default is exactly {60, 30}, the sweeper invariant holds and the other tiers keep their defaults" do
      assert tiers(:members_read) == {60, 30}
      {rate, burst} = tiers(:members_read)
      assert burst / rate <= 60
      assert tiers(:invalid_settings) == []
      assert {tiers(:create_room), tiers(:invite), tiers(:join), tiers(:moderation)} == {{10, 20}, {20, 50}, {12, 30}, {30, 60}}
    end

    test "a valid pair applies at request time (burst / rate == 60 is the boundary) and does not leak into the other tiers" do
      set(:rate_limit_members_read_per_min, 1)
      set(:rate_limit_members_read_burst, 60)
      assert tiers(:members_read) == {1, 60}
      assert tiers(:moderation) == {30, 60}

      set(:rate_limit_members_read_per_min, 120)
      set(:rate_limit_members_read_burst, 1)
      assert tiers(:members_read) == {120, 1}
      assert tiers(:invalid_settings) == []
    end

    test "a half pair takes the default for the other half and is checked as a pair: burst 4000 next to rate 60 is rejected, named and warned at boot" do
      set(:rate_limit_members_read_per_min, 100)
      assert tiers(:members_read) == {100, 30}

      Application.delete_env(:nebu_http, :rate_limit_members_read_per_min)
      set(:rate_limit_members_read_burst, 4_000)
      assert tiers(:members_read) == {60, 30}, "4000 / 60 > 60: the default pair applies"
      assert Enum.sort(tiers(:invalid_settings)) == ["NEBU_RATE_LIMIT_MEMBERS_READ_BURST", "NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN"]

      log = capture_log([level: :warning], fn -> assert :ok = tiers(:warn_invalid_settings) end)
      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "NEBU_RATE_LIMIT_MEMBERS_READ_"))
      assert length(lines) == 2
      refute log =~ "4000"
    end

    test "burst / rate > 60 falls back to the default pair {60, 30}; junk (0, negative, float, string, nil) falls back to the default pair too" do
      set(:rate_limit_members_read_per_min, 1)
      set(:rate_limit_members_read_burst, 61)
      assert tiers(:members_read) == {60, 30}
      assert Enum.sort(tiers(:invalid_settings)) == ["NEBU_RATE_LIMIT_MEMBERS_READ_BURST", "NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN"]

      for junk <- [0, -1, 1.5, "20", nil, :on] do
        for key <- @tier_keys, do: Application.delete_env(:nebu_http, key)
        set(:rate_limit_members_read_per_min, junk)
        assert tiers(:members_read) == {60, 30}, "per_min #{inspect(junk)}"

        for key <- @tier_keys, do: Application.delete_env(:nebu_http, key)
        set(:rate_limit_members_read_burst, junk)
        assert tiers(:members_read) == {60, 30}, "burst #{inspect(junk)}"
      end
    end

    test "config/runtime.exs: the two variables land under :rate_limit_members_read_per_min / _burst; junk is ignored; unset sets nothing" do
      config = runtime_config(%{"NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN" => "45", "NEBU_RATE_LIMIT_MEMBERS_READ_BURST" => "90"})
      assert config_value(config, {:nebu_http, :rate_limit_members_read_per_min}) == 45
      assert config_value(config, {:nebu_http, :rate_limit_members_read_burst}) == 90

      for junk <- ["0", "-3", "abc", "", "9223372036854775808"] do
        config = runtime_config(%{"NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN" => junk, "NEBU_RATE_LIMIT_MEMBERS_READ_BURST" => junk})
        assert config_value(config, {:nebu_http, :rate_limit_members_read_per_min}) == :unset, "junk #{inspect(junk)}"
        assert config_value(config, {:nebu_http, :rate_limit_members_read_burst}) == :unset
      end

      assert config_value(runtime_config(%{}), {:nebu_http, :rate_limit_members_read_per_min}) == :unset
    end
  end
end
