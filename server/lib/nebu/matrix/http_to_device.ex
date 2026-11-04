defmodule Nebu.Matrix.HttpToDevice do
  @moduledoc """
  HTTP side of `PUT /_matrix/client/v3/sendToDevice/{eventType}/{txnId}` (story to-device-messaging, epic e2ee-client-support): request
  validation and answers. The route lives in `Nebu.Web.Router.Protected` (authentication, the event-type allowlist, the per-user rate limit, and only then the
  body is read with the 64 KiB cap, see `Nebu.Web.Plugs.JsonBody.parse_to_device/1`); the queue lives in `Nebu.Matrix.ToDeviceStore`.

  ## Allowlist (story e2ee-compliance-channel-guard, D2, ADR-011)

  Only the event types of `@allowed_event_types` are accepted (exact, case-sensitive match on the decoded type, no prefix or regex family): the Olm wrapper
  `m.room.encrypted`, `m.room_key_request`, `m.room_key.withheld`, `m.secret.request`, `m.dummy` and the eight `m.key.verification.*` types. NOT in the list
  on purpose: `m.room_key`, `m.forwarded_room_key` and `m.secret.send` (inner, Olm-wrapped payloads, never the outer type), the unstable alias
  `org.matrix.room_key.withheld` and the Element Call / MatrixRTC key transport (`io.element.call.encryption_keys`, `m.call.*`). A new client flow that
  needs another type is a reviewed one-line change of the list plus a doc line, not configuration. The type check is the first thing of a send: a refused
  type consumes no rate or byte budget, creates no row and no limiter bucket, and the answer does not depend on any recipient.

  The allowlist is a TYPE filter, not a content filter: the guard narrows which types may be used, it does not inspect or limit content below the existing
  budgets (64 KiB per request, 50 recipients, the rate and byte buckets, the queue caps). Any content still passes under `m.dummy`, `m.key.verification.*`,
  `m.room_key_request`, `m.secret.request` and `m.room_key.withheld`, and `m.room.encrypted` carries arbitrary opaque content by design: the channel is as large
  as before for the allowed types.

  Content is OPAQUE and never logged. An unknown user or device, a user the sender shares no joined room with, a remote user and a malformed user id
  are skipped silently: the answer is the same `200 {}` in every case (no existence or membership oracle).

  ## Errors

    * `400 M_NOT_JSON` malformed JSON, `400 M_BAD_JSON` `messages` missing / not an object, an entry that is not an object, a body that is not an object;
    * `400 M_INVALID_PARAM` an event type outside the allowlist (`@allowed_event_types`, checked FIRST, one fixed text, the type is not echoed), a txn id of 0 or more than 255 bytes;
    * `413 M_TOO_LARGE` a body above 64 KiB, more than 50 recipient entries (`*` counts as one);
    * `403 M_USER_DEACTIVATED` a sender whose erasure is under way;
    * `429 M_LIMIT_EXCEEDED` the sender's rate limit, its byte-cost bucket, no free send slot, a concurrent identical transaction, a statement over the 2 s timeout (of the first transaction),
      a sender whose erasure holds its fence;
    * `500 M_UNKNOWN` a failed database operation (generic text).
  """
  import Nebu.Matrix.Http, only: [send_json: 3, error: 4]
  require Logger

  alias Nebu.Matrix.ToDeviceStore, as: Store

  @max_entries 50
  @max_id_bytes 255

  @allowed_event_types MapSet.new([
    "m.room.encrypted",
    "m.room_key_request",
    "m.room_key.withheld",
    "m.secret.request",
    "m.dummy",
    "m.key.verification.request",
    "m.key.verification.ready",
    "m.key.verification.start",
    "m.key.verification.accept",
    "m.key.verification.key",
    "m.key.verification.mac",
    "m.key.verification.done",
    "m.key.verification.cancel"
  ])

  @spec send_to_device(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def send_to_device(conn, event_type, txn_id) do
    with :ok <- check_type(event_type),
         :ok <- check_json(conn),
         :ok <- check_txn(txn_id),
         {:ok, messages} <- messages(conn),
         {:ok, entries} <- entries(messages),
         :ok <- check_count(entries) do
      sender = conn.assigns[:current_user]
      device = device_id(conn)

      case Store.send(sender, device, event_type, txn_id, Enum.filter(entries, &storable?/1)) do
        :ok -> send_json(conn, 200, %{})
        {:error, busy} when busy in [:lock_timeout, :lock_busy, :statement_timeout] -> Nebu.Web.Plugs.RateLimit.respond_limited(conn, 1)
        {:error, {:bytes_rate, seconds}} -> Nebu.Web.Plugs.RateLimit.respond_limited(conn, seconds)
        {:error, :user_erased} -> error(conn, 403, "M_USER_DEACTIVATED", "This account has been deactivated")
        {:error, reason} -> failed(conn, reason)
      end
    else
      {:error, {status, errcode, message}} -> error(conn, status, errcode, message)
    end
  end

  defp device_id(conn) do
    case conn.assigns[:device_id] do
      id when is_binary(id) -> id
      _ -> ""
    end
  end

  @doc """
  The type check of the route, run BEFORE the rate limit, the body, the recipients and the budgets (D2): `nil` for an allowlisted type, otherwise the
  `400 M_INVALID_PARAM` answer (a fixed text, the type is not echoed). A refused type allocates no limiter bucket, takes no slot and reads no body.
  """
  @spec refuse_unlisted_type(Plug.Conn.t(), String.t()) :: Plug.Conn.t() | nil
  def refuse_unlisted_type(conn, event_type) do
    case check_type(event_type) do
      :ok -> nil
      {:error, {status, errcode, message}} -> error(conn, status, errcode, message)
    end
  end

  defp check_json(conn) do
    if conn.assigns[:json_parse_error] == true, do: {:error, {400, "M_NOT_JSON", "Request body is not valid JSON"}}, else: :ok
  end

  defp check_type(type) do
    if is_binary(type) and MapSet.member?(@allowed_event_types, type),
      do: :ok,
      else: {:error, {400, "M_INVALID_PARAM", "Event type is not supported on this server"}}
  end

  defp check_txn(txn) do
    if is_binary(txn) and byte_size(txn) in 1..@max_id_bytes and String.valid?(txn) and not String.contains?(txn, <<0>>),
      do: :ok,
      else: {:error, {400, "M_INVALID_PARAM", "Invalid transaction id"}}
  end

  defp messages(conn) do
    case conn.body_params do
      %{"messages" => messages} when is_map(messages) -> {:ok, messages}
      _ -> {:error, {400, "M_BAD_JSON", "Request body must be a JSON object with an object member `messages`"}}
    end
  end

  # `[%{user_id, device, content}]`: every user entry must map to an object of device entries, every device entry to an object (the content)
  defp entries(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn
      {user, devices}, {:ok, acc} when is_binary(user) and is_map(devices) ->
        case Enum.reduce_while(devices, {:ok, []}, fn
               {device, content}, {:ok, inner} when is_map(content) -> {:cont, {:ok, [%{user_id: user, device: device, content: Jason.encode!(content)} | inner]}}
               _bad, _ -> {:halt, :bad}
             end) do
          {:ok, list} -> {:cont, {:ok, list ++ acc}}
          :bad -> {:halt, {:error, {400, "M_BAD_JSON", "Every device entry must be a JSON object"}}}
        end

      _bad, _ ->
        {:halt, {:error, {400, "M_BAD_JSON", "Every user entry must be a JSON object"}}}
    end)
  end

  defp check_count(entries) do
    if length(entries) > @max_entries,
      do: {:error, {413, "M_TOO_LARGE", "Too many recipient entries (at most #{@max_entries})"}},
      else: :ok
  end

  # an entry that can name no stored row (malformed user id, a device id that is not valid text) is skipped like an unknown recipient
  defp storable?(%{user_id: user, device: device}) do
    Nebu.Matrix.UserId.valid?(user) and valid_device?(device)
  end

  defp valid_device?("*"), do: true
  defp valid_device?(d), do: byte_size(d) in 1..@max_id_bytes and String.valid?(d) and not String.contains?(d, <<0>>)

  defp failed(conn, reason) do
    Logger.error("to-device request failed: #{error_kind(reason)}")
    error(conn, 500, "M_UNKNOWN", "The message could not be queued, please try again.")
  end

  defp error_kind(%{__struct__: module}), do: inspect(module)
  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(_), do: "error"
end
