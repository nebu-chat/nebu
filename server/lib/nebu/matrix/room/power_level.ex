defmodule Nebu.Matrix.Room.PowerLevels do
  @moduledoc """
  Pure functions for Matrix power level evaluation (room version 10).
  All maps use string keys (architecture rule: no atom keys in DB-sourced maps).

  Story power-levels-enforcement (follow-ups `eq`, `er`, `fr`):

    * READ (D4): every check reads the NORMALISED view (`normalize/1`), so a stored value that is not a v10 integer can never
      decide anything (in Erlang term order every binary is greater than every integer: a string user level `"100"` passed
      every `>=` before). A threshold that is not an integer reads as its spec default, a `users` / `events` /
      `notifications` value that is not an integer reads as absent. `get_user_level/2`, `required_level/2` and `can?/3`
      accept the RAW stored content or the normalised view (normalising is idempotent).
    * WRITE (D3): `validate_content/1` is the ONE strict shape validator of every path that writes levels (the PUT route,
      `power_level_content_override`, an `initial_state` entry, the internal writer).
    * CHANGE (D2 (5)): `check_change/3` applies the v10 rules (5) - (7) of a new content against the CURRENT one.
    * DEFAULTS (D12, NON-SPEC, Synapse-derived): `default_levels/0` carries a default `events` map for NEW rooms.

  `redact` is evaluated by the redaction writer (`required_level(levels, :redact)`, story state-writer-redaction); `notifications` is
  not evaluated anywhere (no server-side push processing, a note on follow-up `ad`): it is validated, stored and delivered.
  """

  alias Nebu.Matrix.UserId

  # room v10 canonical-JSON integer range of a power level value (±(2^53 - 1))
  @max_level 9_007_199_254_740_991
  @max_key_bytes 255

  # the seven integer keys of the v10 content and their spec defaults
  @spec_defaults %{
    "ban" => 50,
    "kick" => 50,
    "invite" => 0,
    "redact" => 50,
    "state_default" => 50,
    "events_default" => 0,
    "users_default" => 0
  }
  @int_keys Map.keys(@spec_defaults)
  @level_maps ~w(events notifications)

  # D12 (NON-SPEC, Synapse-derived, not verifiable in the spec bundle): the default `events` map of NEW rooms
  @default_events %{
    "m.room.power_levels" => 100,
    "m.room.history_visibility" => 100,
    "m.room.tombstone" => 100,
    "m.room.server_acl" => 100,
    "m.room.encryption" => 100,
    "m.room.name" => 50,
    "m.room.avatar" => 50,
    "m.room.canonical_alias" => 50
  }

  @default_levels Map.merge(@spec_defaults, %{"users" => %{}, "events" => @default_events})

  # the fixed texts of the shape validator (the texts of the createRoom override rule; no client value is ever echoed)
  @text_not_object "power levels must be an object"
  @text_null "power levels must not contain null values"
  @text_integer "power level values must be integers within +-(2^53 - 1)"
  @text_events_object "events must be an object"
  @text_events_key "events keys must be non-empty event types of at most 255 bytes"
  @text_users_object "users must be an object"
  @text_users_key "users keys must be valid user ids"
  @text_notifications_object "notifications must be an object"

  @type change_error :: :above_own_level | :grant_above_own_level | :target_not_lower

  @doc "Returns the default Matrix power levels map of a NEW room (string keys), the D12 `events` map included."
  @spec default_levels() :: map()
  def default_levels, do: @default_levels

  @doc "True for an integer within the v10 range ±(2^53 - 1)."
  @spec level?(term()) :: boolean()
  def level?(value), do: is_integer(value) and value >= -@max_level and value <= @max_level

  @doc "The fixed text of a `null` value (`power_level_content_override` keeps its own wording for it)."
  @spec null_text() :: String.t()
  def null_text, do: @text_null

  # ─── the tolerant read (D4) ──────────────────────────────────────────────────────────────────────────────────────

  @doc """
  The normalised view every decision reads: the seven integer keys (each a v10 integer, else its spec default), `users`,
  `events` and `notifications` as maps holding only v10 integer values (`notifications.room` defaults to 50). Other keys are
  dropped. Idempotent; a content that is not a map reads as `%{}`.
  """
  @spec normalize(term()) :: map()
  def normalize(content) when is_map(content) do
    @spec_defaults
    |> Map.new(fn {key, default} -> {key, if(level?(content[key]), do: content[key], else: default)} end)
    |> Map.put("users", level_map(content["users"]))
    |> Map.put("events", level_map(content["events"]))
    |> Map.put("notifications", Map.merge(%{"room" => 50}, level_map(content["notifications"])))
  end

  def normalize(_other), do: normalize(%{})

  # the entries of a level map whose value is a v10 integer (anything else reads as absent)
  defp level_map(map) when is_map(map), do: for({key, value} <- map, is_binary(key), level?(value), into: %{}, do: {key, value})
  defp level_map(_other), do: %{}

  @doc "The effective level of `user_id`, always an integer: `users[user_id]`, else `users_default` (normalised view)."
  @spec get_user_level(map(), String.t()) :: integer()
  def get_user_level(levels, user_id) do
    view = normalize(levels)
    Map.get(view["users"], user_id, view["users_default"])
  end

  @doc """
  The level an action needs (normalised view). `{:message, type}` / `{:state, type}` (D5): `events[type]` when present, else
  `events_default` / `state_default`. The atoms keep their meaning: `:send_event` (`events_default`), `:change_state`
  (`state_default`), `:invite`, `:kick`, `:ban`, `:redact` (the level to redact ANOTHER sender's event, story
  state-writer-redaction).
  """
  @spec required_level(map(), {:message | :state, String.t()} | :send_event | :change_state | :invite | :kick | :ban | :redact) :: integer()
  def required_level(levels, {kind, event_type}) when kind in [:message, :state] do
    view = normalize(levels)

    case Map.fetch(view["events"], event_type) do
      {:ok, level} -> level
      :error when kind == :message -> view["events_default"]
      :error -> view["state_default"]
    end
  end

  def required_level(levels, :send_event), do: normalize(levels)["events_default"]
  def required_level(levels, :change_state), do: normalize(levels)["state_default"]
  def required_level(levels, action) when action in [:invite, :kick, :ban, :redact], do: normalize(levels)[Atom.to_string(action)]

  @doc """
  Returns `true` if `user_id` has sufficient power to perform `action` (see `required_level/2` for the actions).
  """
  @spec can?(map(), String.t(), atom() | {:message | :state, String.t()}) :: boolean()
  def can?(power_levels, user_id, action), do: get_user_level(power_levels, user_id) >= required_level(power_levels, action)

  @doc """
  The level a room upgrade needs (story state-writer-redaction, D11, follow-up `fx`): the tombstone level (`events["m.room.tombstone"]`,
  else `state_default`) with a floor of 100 (a Nebu restriction: the upgrader carries the levels into the new room, whose
  `events["m.room.power_levels"]` is 100).
  """
  @spec upgrade_level(map()) :: integer()
  def upgrade_level(levels), do: max(required_level(levels, {:state, "m.room.tombstone"}), 100)

  @doc """
  The strictly valid part of a stored content (D8, the copy of an upgrade): every value that is not v10-valid (a non-integer
  level, an invalid `users` / `events` key, a non-object level map, `null`) is dropped SILENTLY, every other key is kept as stored.
  A `users` entry whose id fails `UserId.valid?/1` (above 255 bytes, a port) is dropped too, EXCEPT the ids in `keep_users`
  (fix cycle 2, Kassandra D-L1: the upgrader's own id, kept when it passes the relaxed grammar, so an upgrade never leaves the
  upgrader without his level); the result passes `validate_content/2` with `stored_users` holding those entries.
  """
  @spec valid_subset(term(), [String.t()]) :: map()
  def valid_subset(content, keep_users \\ [])

  def valid_subset(content, keep_users) when is_map(content) do
    keep? = fn k -> UserId.valid?(k) or (k in keep_users and grammar_user_id?(k)) end

    Enum.reduce(content, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc when key in @int_keys -> if level?(value), do: Map.put(acc, key, value), else: acc
      {"users", value}, acc when is_map(value) -> Map.put(acc, "users", Map.filter(level_map(value), fn {k, _} -> keep?.(k) end))
      {"events", value}, acc when is_map(value) -> Map.put(acc, "events", Map.filter(level_map(value), fn {k, _} -> event_type_key?(k) end))
      {"notifications", value}, acc when is_map(value) -> Map.put(acc, "notifications", level_map(value))
      {key, _not_a_map}, acc when key in ["users", "events", "notifications"] -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  def valid_subset(_other, _keep_users), do: %{}

  @doc "Every level of a content (the seven keys, `users`, `events`, `notifications`), normalised view: the input of D8's check."
  @spec all_levels(term()) :: [integer()]
  def all_levels(content) do
    view = normalize(content)
    Map.values(Map.take(view, @int_keys)) ++ Enum.flat_map(["users" | @level_maps], &Map.values(view[&1]))
  end

  # ─── the strict write (D3) ───────────────────────────────────────────────────────────────────────────────────────

  @doc """
  The v10 shape of a levels content: an object; the seven integer keys, when present, v10 integers (a float such as `50.0`, a
  string, a boolean is refused); `events` / `notifications`, when present, objects of such integers (`events` keys non-empty
  and at most 255 bytes); `users`, when present, an object whose keys are valid user ids and whose values are such integers;
  no `null` value at the top level; other top-level keys are kept as sent. An absent `users` / `events` / `notifications` is
  allowed (absent `users`: a Nebu choice, the spec is ambiguous; Synapse parity). `:ok` or `{:error, fixed text}`.

  The `users` keys (`opts`):

    * default: strict, `UserId.valid?/1` (at most 255 bytes, no port);
    * `users_keys: :grammar` (the INTERNAL writer only): the user-id grammar without the 255-byte bound and with an optional
      server-name port, for every key (the ids the server itself chose: creator, upgrader, invitees);
    * `stored_users: map` (the CLIENT writer, fix cycle 2, Kassandra D-L1): a key that fails the strict rule is still accepted
      when it passes the relaxed grammar AND is UNCHANGED from the stored `users` map (same key, same value), so a full-content
      PUT that repeats the entry of a creator with a port or a long id is not refused; an added or changed such key stays refused.
  """
  @spec validate_content(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_content(content, opts \\ [])

  def validate_content(content, opts) when is_map(content) do
    grammar? = Keyword.get(opts, :users_keys, :strict) == :grammar
    stored = Keyword.get(opts, :stored_users, %{})
    stored = if is_map(stored), do: stored, else: %{}
    new_users = if is_map(content["users"]), do: content["users"], else: %{}

    user_key? = fn key ->
      cond do
        grammar? -> grammar_user_id?(key)
        UserId.valid?(key) -> true
        true -> grammar_user_id?(key) and Map.has_key?(stored, key) and same_json?(stored[key], new_users[key])
      end
    end

    Enum.find_value(content, :ok, fn
      {_key, nil} -> {:error, @text_null}
      {key, value} when key in @int_keys -> if level?(value), do: nil, else: {:error, @text_integer}
      {"events", value} -> validate_level_map(value, @text_events_object, &event_type_key?/1, @text_events_key)
      {"users", value} -> validate_level_map(value, @text_users_object, user_key?, @text_users_key)
      {"notifications", value} -> validate_level_map(value, @text_notifications_object, &is_binary/1, @text_integer)
      {_other_key, _value} -> nil
    end)
  end

  def validate_content(_other, _opts), do: {:error, @text_not_object}

  # the relaxed user-id grammar (review cycle 0 M4, fix cycle 2 D-L1): WITHOUT the 255-byte bound and with an optional `:port` of
  # the server name; used for every key of the INTERNAL writer and, in the client writer, only for an UNCHANGED stored entry
  defp grammar_user_id?(user_id) when is_binary(user_id),
    do: UserId.valid_shape?(user_id) or UserId.valid_shape?(Regex.replace(~r/:[0-9]{1,5}\z/, user_id, ""))

  defp grammar_user_id?(_other), do: false

  # nil (the value of Enum.find_value/2 for "no error") or {:error, text}
  defp validate_level_map(map, _object_text, key_ok?, key_text) when is_map(map) do
    Enum.find_value(map, fn {key, level} ->
      cond do
        not key_ok?.(key) -> {:error, key_text}
        not level?(level) -> {:error, @text_integer}
        true -> nil
      end
    end)
  end

  defp validate_level_map(_other, object_text, _key_ok?, _key_text), do: {:error, object_text}

  defp event_type_key?(key), do: is_binary(key) and key != "" and byte_size(key) <= @max_key_bytes

  @doc """
  STRICT structural equality of two decoded JSON values (fix cycle 3, Kassandra C2-L1): maps with the same keys and strictly equal
  values, lists element by element, scalars with `===` (so `100.0` and `100` differ at every depth, unlike `==`). Every
  "unchanged" / "altered" / "identical" decision on levels content uses it.
  """
  @spec same_json?(term(), term()) :: boolean()
  def same_json?(a, b) when is_map(a) and is_map(b),
    do: map_size(a) == map_size(b) and Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and same_json?(v, Map.fetch!(b, k)) end)

  def same_json?(a, b) when is_list(a) and is_list(b), do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same_json?(x, y) end)
  def same_json?(a, b), do: a === b

  # ─── the change rules (D2 (5)) ───────────────────────────────────────────────────────────────────────────────────

  @doc """
  The v10 change rules (5) - (7) of the RAW `new` content against the RAW `current` stored content for `sender_id`, whose level
  is read from the current levels (normalised). First failure wins, in rule order:

    * (5) each of the seven integer keys that is added, changed or removed: a current value above the sender's level is
      `:above_own_level`, a new value above it is `:grant_above_own_level`;
    * (6) the same for each entry of `events` and `notifications`;
    * (7) each `users` entry that is added, changed or removed: the CURRENT value of another user's entry at or above the
      sender's level is `:target_not_lower` (the sender may lower or remove his own entry), a new value above the sender's
      level is `:grant_above_own_level`.

  "Added, changed or removed" compares the RAW maps (a key absent on one side is an alteration, even when the other side holds
  the default); the values compared with the sender's level are the normalised ones (a legacy value that is not an integer
  reads as its default / as absent, D4). Unknown top-level keys are not subject to the rules.
  """
  @spec check_change(map(), map(), String.t()) :: :ok | {:error, change_error()}
  def check_change(current, new, sender_id) do
    current = if is_map(current), do: current, else: %{}
    new = if is_map(new), do: new, else: %{}
    view = normalize(current)
    sender = Map.get(view["users"], sender_id, view["users_default"])

    with :ok <- check_scalar_keys(current, new, view, sender),
         :ok <- check_level_map("events", current, new, sender),
         :ok <- check_level_map("notifications", current, new, sender) do
      check_users(current, new, view, sender, sender_id)
    end
  end

  defp check_scalar_keys(current, new, view, sender) do
    first_error(@int_keys, fn key ->
      if altered?(current, new, key) do
        old_value = if Map.has_key?(current, key), do: view[key]
        check_entry(old_value, new[key], sender)
      end
    end)
  end

  # the current value of an entry is the STORED integer (review cycle 0 M5: never the `notifications.room` default 50 that the
  # normalised view injects for an absent entry; an absent or non-integer entry has no current value)
  defp check_level_map(name, current, new, sender) do
    old_raw = raw_map(current[name])
    new_raw = raw_map(new[name])
    old_levels = level_map(old_raw)

    first_error(keys_of(old_raw, new_raw), fn key ->
      if altered?(old_raw, new_raw, key), do: check_entry(Map.get(old_levels, key), new_raw[key], sender)
    end)
  end

  defp check_users(current, new, view, sender, sender_id) do
    old_raw = raw_map(current["users"])
    new_raw = raw_map(new["users"])

    first_error(keys_of(old_raw, new_raw), fn user_id ->
      if altered?(old_raw, new_raw, user_id) do
        old_value = Map.get(view["users"], user_id)
        new_value = new_raw[user_id]

        cond do
          user_id != sender_id and is_integer(old_value) and old_value >= sender -> {:error, :target_not_lower}
          level?(new_value) and new_value > sender -> {:error, :grant_above_own_level}
          true -> :ok
        end
      end
    end)
  end

  defp check_entry(old_value, new_value, sender) do
    cond do
      is_integer(old_value) and old_value > sender -> {:error, :above_own_level}
      level?(new_value) and new_value > sender -> {:error, :grant_above_own_level}
      true -> :ok
    end
  end

  # the first `{:error, _}` the check answers for the keys, else :ok (nil and :ok both mean "no refusal")
  defp first_error(keys, check), do: Enum.find_value(keys, :ok, fn key -> with :ok <- check.(key), do: nil end)

  # fix cycle 3 (Kassandra C2-L1): STRICT comparison (a stored legacy float 100.0 is not the integer 100: the read path treats the
  # float as absent, so replacing it by the integer IS an alteration that the rules must see)
  defp altered?(old_map, new_map, key), do: not same_entry?(Map.fetch(old_map, key), Map.fetch(new_map, key))

  defp same_entry?({:ok, a}, {:ok, b}), do: same_json?(a, b)
  defp same_entry?(:error, :error), do: true
  defp same_entry?(_a, _b), do: false
  defp raw_map(map) when is_map(map), do: map
  defp raw_map(_other), do: %{}
  defp keys_of(a, b), do: Enum.uniq(Map.keys(a) ++ Map.keys(b))
end
