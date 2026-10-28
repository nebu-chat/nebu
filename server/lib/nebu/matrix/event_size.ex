defmodule Nebu.Matrix.EventSize do
  @moduledoc """
  Write-time size accounting of Matrix events (story `event-size-limit`, follow-up `ep`). Pure: no DB, no state, no process
  (ADR-018: a helper next to `Nebu.Matrix.CanonicalJson`, not a domain model).

  Matrix v1.18 (client-server API, "Size limits"): a complete event MUST NOT be larger than 65 536 bytes of canonical JSON
  including its signatures, and `type` / `state_key` MUST NOT exceed 255 bytes each. Every write site refuses a larger event BEFORE
  anything is persisted (`Nebu.Matrix.Status.too_large/0`, HTTP 413 `M_TOO_LARGE`).

  ## What is measured (D1)

  The size of an event is `byte_size(Nebu.Matrix.CanonicalJson.encode!(stored_event))`, where `stored_event` is the map Nebu
  persists and serves before any read-time `unsigned`: the six signed keys `content`, `origin_server_ts`, `room_id`, `sender`,
  `state_key` (the string, or JSON `null` for a message event: that is what Nebu signs), `type`, plus `event_id` and `signatures`
  (`{"nebu": <base64 Ed25519 signature>}`). The spec measures "the federation event format". Nebu does not federate: it has no
  `auth_events` / `prev_events` / `depth` / `hashes`, so NO reserve is added for those keys (a federating PDU would be roughly 1-2 KB
  larger; a reserve is due if federation or an export format is ever added). This is a Nebu interpretation of the spec text.
  `unsigned` is excluded (not covered by the signatures, computed at read time).

  `event_id` (`"$"` + the 43 characters of an unpadded url-safe base64 SHA-256) and the signature (64 bytes, 88 base64 characters)
  have a constant length, so what they add is a constant, `signed_overhead/0`.

  ## Why a `Jason.encode!` is enough (D3)

  `CanonicalJson.encode!/1` is `Jason.encode!/1` over key-sorted objects: only the key ORDER differs, so for a string-keyed map
  `byte_size(Jason.encode!(content)) == byte_size(CanonicalJson.encode!(content))`. The callers already hold
  `byte_size(Jason.encode!(content))` (the routers encode the content once), and pass it in; the envelope without content is a few
  hundred bytes. The write sites that already hold the signed canonical bytes use `stored_bytes/1` / `check_stored/1`. Floats are
  measured as Jason renders them (`1e2` becomes `100.0`); the spec's canonical JSON forbids floats at all (follow-up `fn`).

  An envelope is a STRING-keyed map WITHOUT `"content"`: `"room_id"`, `"type"`, `"state_key"` (`nil` for a message event),
  `"sender"`, `"origin_server_ts"`; build it with `envelope/5`.
  """

  @max_event_bytes 65_536
  @max_key_bytes 255

  # `,"event_id":"$<43>"` and `,"signatures":{"nebu":"<88>"}`: the two keys the stored event has on top of the signed map.
  @event_id_bytes 1 + 43
  @signature_bytes 88
  @event_id_part byte_size(~s(,"event_id":")) + @event_id_bytes + byte_size(~s("))
  @signatures_part byte_size(~s(,"signatures":{"nebu":")) + @signature_bytes + byte_size(~s("}))
  @signed_overhead @event_id_part + @signatures_part

  @doc "The maximum size of a complete event, in canonical JSON bytes (65 536)."
  @spec max_event_bytes() :: pos_integer()
  def max_event_bytes, do: @max_event_bytes

  @doc "The maximum size of an event `type` / `state_key`, in UTF-8 bytes (255)."
  @spec max_key_bytes() :: pos_integer()
  def max_key_bytes, do: @max_key_bytes

  @doc "The bytes `event_id` and `signatures` add to the signed canonical JSON of an event (171)."
  @spec signed_overhead() :: pos_integer()
  def signed_overhead, do: @signed_overhead

  @doc """
  The size of the STORED event given the signed canonical JSON (the `event_json` the write sites sign): the bytes of `event_json`
  plus `signed_overhead/0`.
  """
  @spec stored_bytes(binary()) :: non_neg_integer()
  def stored_bytes(event_json) when is_binary(event_json), do: byte_size(event_json) + @signed_overhead

  @doc """
  The size the stored event WILL have, from its envelope and the size of its content: the envelope is encoded with an empty content
  placeholder (`{}` is 2 bytes) and the content size is passed in.
  """
  @spec predicted_bytes(%{optional(String.t()) => term()}, non_neg_integer()) :: non_neg_integer()
  def predicted_bytes(envelope, content_bytes) when is_map(envelope) and is_integer(content_bytes) do
    byte_size(Nebu.Matrix.CanonicalJson.encode!(Map.put(envelope, "content", %{}))) - 2 + content_bytes + @signed_overhead
  end

  @doc "The envelope of an event (see the moduledoc); `state_key` is `nil` for a message event."
  @spec envelope(String.t(), String.t(), String.t(), String.t() | nil, non_neg_integer()) :: %{String.t() => term()}
  def envelope(room_id, sender, type, state_key, origin_server_ts) do
    %{
      "room_id" => room_id,
      "type" => type,
      "state_key" => state_key,
      "sender" => sender,
      "origin_server_ts" => origin_server_ts
    }
  end

  @doc """
  The key limits: `type` and `state_key` (raw decoded bytes, NOT code points and NOT their JSON form) at most 255 bytes, and the
  authenticated `sender` too (a session minted before the user ids were bounded at their source, `Nebu.Matrix.UserId`). A `nil`
  state key (a message event) is not counted. `:sender_too_long` is not a size problem the client can fix by changing the request:
  the routers answer it with a 403.
  """
  @spec check_keys(String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, :type_too_long | :state_key_too_long | :sender_too_long}
  def check_keys(type, state_key, sender) do
    cond do
      too_long?(type) -> {:error, :type_too_long}
      too_long?(state_key) -> {:error, :state_key_too_long}
      too_long?(sender) -> {:error, :sender_too_long}
      true -> :ok
    end
  end

  @doc "The size rule on a predicted event (`predicted_bytes/2`): exactly 65 536 is accepted, 65 537 is not. The keys are `check_keys/3`."
  @spec check(%{optional(String.t()) => term()}, non_neg_integer()) :: :ok | {:error, :event_too_large}
  def check(envelope, content_bytes), do: within_limit(predicted_bytes(envelope, content_bytes))

  @doc "The size rule on the signed canonical JSON a write site holds (`stored_bytes/1`)."
  @spec check_stored(binary()) :: :ok | {:error, :event_too_large}
  def check_stored(event_json), do: within_limit(stored_bytes(event_json))

  @typedoc "A refusal reason with a fixed client-facing text (`message/1`)."
  @type reason ::
          :event_too_large
          | :type_too_long
          | :state_key_too_long
          | :sender_too_long
          | :creation_content_too_large
          | :power_levels_too_large
          | :initial_state_event_too_large
          | :initial_state_type_too_long
          | :initial_state_key_too_long

  @doc """
  The FIXED client-facing text of a refusal (the `check*` reasons and the createRoom sources): never a client value, never a number
  other than the limit. The single source of every size text of the server: the limits in them are the module's own constants.
  """
  @spec message(reason()) :: String.t()
  def message(:event_too_large), do: "Event exceeds the maximum size of #{@max_event_bytes} bytes"
  def message(:type_too_long), do: "Event type exceeds #{@max_key_bytes} bytes"
  def message(:state_key_too_long), do: "State key exceeds #{@max_key_bytes} bytes"
  def message(:sender_too_long), do: "Your user id exceeds #{@max_key_bytes} bytes: sign in again"

  def message(:creation_content_too_large),
    do: "creation_content makes the m.room.create event exceed the maximum size of #{@max_event_bytes} bytes"

  def message(:power_levels_too_large),
    do: "power_level_content_override makes the m.room.power_levels event exceed the maximum size of #{@max_event_bytes} bytes"

  def message(:initial_state_event_too_large), do: "An initial_state event exceeds the maximum size of #{@max_event_bytes} bytes"
  def message(:initial_state_type_too_long), do: "An initial_state event type exceeds #{@max_key_bytes} bytes"
  def message(:initial_state_key_too_long), do: "An initial_state state key exceeds #{@max_key_bytes} bytes"

  defp within_limit(bytes) when bytes > @max_event_bytes, do: {:error, :event_too_large}
  defp within_limit(_bytes), do: :ok

  defp too_long?(value), do: is_binary(value) and byte_size(value) > @max_key_bytes
end
