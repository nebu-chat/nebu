defmodule Nebu.Matrix.Room.JoinRules do
  @moduledoc """
  Pure join decision of the room join path (epic spaces-elixir story s4-restricted-join for the MSC3083
  `restricted` rule; epic oauth-broker story `create-room-presets-power-levels-topic`, follow-up `ec`, decision D1,
  for the enforcement of EVERY join rule and of bans). THIS MODULE IS THE SECURITY BOUNDARY of
  `POST /_matrix/client/v3/join/{roomId}`.

  `check_join_allowed/3` is Repo-less and side-effect-free: the caller injects `banned?` (the user's latest
  `m.room.member` is `ban`), `has_invite?` (does the joining user have a pending invite?) and a `space_member?`
  resolver (`fn room_id, user_id -> boolean end`). This keeps the decision unit-testable without a database or a
  GenServer, and lets `Nebu.Matrix.EventDispatcher.Server.join_room/2` own the impure resolution (room state
  lookup, membership lookup, pending-invite lookup, member-set lookup) and the member short-circuit (a member's
  re-join is idempotent and never reaches this module).

  ## Decision table (in this order)

  | Input                                              | Result                                                      |
  |----------------------------------------------------|-------------------------------------------------------------|
  | `banned?: true` (whatever the rule, invite, space) | `{:error, :forbidden}`                                      |
  | `public`                                           | `:ok`                                                       |
  | `invite`, `knock`                                  | `:ok` only with `has_invite?`, else forbidden               |
  | NO `m.room.join_rules` event at all                | treated as `invite` (Nebu / Synapse POLICY, not spec text)  |
  | `restricted`, `knock_restricted`                   | `has_invite?` OR member of a VALID `allow[]` room -> `:ok`  |
  | `private` (reserved), any unknown value            | `{:error, :forbidden}` ALWAYS, even with an invite          |
  | MALFORMED event (no / empty / non-string           | `{:error, :forbidden}` ALWAYS, even with an invite          |
  | `join_rule`, undecodable content)                  |                                                             |

  Strict room v10 auth: `invite` / `knock` accept an existing invitation, `restricted` / `knock_restricted` an
  invitation or an authorising allow condition, `public` allows, OTHERWISE reject. The ABSENT-rule `invite` is the
  Nebu / Synapse policy (strict v10 has no default and would reject even invited users); it keeps legacy rooms
  (created before the preset story, without a join rules event) joinable by invitation. An event that EXISTS but is
  malformed is NOT absent: it denies always (a member with PL >= 50 can repair the room by setting a valid rule).
  Only an `m.room.join_rules` event with state_key `""` counts as the room's rule.

  The former behaviour (everything but `restricted` returned `:ok`: every private room, DM and `invite` room was
  open-join for any local user who knew the room id, bans were not enforced) was the security finding `ec`.

  ## Security (Kassandra S2/S3 forward-warnings)

  `m.room.join_rules.allow[]` is client-writable by any PL>=state_default member via the generic state PUT (story
  S2), so it is an attacker-influenceable membership-bypass primitive. Therefore:

    * **Default-deny** on `restricted` / `knock_restricted`: only an explicit, valid allow[]-space membership OR a
      pending invite grants the join.
    * **Validate every `allow[]` entry** (`type == "m.room_membership"` and a non-empty binary `room_id`).
      Malformed entries are filtered out; a malformed/empty/missing `allow` therefore behaves invite-only.
    * **No info leak (AC6):** the resolver returns a plain boolean, so a non-existent allow-room and an
      existing-but-not-member allow-room deny *identically* - the decision never reveals which rooms exist.
  """

  @doc """
  Decide whether `user_id` may join a room with the given resolved state.

  `room_state` is the room's resolved state-event list (the
  `Nebu.Matrix.EventDispatcher.Server.build_state_events/2` shape): a list of
  maps each carrying `:type`, `:state_key`, and a JSON-string `:content`. The
  `m.room.join_rules` content (`join_rule` + `allow`) is read from it.

  Options:

    * `:banned?` (boolean, default `false`) - the user's latest `m.room.member` is `ban`. Decided before the rule.
    * `:has_invite?` (boolean, default `false`) - the user has a pending
      `m.room.member` invite to this room. Grants `invite`, `knock`, `restricted`, `knock_restricted`
      (and an absent rule), never `private` / unknown / malformed.
    * `:space_member?` (`fn room_id, user_id -> boolean end`, required for the
      restricted path) — is the user a member of the given allow-room?

  Returns `:ok` or `{:error, :forbidden}`.
  """
  @spec check_join_allowed(
          [map()],
          String.t(),
          keyword()
        ) :: :ok | {:error, :forbidden}
  def check_join_allowed(room_state, user_id, opts) do
    if Keyword.get(opts, :banned?, false) do
      {:error, :forbidden}
    else
      decide(join_rule(room_state), room_state, user_id, opts)
    end
  end

  defp decide("public", _room_state, _user_id, _opts), do: :ok

  defp decide(rule, _room_state, _user_id, opts) when rule in ["invite", "knock"] do
    if Keyword.get(opts, :has_invite?, false), do: :ok, else: {:error, :forbidden}
  end

  defp decide(rule, room_state, user_id, opts) when rule in ["restricted", "knock_restricted"],
    do: check_restricted(room_state, user_id, opts)

  # `private`, unknown values and malformed events: denied always, even with an invite (strict v10).
  defp decide(_other, _room_state, _user_id, _opts), do: {:error, :forbidden}

  defp check_restricted(room_state, user_id, opts) do
    has_invite? = Keyword.get(opts, :has_invite?, false)
    space_member? = Keyword.get(opts, :space_member?, fn _room, _user -> false end)

    cond do
      # Pending invite always overrides restricted (AC3).
      has_invite? ->
        :ok

      # Member of ANY valid allow[]-room (AC1). Validation per AC4 happens in
      # valid_allow_rooms/1; the resolver boolean keeps it no-leak (AC6).
      Enum.any?(valid_allow_rooms(room_state), fn room_id ->
        space_member?.(room_id, user_id)
      end) ->
        :ok

      # Default-deny.
      true ->
        {:error, :forbidden}
    end
  end

  # The effective rule: the join_rule of the m.room.join_rules event (state_key ""), "invite" when there is NO such
  # event (Nebu / Synapse policy), :malformed when the event exists but carries no usable join_rule.
  defp join_rule(room_state) do
    case join_rules_event(room_state) do
      nil ->
        "invite"

      ev ->
        case decode_content(Map.get(ev, :content)) do
          %{"join_rule" => jr} when is_binary(jr) and jr != "" -> jr
          _ -> :malformed
        end
    end
  end

  # Extract and validate the allow[] room_ids: keep only entries that are maps
  # with type == "m.room_membership" and a non-empty binary room_id (AC4).
  # Everything else (wrong type, missing/empty/non-binary room_id, non-map
  # entries, non-list allow) is filtered out → []. No crash.
  defp valid_allow_rooms(room_state) do
    case join_rules_content(room_state) do
      %{"allow" => allow} when is_list(allow) ->
        allow
        |> Enum.filter(&valid_allow_entry?/1)
        |> Enum.map(fn %{"room_id" => room_id} -> room_id end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp valid_allow_entry?(%{"type" => "m.room_membership", "room_id" => room_id})
       when is_binary(room_id) and room_id != "",
       do: true

  defp valid_allow_entry?(_), do: false

  # The m.room.join_rules event with state_key "" (nil when there is none).
  defp join_rules_event(room_state) do
    Enum.find(room_state, fn ev ->
      Map.get(ev, :type) == "m.room.join_rules" and Map.get(ev, :state_key, "") == ""
    end)
  end

  # Decode the m.room.join_rules content to a map. content is a JSON string as persisted; malformed -> %{}.
  defp join_rules_content(room_state) do
    case join_rules_event(room_state) do
      nil -> %{}
      ev -> decode_content(Map.get(ev, :content))
    end
  end

  # A JSONB string whose text is itself JSON (legacy double encoding: Postgrex was once handed a pre-encoded string) decodes
  # to a binary: decode that once more (review cycle 1, F-7). Anything that is still no object is malformed.
  defp decode_content(content) when is_binary(content) and content != "" do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) ->
        map

      {:ok, text} when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp decode_content(content) when is_map(content), do: content
  defp decode_content(_), do: %{}
end
