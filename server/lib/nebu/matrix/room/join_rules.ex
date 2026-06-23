defmodule Nebu.Matrix.Room.JoinRules do
  @moduledoc """
  Pure decision module for the MSC3083 `restricted` join rule
  (epic spaces-elixir, story s4-restricted-join).

  `check_join_allowed/3` is Repo-less and side-effect-free: the caller injects
  `has_invite?` (does the joining user have a pending invite?) and a
  `space_member?` resolver (`fn room_id, user_id -> boolean end`). This keeps the
  security-critical decision unit-testable without a database or a GenServer, and
  lets `Nebu.Matrix.EventDispatcher.Server.join_room/2` own the impure resolution
  (room state lookup, member-set lookup, pending-invite lookup).

  ## Decision table

  | join_rule              | grants                                                        |
  |------------------------|---------------------------------------------------------------|
  | "restricted"           | `has_invite?` OR member of any VALID `allow[]` room → `:ok`   |
  |                        | otherwise → `{:error, :forbidden}`                            |
  | anything else / absent | `:ok` (public / invite / default / unknown — UNCHANGED)       |

  This story is deliberately SCOPED to the `restricted` rule. `public`,
  `invite`, default (absent join_rules), and any unrecognised value all return
  `:ok` — preserving the pre-story open-join behaviour (no join_rule check).

  ## Security (Kassandra S2/S3 forward-warnings)

  `m.room.join_rules.allow[]` is client-writable by any PL≥state_default member
  via the generic state PUT (story S2), so it is an attacker-influenceable
  membership-bypass primitive. Therefore:

    * **Default-deny** on `restricted`: only an explicit, valid allow[]-space
      membership OR a pending invite grants the join.
    * **Validate every `allow[]` entry** (`type == "m.room_membership"` and a
      non-empty binary `room_id`). Malformed entries are filtered out; a
      malformed/empty/missing `allow` therefore behaves invite-only.
    * **No info leak (AC6):** the resolver returns a plain boolean, so a
      non-existent allow-room and an existing-but-not-member allow-room deny
      *identically* — the decision never reveals which rooms exist.
  """

  @doc """
  Decide whether `user_id` may join a room with the given resolved state.

  `room_state` is the room's resolved state-event list (the
  `Nebu.Matrix.EventDispatcher.Server.build_state_events/2` shape): a list of
  maps each carrying `:type`, `:state_key`, and a JSON-string `:content`. The
  `m.room.join_rules` content (`join_rule` + `allow`) is read from it.

  Options:

    * `:has_invite?` (boolean, default `false`) — the user has a pending
      `m.room.member` invite to this room. Overrides restricted.
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
    case join_rule(room_state) do
      "restricted" ->
        check_restricted(room_state, user_id, opts)

      _other ->
        # public / invite / default / knock / unknown — unchanged (AC5).
        :ok
    end
  end

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

  # The `join_rule` from the latest m.room.join_rules content, defaulting to
  # "invite" (Matrix default) when absent — mirrors the server's join_rule/1.
  defp join_rule(room_state) do
    case join_rules_content(room_state) do
      %{"join_rule" => jr} when is_binary(jr) and jr != "" -> jr
      _ -> "invite"
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

  # Decode the latest m.room.join_rules (state_key "") content to a map.
  # content is a JSON string as persisted; malformed/absent → %{}.
  defp join_rules_content(room_state) do
    room_state
    |> Enum.find(fn ev ->
      Map.get(ev, :type) == "m.room.join_rules" and Map.get(ev, :state_key, "") == ""
    end)
    |> case do
      nil -> %{}
      ev -> decode_content(Map.get(ev, :content))
    end
  end

  defp decode_content(content) when is_binary(content) and content != "" do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_content(content) when is_map(content), do: content
  defp decode_content(_), do: %{}
end
