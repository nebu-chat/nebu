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
  require Logger

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
  def sync_response(next_batch, rooms, room_account_data \\ %{}) when is_list(rooms) do
    %{
      "next_batch" => next_batch,
      "rooms" => %{
        "join" => build_joined_rooms(rooms, room_account_data),
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

  defp build_joined_rooms(rooms, room_account_data) do
    Map.new(rooms, fn room ->
      now_ms = System.system_time(:millisecond)

      # Bugfix sync-state-events-missing-fields: rooms.join.*.state.events entries
      # are ClientEventWithoutRoomID, exactly like timeline.events — event_id/
      # origin_server_ts are required, non-nullable fields regardless of whether an
      # event is surfaced in state or timeline (Oracle-confirmed spec rule). unsigned
      # is optional but added for parity (AC3), mirroring the timeline block below.
      # se.event_id/se.origin_server_ts are the REAL persisted values threaded
      # through by build_state_events/2 — never synthesized/fake.
      #
      # Code-review cycle 1 (MINOR-1): when identity is unavailable (event_id ==
      # "" — a pre-existing legacy room not yet covered by the
      # 000035_backfill_power_levels_events migration, or a failed event write,
      # see room/server.ex's fail-open moduledoc section), omit `unsigned`
      # entirely instead of shipping a ~56-year fake age computed from
      # origin_server_ts == 0 (Oracle-confirmed: unsigned is optional per
      # ClientEventWithoutRoomID) — and log so this condition is observable
      # rather than silently shipped to clients.
      #
      # Code-review cycle 2 (MINOR, Logger rate-limiting): this branch sits on
      # the `/sync` hot path — a room lacking identity would otherwise log
      # once per sync per connected client, forever, if this were
      # `Logger.warning`. Downgraded to `Logger.debug`: per this project's
      # logger level convention (server/config/prod.exs sets `level: :info`),
      # debug-level logs are compiled in but not emitted in production, so this
      # is effectively unbounded-safe there while staying fully visible in
      # dev (`level: :debug`) for local debugging. No separate dedup/counter
      # mechanism exists elsewhere in the codebase for a single log call, so
      # one isn't introduced here either (migration 000035 also makes this
      # branch far less reachable in practice going forward).
      state_events =
        Enum.map(room.state_events, fn se ->
          base = %{
            "event_id" => se.event_id,
            "type" => se.type,
            "state_key" => se.state_key,
            "content" => decode_content(se.content),
            "sender" => se.sender,
            "origin_server_ts" => se.origin_server_ts
          }

          if se.event_id == "" do
            Logger.debug(
              "build_joined_rooms: state event #{se.type}/#{inspect(se.state_key)} in room " <>
                "#{room.room_id} has no real event identity (event_id/origin_server_ts " <>
                "unavailable) — omitting unsigned rather than shipping a fake age"
            )

            base
          else
            unsigned = %{"age" => max(1, now_ms - se.origin_server_ts)}
            # Bugfix unsigned-replaces-state (Matrix CS API v1.19, AC1/AC3/AC4):
            # se.replaces_state is "" (absent, never a sentinel null) when no
            # predecessor exists at this (room_id, type, state_key) slot —
            # NOT gated by history_visibility anywhere in this path (AC4).
            #
            # Code-review cycle 1 (MINOR): `is_binary/1` guards against a nil
            # replaces_state value slipping past `!= ""` (nil != "" is also
            # true) and getting Map.put'd in as a literal JSON null — the
            # exact anti-pattern AC3 forbids. se.replaces_state is always a
            # binary in practice (proto3 string zero value), but this makes
            # the check correct even if that assumption is ever violated.
            unsigned =
              if is_binary(se.replaces_state) and se.replaces_state != "" do
                Map.put(unsigned, "replaces_state", se.replaces_state)
              else
                unsigned
              end

            Map.put(base, "unsigned", unsigned)
          end
        end)

      timeline_events =
        Enum.map(room.timeline_events, fn te ->
          unsigned = %{"age" => max(1, now_ms - te.origin_ts)}
          # Bugfix unsigned-replaces-state (AC2): only ever non-"" for an entry
          # that is itself a genuine state event (set upstream in
          # EventDispatcher.Server.event_map_to_core_event/1, which alone has
          # the DB signal needed to tell a state event with a real empty-string
          # state_key apart from a plain message — te.state_key itself is
          # ambiguous for that; te.is_state_event is the authoritative signal,
          # see that function's own comment).
          #
          # Code-review cycle 1 (MINOR): is_binary/1 guard — see the matching
          # comment on the state_events block above for why.
          unsigned =
            if is_binary(te.replaces_state) and te.replaces_state != "" do
              Map.put(unsigned, "replaces_state", te.replaces_state)
            else
              unsigned
            end

          %{
            "event_id" => te.event_id,
            "type" => te.event_type,
            "sender" => te.sender_id,
            "room_id" => te.room_id,
            "content" => decode_content(te.content),
            "origin_server_ts" => te.origin_ts,
            "unsigned" => unsigned
          }
          |> put_state_key(te)
        end)

      joined = %{
        "state" => %{"events" => state_events},
        "timeline" => %{
          "events" => timeline_events,
          "limited" => room.limited,
          "prev_batch" => room.prev_batch
        },
        "account_data" => %{"events" => Map.get(room_account_data, room.room_id, [])}
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

  @doc """
  Maps a `Core.Event` to the Matrix `/messages` chunk event shape.

  Pure, side-effect-free, no DB access — `e.replaces_state` (bugfix
  unsigned-replaces-state, AC2) is already populated upstream by
  `Nebu.Matrix.EventDispatcher.Server.event_maps_to_core_events/1`'s single
  batched query per response (AC5); by the time an event reaches this
  function, "" simply means "absent" (AC3 — never a sentinel null), exactly
  like every other optional field here. `e.replaces_state` is ONLY ever
  non-"" for an event that is itself a genuine state event (the upstream
  batch only ever populates it for slots it looked up, which are themselves
  filtered to real state events) — so checking it alone, with no separate
  state_key check, correctly adds `unsigned` ONLY for state entries and ONLY
  the `replaces_state` key (no `age` — a separate, out-of-scope gap for this
  endpoint, AC2).
  """
  def message_event(%Core.Event{} = e) do
    base =
      %{
        "event_id" => e.event_id,
        "room_id" => e.room_id,
        "sender" => e.sender_id,
        "type" => e.event_type,
        "content" => decode_content(e.content),
        "origin_server_ts" => e.origin_ts
      }
      |> put_state_key(e)

    # Code-review cycle 1 (MINOR): is_binary/1 guard — see the matching
    # comment in build_joined_rooms/1 above for why.
    if is_binary(e.replaces_state) and e.replaces_state != "" do
      Map.put(base, "unsigned", %{"replaces_state" => e.replaces_state})
    else
      base
    end
  end

  # A state event (m.room.member, m.room.create, m.room.name, …) MUST carry its
  # `state_key` — Matrix clients key state off (type, state_key). For m.room.member the
  # state_key is the target user, so without it a client cannot tell that a user joined
  # (Element stays stuck on "Joining…"). Non-state (message) events have no state_key, so
  # only add the field when it is present.
  #
  # Code-review cycle 1 (MAJOR-2 — spec-correct fix): `event.state_key` alone
  # is ambiguous once collapsed to "" — BOTH "not a state event at all" (a
  # plain m.room.message) AND "a genuine state event whose real state_key IS
  # the empty string" (m.room.name/topic/power_levels/create) serialise to
  # the exact same Elixir "" value on the Core.Event struct. Per the Matrix
  # spec, `state_key` MUST be present on every genuine state event regardless
  # of its value — omitting it for the empty-string case (the OLD behavior)
  # made those event types indistinguishable from plain messages, and
  # self-contradicted a sibling `unsigned.replaces_state` that WAS present.
  # `event.is_state_event` (set by
  # EventDispatcher.Server.event_map_to_core_event/1 from the raw DB column's
  # nil-ness, NOT from the state_key value) is the authoritative signal this
  # function needs — never re-derive "is this a state event" from state_key
  # itself.
  defp put_state_key(map, %{is_state_event: true, state_key: sk}), do: Map.put(map, "state_key", sk)
  defp put_state_key(map, %{is_state_event: false}), do: map

  # Code-review cycle 2 (MINOR): total-function catch-all, restored. The
  # cycle-1 rewrite (above) narrowed this from the original `put_state_key(map,
  # sk) when is_binary(sk)...` + `put_state_key(map, _), do: map` shape (which
  # was total over any input) to two clauses that only match a map/struct
  # carrying an `is_state_event` key. Any other input — a malformed/partial
  # event map missing `is_state_event` entirely, or a value of some other
  # shape — now falls through safely instead of raising FunctionClauseError
  # (HTTP 500). The two expected cases above are matched first and still apply
  # their correct, is_state_event-driven logic; this clause only catches what
  # they don't.
  defp put_state_key(map, _), do: map
end
