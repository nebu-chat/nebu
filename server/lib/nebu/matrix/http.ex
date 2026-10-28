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

  # story power-levels-enforcement (D10): the ONE 500 text that map_error/1 passes through
  @power_levels_not_changed "The power levels could not be changed"

  @doc "The fixed text of a failed power-level write (`500 M_UNKNOWN`, the only internal error whose text reaches the client)."
  @spec power_levels_not_changed_text() :: String.t()
  def power_levels_not_changed_text, do: @power_levels_not_changed

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
  defp map_error(%Nebu.Matrix.Error{status: status, message: message, errcode: errcode}) do
    cond do
      # a specific errcode (story create-room-input-validation, D6) is only honoured for invalid_argument
      is_binary(errcode) and status == Nebu.Matrix.Status.invalid_argument() ->
        {400, errcode, message || "Invalid parameter"}

      # story create-room-presets-power-levels-topic (D1): the join refusals carry their own fixed errcode / text
      # ("You are banned from this room" / "You are not invited to this room"); opt-in only, every
      # permission_denied without an errcode keeps the generic text below.
      is_binary(errcode) and status == Nebu.Matrix.Status.permission_denied() ->
        {403, errcode, message || "You are not a member of this room"}

      # story create-room-invites-direct (D13): an unknown / deactivated invitee carries its own errcode / fixed text;
      # opt-in only, every not_found without an errcode keeps "Room not found".
      is_binary(errcode) and status == Nebu.Matrix.Status.not_found() ->
        {404, errcode, message || "Room not found"}

      # story power-levels-enforcement (D10): a power-level write that failed is a 500 M_UNKNOWN with its own FIXED text; opt-in only
      # and only for exactly that text (review cycle 0 I2 / Kassandra I-4): every other internal error keeps "Internal server error"
      # (its message may carry an internal detail and is never sent)
      errcode == "M_UNKNOWN" and message == @power_levels_not_changed and status == Nebu.Matrix.Status.internal() ->
        {500, "M_UNKNOWN", @power_levels_not_changed}

      # story event-size-limit (D2 (e)): 413 M_TOO_LARGE with a FIXED message (never a client value); an errcode on the error is ignored.
      status == Nebu.Matrix.Status.too_large() ->
        {413, "M_TOO_LARGE", message || Nebu.Matrix.EventSize.message(:event_too_large)}

      status == Nebu.Matrix.Status.not_found() ->
        {404, "M_NOT_FOUND", "Room not found"}

      status == Nebu.Matrix.Status.permission_denied() ->
        {403, "M_FORBIDDEN", "You are not a member of this room"}

      status == Nebu.Matrix.Status.invalid_argument() ->
        {400, "M_INVALID_PARAM", message || "Invalid parameter"}

      # story history-visibility-enforcement (security cycle 1): a per-room cap of the room process (the history-visibility
      # events) is 429 M_LIMIT_EXCEEDED with its own fixed text; opt-in only
      errcode == "M_LIMIT_EXCEEDED" and status == Nebu.Matrix.Status.resource_exhausted() ->
        {429, "M_LIMIT_EXCEEDED", message || "Too many requests"}

      status == Nebu.Matrix.Status.resource_exhausted() ->
        {403, "M_ROOM_FULL", "Room is full"}

      status == Nebu.Matrix.Status.failed_precondition() ->
        {400, "M_BAD_STATE", message || "Bad state"}

      # story rate-limits-join-invite-create-room (delta gate L-2): the busy invitation locks carry their own errcode / fixed text
      # (`M_LIMIT_EXCEEDED`: time-based, a client may retry); opt-in only, every other unavailable keeps the generic answer.
      is_binary(errcode) and status == Nebu.Matrix.Status.unavailable() ->
        {503, errcode, message || "Core is temporarily unavailable"}

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

  ## The three room sections (story sync-membership-partition)

  `rooms.join` renders `rooms` (the joined rooms with something to deliver, plus
  the account-data-only entries the route adds); `rooms.invite` renders
  `invite_rooms` (`Core.SyncInviteRoom`: only the stripped `invite_state`
  events); `rooms.leave` renders `leave_rooms` (`Core.SyncRoom`: the leave
  window, `state` and `account_data` empty, a `prev_batch` ONLY for a limited
  timeline). A room id appears in at most one section: the core classifies, this
  module only renders. `knock` is not produced (Nebu has no knock API).
  """
  def sync_response(next_batch, rooms, room_account_data \\ %{}, invite_rooms \\ [], leave_rooms \\ []) when is_list(rooms) do
    %{
      "next_batch" => next_batch,
      "rooms" => %{
        "join" => build_joined_rooms(rooms, room_account_data),
        "invite" => build_invite_rooms(invite_rooms),
        "leave" => build_leave_rooms(leave_rooms)
      },
      "presence" => %{"events" => []},
      "account_data" => %{"events" => []},
      "device_one_time_keys_count" => %{},
      "device_unused_fallback_key_types" => [],
      "device_lists" => %{"changed" => [], "left" => []}
    }
  end

  # rooms.invite.<id>: ONLY `invite_state.events`, each a stripped state event with exactly the four spec properties
  # (`type`, `state_key`, `sender`, `content`): no event_id, origin_server_ts, unsigned or signatures (D4).
  defp build_invite_rooms(invite_rooms) do
    Map.new(invite_rooms, fn room ->
      events =
        Enum.map(room.invite_state, fn ev ->
          %{"type" => ev.type, "state_key" => ev.state_key, "sender" => ev.sender, "content" => decode_content(ev.content)}
        end)

      {room.room_id, %{"invite_state" => %{"events" => events}}}
    end)
  end

  # rooms.leave.<id>: `state` and `account_data` are empty by design (D6: no current state after the leave, room account
  # data is joined-only); the timeline has the shape of a join timeline; a non-limited window has NO `prev_batch` key.
  defp build_leave_rooms(leave_rooms) do
    now_ms = System.system_time(:millisecond)

    Map.new(leave_rooms, fn room ->
      timeline = %{"events" => Enum.map(room.timeline_events, &timeline_event_json(&1, now_ms)), "limited" => room.limited}

      timeline =
        if room.limited and room.prev_batch != "", do: Map.put(timeline, "prev_batch", room.prev_batch), else: timeline

      {room.room_id, %{"state" => %{"events" => []}, "timeline" => timeline, "account_data" => %{"events" => []}}}
    end)
  end

  # One timeline event (shared by rooms.join and rooms.leave).
  defp timeline_event_json(te, now_ms) do
    # Story member-event-prev-content (D1, D10): replaces_state / prev_content / prev_sender are set upstream (the batched
    # predecessor lookup in EventDispatcher.Server) only for a genuine state event with a predecessor; the shared helper
    # `put_predecessor_keys/2` renders the three together or none.
    unsigned = %{"age" => max(1, now_ms - te.origin_ts)} |> put_predecessor_keys(te) |> put_redacted_because(te)

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
    |> put_redacts(te)
  end

  defp build_joined_rooms(rooms, room_account_data) do
    Map.new(rooms, fn room ->
      now_ms = System.system_time(:millisecond)

      # rooms.join.*.state.events are ClientEventWithoutRoomID (no room_id): the ONE state-event renderer (story
      # membership-state-model, D10) without a room id.
      state_events = Enum.map(room.state_events, &state_event_json(&1, now_ms, nil))

      timeline_events = Enum.map(room.timeline_events, &timeline_event_json(&1, now_ms))

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

  @doc """
  The ONE renderer of a `Core.SyncRoomStateEvent` (story membership-state-model, D10): `/sync` state (`room_id` `nil`: a
  ClientEventWithoutRoomID), `/members` and the `/initialSync` state (a `room_id`: a ClientEvent). `unsigned` = `age` plus the
  predecessor keys (together or not at all). An entry WITHOUT a real event identity (`event_id` `""`: the legacy fallback D8 (a))
  carries no `unsigned`: in `/sync` it keeps `""` / 0, with a `room_id` it gets the deterministic `$synth_` id and `now` (the ONLY
  place that synthesizes an id).
  """
  @spec state_event_json(%Core.SyncRoomStateEvent{}, integer(), String.t() | nil) :: map()
  def state_event_json(%Core.SyncRoomStateEvent{} = se, now_ms, room_id) do
    legacy? = se.event_id == ""

    {event_id, ts} =
      if legacy? and room_id != nil,
        do: {"$synth_" <> Base.url_encode64(se.type <> "|" <> se.state_key, padding: false), now_ms},
        else: {se.event_id, se.origin_server_ts}

    base =
      %{
        "event_id" => event_id,
        "type" => se.type,
        "state_key" => se.state_key,
        "content" => decode_content(se.content),
        "sender" => se.sender,
        "origin_server_ts" => ts
      }
      |> then(fn ev -> if room_id, do: Map.put(ev, "room_id", room_id), else: ev end)

    if legacy? do
      Logger.debug("state_event_json: a #{se.type} state slot has no real event identity, unsigned omitted")
      base
    else
      Map.put(base, "unsigned", put_predecessor_keys(%{"age" => max(1, now_ms - se.origin_server_ts)}, se))
    end
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

  Pure, side-effect-free, no DB access — `e.replaces_state` / `e.prev_content` / `e.prev_sender` (bugfix
  unsigned-replaces-state, story member-event-prev-content) are already populated upstream by
  `Nebu.Matrix.EventDispatcher.Server.event_maps_to_core_events/1`'s single batched query per
  response; by the time an event reaches this function, "" simply means "absent" (never a
  sentinel null). `unsigned` is added ONLY for a state event with a predecessor and then carries
  exactly the three keys `replaces_state`, `prev_content` (the decoded object) and `prev_sender`
  together (no `age` — a separate, out-of-scope gap for this endpoint, follow-up fl); see
  `put_predecessor_keys/2`.
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
      |> put_redacts(e)

    case %{} |> put_predecessor_keys(e) |> put_redacted_because(e) do
      unsigned when map_size(unsigned) > 0 -> Map.put(base, "unsigned", unsigned)
      _ -> base
    end
  end

  # story state-writer-redaction (D5, D6): the top-level `redacts` of a redaction event and `unsigned.redacted_because` of a redacted
  # event (the full served redaction event, a JSON object); both absent (never null) when empty
  defp put_redacts(map, %{redacts: target}) when is_binary(target) and target != "", do: Map.put(map, "redacts", target)
  defp put_redacts(map, _event), do: map

  defp put_redacted_because(unsigned, %{redacted_because: json}) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, because} when is_map(because) -> Map.put(unsigned, "redacted_because", because)
      _ -> unsigned
    end
  end

  defp put_redacted_because(unsigned, _event), do: unsigned

  # Story member-event-prev-content (D10): the ONE rule for the three predecessor keys of a state event, shared by the
  # /sync timeline (join + leave), the /sync join state block and message_event/1. The keys are added TOGETHER or not at
  # all: only when the event is a state event (a Core.SyncRoomStateEvent has no flag and is always one; a Core.Event needs
  # `is_state_event: true`), `replaces_state` and `prev_sender` are non-empty binaries and `prev_content` is a non-empty
  # binary that decodes to a JSON object. Anything else (an inconsistent struct, a `nil` field, a non-object body) yields
  # NONE of the three keys: never a `null`, never a partial triple, never `"prev_sender" => ""`.
  defp put_predecessor_keys(unsigned, ev) do
    with true <- Map.get(ev, :is_state_event, true) == true,
         replaces when is_binary(replaces) and replaces != "" <- Map.get(ev, :replaces_state),
         prev_content when is_binary(prev_content) and prev_content != "" <- Map.get(ev, :prev_content),
         prev_sender when is_binary(prev_sender) and prev_sender != "" <- Map.get(ev, :prev_sender),
         {:ok, content} when is_map(content) <- Jason.decode(prev_content) do
      Map.merge(unsigned, %{"replaces_state" => replaces, "prev_content" => content, "prev_sender" => prev_sender})
    else
      _ -> unsigned
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
