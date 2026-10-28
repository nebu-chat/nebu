defmodule Nebu.Matrix.RoomSummary do
  @moduledoc """
  Pure builder of the `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` response body (Matrix v1.15
  `RoomSummary` + `membership`; story oauth-room-summary-unrecognized, decision RU5).

  No DB, no process, no clock: `build/3` maps the room's state events (the list
  `Nebu.Matrix.EventDispatcher.Server` builds from the Room state, `%Core.SyncRoomStateEvent{}` with a JSON
  string `content`) plus a small context to the string-keyed, JSON-ready map. Visibility, existence and
  membership are decided by the caller (`Nebu.Matrix.EventDispatcher.Server.get_room_summary/2`).

  Always present: `room_id`, `num_joined_members`, `guest_can_join`, `world_readable`, `join_rule`
  (default `invite`), `room_version` (create content, `"1"` when absent), `membership`. Present only when
  non-empty: `name`, `topic`, `avatar_url`, `canonical_alias`, `room_type`. `topic` is the `m.topic`
  `text/plain` block (a block without a mimetype counts as text/plain), else the legacy `topic`, never
  another mimetype. `encryption` only for `m.megolm.v1.aes-sha2`; `allowed_room_ids` only for `restricted`
  and `knock_restricted` rooms. Never `children_state`, `aliases` or `im.nheko.summary.*`.
  """

  @megolm "m.megolm.v1.aes-sha2"

  @type context :: %{num_joined_members: non_neg_integer(), membership: String.t()}

  @spec build(String.t(), [struct()], context()) :: map()
  def build(room_id, state_events, %{num_joined_members: joined, membership: membership}) do
    index = index_state(state_events)
    join_rule = string(index, "m.room.join_rules", "join_rule", "invite")
    create = content(index, "m.room.create")

    %{
      "room_id" => room_id,
      "num_joined_members" => joined,
      "guest_can_join" => string(index, "m.room.guest_access", "guest_access") == "can_join",
      "world_readable" => string(index, "m.room.history_visibility", "history_visibility") == "world_readable",
      "join_rule" => join_rule,
      "room_version" => non_empty(create["room_version"]) || "1",
      "membership" => membership
    }
    |> put_present("name", string(index, "m.room.name", "name"))
    |> put_present("topic", topic(content(index, "m.room.topic")))
    |> put_present("avatar_url", string(index, "m.room.avatar", "url"))
    |> put_present("canonical_alias", string(index, "m.room.canonical_alias", "alias"))
    |> put_present("room_type", non_empty(create["type"]))
    |> put_encryption(index)
    |> put_allowed_room_ids(join_rule, content(index, "m.room.join_rules"))
  end

  # ── state access ────────────────────────────────────────────────────────────

  # %{type => decoded content} of the state events with state_key "" (the first one wins, as the caller's
  # list holds one current event per type/key).
  defp index_state(state_events) do
    Enum.reduce(state_events, %{}, fn ev, acc ->
      if ev.state_key == "", do: Map.put_new(acc, ev.type, decode(ev.content)), else: acc
    end)
  end

  defp content(index, type), do: Map.get(index, type, %{})

  defp string(index, type, key, default \\ "") do
    case content(index, type)[key] do
      v when is_binary(v) and v != "" -> v
      _ -> default
    end
  end

  defp decode(content) when is_binary(content) and content != "" do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  defp non_empty(v) when is_binary(v) and v != "", do: v
  defp non_empty(_), do: nil

  # Optional keys are omitted (never null, never "").
  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # ── topic (m.topic text/plain block, else the legacy `topic`) ──────────────

  defp topic(%{} = content) do
    plain_block_body(content) || non_empty(content["topic"])
  end

  defp plain_block_body(content) do
    with %{"m.text" => blocks} when is_list(blocks) <- content["m.topic"],
         %{"body" => body} <- Enum.find(blocks, &plain_block?/1) do
      non_empty(body)
    else
      _ -> nil
    end
  end

  # A block without a `mimetype` is text/plain (the `m.topic` / `m.text` default).
  defp plain_block?(%{"mimetype" => mimetype, "body" => body}) when is_binary(body), do: mimetype == "text/plain"
  defp plain_block?(%{"body" => body} = block) when is_binary(body), do: not Map.has_key?(block, "mimetype")
  defp plain_block?(_), do: false

  # ── encryption / allowed_room_ids ──────────────────────────────────────────

  defp put_encryption(map, index) do
    case content(index, "m.room.encryption")["algorithm"] do
      @megolm -> Map.put(map, "encryption", @megolm)
      _ -> map
    end
  end

  defp put_allowed_room_ids(map, rule, join_rules_content) when rule in ["restricted", "knock_restricted"] do
    allow =
      case join_rules_content["allow"] do
        list when is_list(list) -> list
        _ -> []
      end

    ids = for %{"type" => "m.room_membership", "room_id" => id} <- allow, is_binary(id), id != "", do: id
    Map.put(map, "allowed_room_ids", ids)
  end

  defp put_allowed_room_ids(map, _rule, _content), do: map
end
