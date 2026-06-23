defmodule Nebu.Matrix.Http do
  @moduledoc """
  Shared helpers for the Matrix Client-Server API HTTP handlers
  (`Nebu.Web.MatrixRouter`, `Nebu.Matrix.HttpPublic`).

  ## Why this exists

  The full Matrix business logic lives in
  `Nebu.Matrix.EventDispatcher.Server`, which the HTTP handlers call DIRECTLY —
  there is no gRPC hop on the request path (ADR-021).

  Command functions take `(request_struct, stream)` and either return a
  `Core.*Response` struct or `raise Nebu.Matrix.Error`. This module provides:

    * `stream/1` — a minimal request-context map carrying the trusted identity in the
      `http_request_headers` map, exactly the shape
      `Nebu.Matrix.RequestMetadata.trusted_identity/1` reads. Identity here is trusted
      because `OidcPlug` already validated the Bearer token for authed routes.
    * `call_core/1` — runs a command function, catching `Nebu.Matrix.Error` and
      mapping the status atom to a `{:error, {http_status, errcode, msg}}`
      tuple.
    * `send_json/3`, `error/4` — encode the Matrix JSON envelopes.

  The JSON response *shapes* are reproduced from the Go handlers in
  `gateway/internal/matrix/*.go` (contract parity, AC1).
  """

  import Plug.Conn

  @doc """
  Builds the fake gRPC stream that carries the trusted Matrix identity.

  `user_id` is the authenticated `@user:server` (from `OidcPlug`), trusted
  because the Bearer token was already verified. `system_role` defaults to
  `"user"` — admin-only endpoints are out of scope for this story.
  """
  def stream(user_id, system_role \\ "user") do
    %{http_request_headers: %{"x-user-id" => user_id, "x-system-role" => system_role}}
  end

  @doc """
  Invokes a `Nebu.Matrix.EventDispatcher.Server` function, mapping a raised
  `Nebu.Matrix.Error` to a Matrix HTTP error tuple.

  Returns `{:ok, response_struct}` or `{:error, {http_status, errcode, message}}`.
  """
  def call_core(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    e in Nebu.Matrix.Error ->
      {:error, map_error(e)}
  end

  # status atom → {http_status, matrix_errcode, message}.
  defp map_error(%Nebu.Matrix.Error{status: status, message: message}) do
    cond do
      status == Nebu.Matrix.Status.not_found() ->
        {404, "M_NOT_FOUND", "Room not found"}

      status == Nebu.Matrix.Status.permission_denied() ->
        {403, "M_FORBIDDEN", "You are not a member of this room"}

      status == Nebu.Matrix.Status.invalid_argument() ->
        {400, "M_INVALID_PARAM", message || "Invalid parameter"}

      status == Nebu.Matrix.Status.resource_exhausted() ->
        {403, "M_ROOM_FULL", "Room is full"}

      status == Nebu.Matrix.Status.failed_precondition() ->
        {400, "M_BAD_STATE", message || "Bad state"}

      status == Nebu.Matrix.Status.unavailable() ->
        {503, "M_UNAVAILABLE", "Core is temporarily unavailable"}

      status == Nebu.Matrix.Status.unauthenticated() ->
        {401, "M_UNKNOWN_TOKEN", "Unauthenticated"}

      true ->
        {500, "M_UNKNOWN", "Internal server error"}
    end
  end

  @doc "Encodes `body` as JSON and sends it with `status` and the JSON content type."
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc "Sends a Matrix error envelope `{errcode, error}` with the given HTTP status."
  def error(conn, status, errcode, message) do
    send_json(conn, status, %{"errcode" => errcode, "error" => message})
  end

  @doc "Sends a `{http_status, errcode, message}` tuple produced by `call_core/1`."
  def send_error(conn, {status, errcode, message}) do
    error(conn, status, errcode, message)
  end

  # ─── SyncRoom (proto) → Matrix sync JSON ────────────────────────────────
  # Mirrors gateway/internal/matrix/sync.go buildJoinedRooms + syncResponse.

  @doc """
  Builds the full Matrix `/sync` JSON response from a list of `Core.SyncRoom`
  structs and the `next_batch` token.

  ## invite / leave sections — deferred (MINOR-2, cycle 1)

  The `invite` and `leave` sections are emitted as empty maps. This is a known,
  tracked gap (see the matrix-api-migration Dev Agent Record): the proto
  `SyncRoom` (proto/core.proto) carries NO membership field, and
  `GetSyncDelta`/`GetInitialSync` only return joined-room snapshots in
  `rooms`. The Go gateway builds invite/leave from SEPARATE DB queries
  (`buildInviteRooms` / `buildLeaveRooms` in sync.go) that the migrated
  no-gRPC-hop path does not yet call. Splitting them out of `delta.rooms` is
  not possible because the data simply is not present there. Wiring the extra
  invite/leave queries (or adding a membership field to `SyncRoom`) is genuine
  new work beyond this story's scope and is tracked as a follow-up. `join`
  carries the fan-out events that AC2 asserts on.
  """
  def sync_response(next_batch, rooms) when is_list(rooms) do
    %{
      "next_batch" => next_batch,
      "rooms" => %{
        "join" => build_joined_rooms(rooms),
        # invite/leave deferred — see moduledoc above (MINOR-2): no membership
        # data in proto SyncRoom; tracked as a follow-up.
        "invite" => %{},
        "leave" => %{}
      },
      "presence" => %{"events" => []},
      "account_data" => %{"events" => []},
      "device_one_time_keys_count" => %{},
      "device_unused_fallback_key_types" => [],
      "device_lists" => %{"changed" => [], "left" => []}
    }
  end

  defp build_joined_rooms(rooms) do
    Map.new(rooms, fn room ->
      state_events =
        Enum.map(room.state_events, fn se ->
          %{
            "type" => se.type,
            "state_key" => se.state_key,
            "content" => decode_content(se.content),
            "sender" => se.sender
          }
        end)

      now_ms = System.system_time(:millisecond)

      timeline_events =
        Enum.map(room.timeline_events, fn te ->
          %{
            "event_id" => te.event_id,
            "type" => te.event_type,
            "sender" => te.sender_id,
            "room_id" => te.room_id,
            "content" => decode_content(te.content),
            "origin_server_ts" => te.origin_ts,
            "unsigned" => %{"age" => max(1, now_ms - te.origin_ts)}
          }
          |> put_state_key(te.state_key)
        end)

      joined = %{
        "state" => %{"events" => state_events},
        "timeline" => %{
          "events" => timeline_events,
          "limited" => room.limited,
          "prev_batch" => room.prev_batch
        },
        "account_data" => %{"events" => []}
      }

      {room.room_id, joined}
    end)
  end

  # Event/state content is a JSON-encoded `bytes` field in the proto. Decode it
  # back to a map for the HTTP JSON body (Go re-emits it as json.RawMessage).
  defp decode_content(content) when is_binary(content) and content != "" do
    case Jason.decode(content) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp decode_content(_), do: %{}

  # ─── /messages (proto Event list) → Matrix chunk JSON ───────────────────
  # Mirrors gateway/internal/matrix/messages.go getMessagesResponse.

  @doc "Maps a `Core.Event` to the Matrix `/messages` chunk event shape."
  def message_event(%Core.Event{} = e) do
    %{
      "event_id" => e.event_id,
      "room_id" => e.room_id,
      "sender" => e.sender_id,
      "type" => e.event_type,
      "content" => decode_content(e.content),
      "origin_server_ts" => e.origin_ts
    }
    |> put_state_key(e.state_key)
  end

  # A state event (m.room.member, m.room.create, m.room.name, …) MUST carry its
  # `state_key` — Matrix clients key state off (type, state_key). For m.room.member the
  # state_key is the target user, so without it a client cannot tell that a user joined
  # (Element stays stuck on "Joining…"). Non-state (message) events have no state_key, so
  # only add the field when it is present.
  defp put_state_key(map, sk) when is_binary(sk) and sk != "", do: Map.put(map, "state_key", sk)
  defp put_state_key(map, _), do: map
end
