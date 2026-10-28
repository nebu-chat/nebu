defmodule Nebu.Web.RateLimitTiers do
  @moduledoc """
  The per-USER rate-limit tiers of the room membership routes, the membership tiers (writes: invite, join, moderation; read: members_read)
  (story rate-limits-join-invite-create-room, D1, D4):

  | Tier           | Charged by                                                    | Default (rate per minute, burst) |
  |----------------|---------------------------------------------------------------|----------------------------------|
  | `create_room`  | 1 per `POST /createRoom`                                      | `{10, 20}`                       |
  | `invite`       | 1 per `POST /rooms/{roomId}/invite`, n per createRoom invitee | `{20, 50}`                       |
  | `join`         | 1 per `POST /join/{roomIdOrAlias}`                            | `{12, 30}`                       |
  | `moderation`   | 1 per `POST /rooms/{roomId}/kick`, `/ban` or `/unban`         | `{30, 60}`                       |
  | `members_read` | 1 per `GET /rooms/{roomId}/members` or `/initialSync`         | `{60, 30}`                       |

  The `moderation` tier (story moderation-routes-atomic-ban, D5) is a labelled divergence from the spec, which marks the three
  moderation endpoints "Rate-limited: No": a moderator clearing a spam wave bans dozens of accounts, so the budget is large, but
  it is not unbounded (every pre-emptive ban adds a state slot, follow-up `fp`). Internal callers (the ban copy of an upgrade) are
  not charged.

  The `members_read` tier (story membership-state-model, D14, Kassandra M-1) bounds the two member-state READS, whose cost grows
  with the member events of the room: 60 per minute, burst 30, a divergence from the spec (no rate limit listed). The initial `/sync`
  is not charged.

  Plain module without state (like `Nebu.Web.SessionConfig`): `create_room/0`, `invite/0`, `join/0`, `moderation/0` and `members_read/0` return
  `{rate_per_min, burst}`, read at REQUEST time from `Application.get_env(:nebu_http, :rate_limit_<tier>_per_min | _burst)`.
  `config/runtime.exs` fills those keys from the environment (`NEBU_RATE_LIMIT_<TIER>_PER_MIN` / `_BURST`, strictly positive
  int64 integers; anything else is ignored there).

  ## Invariants (a configured pair that breaks one falls back to the DEFAULT PAIR of its tier)

    * `burst / rate_per_min <= 60`: `Nebu.Web.RateLimitSweeper` evicts buckets idle for an hour, which is only free of effect when
      every bucket refills completely within the hour;
    * `invite`: `burst >= Nebu.Matrix.EventDispatcher.Server.invite_max_entries/0` (50), so a valid createRoom (one invite unit per
      invitee, at most 50) is never unsatisfiable.

  A half-configured pair takes the default for the absent half and is then checked as a pair. A value that is not a strictly
  positive integer (never produced by `runtime.exs`, but possible through the application env) counts as absent: the accessors
  never divide by zero. `invalid_settings/0` names the environment variables of every rejected pair and `warn_invalid_settings/0`
  logs one value-free warning per name (called once from `Nebu.Application.start/2`).

  ## Cluster semantics

  The buckets live in a node-local ETS table: with N nodes behind a load balancer that does not pin a user to a node, the
  effective budget of a user is up to N times the values above (follow-up `fi`). The pending-invitation caps, which are the
  cluster-wide bound, live in PostgreSQL.
  """
  require Logger

  @defaults %{create_room: {10, 20}, invite: {20, 50}, join: {12, 30}, moderation: {30, 60}, members_read: {60, 30}}
  @env %{
    create_room: {"NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN", "NEBU_RATE_LIMIT_CREATE_ROOM_BURST"},
    invite: {"NEBU_RATE_LIMIT_INVITE_PER_MIN", "NEBU_RATE_LIMIT_INVITE_BURST"},
    join: {"NEBU_RATE_LIMIT_JOIN_PER_MIN", "NEBU_RATE_LIMIT_JOIN_BURST"},
    moderation: {"NEBU_RATE_LIMIT_MODERATION_PER_MIN", "NEBU_RATE_LIMIT_MODERATION_BURST"},
    members_read: {"NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN", "NEBU_RATE_LIMIT_MEMBERS_READ_BURST"}
  }
  # {tier, :per_min | :burst} => the application env key (atoms built at compile time, never from runtime data)
  @keys Map.new(for(tier <- Map.keys(@defaults), part <- [:per_min, :burst], do: {{tier, part}, String.to_atom("rate_limit_#{tier}_#{part}")}))
  # a bucket must refill completely within this many minutes (the sweeper's one-hour argument)
  @max_full_refill_minutes 60

  @typedoc "`{rate_per_min, burst}`"
  @type tier :: {pos_integer(), pos_integer()}

  @doc "The `create_room` tier: `{rate_per_min, burst}`."
  @spec create_room() :: tier()
  def create_room, do: resolve(:create_room)

  @doc "The `invite` tier: `{rate_per_min, burst}`."
  @spec invite() :: tier()
  def invite, do: resolve(:invite)

  @doc "The `join` tier: `{rate_per_min, burst}`."
  @spec join() :: tier()
  def join, do: resolve(:join)

  @doc "The `moderation` tier (kick / ban / unban): `{rate_per_min, burst}`."
  @spec moderation() :: tier()
  def moderation, do: resolve(:moderation)

  @doc "The `members_read` tier (`GET /members`, `GET /initialSync`): `{rate_per_min, burst}`."
  @spec members_read() :: tier()
  def members_read, do: resolve(:members_read)

  @doc """
  The environment variable NAMES of every rejected tier pair (both variables of a rejected pair), `[]` when nothing is rejected.
  """
  @spec invalid_settings() :: [String.t()]
  def invalid_settings do
    for tier <- Map.keys(@defaults), not valid?(tier, configured(tier)), name <- Tuple.to_list(Map.fetch!(@env, tier)), do: name
  end

  @doc """
  Logs ONE warning per entry of `invalid_settings/0`: the variable NAME and the rule, never the configured value. Returns `:ok`.
  """
  @spec warn_invalid_settings() :: :ok
  def warn_invalid_settings do
    for name <- invalid_settings() do
      Logger.warning(
        "#{name} is ignored together with the other setting of its rate-limit tier: " <>
          "burst / rate_per_min must be at most #{@max_full_refill_minutes}, an invite burst at least " <>
          "#{Nebu.Matrix.EventDispatcher.Server.invite_max_entries()}; the default pair applies"
      )
    end

    :ok
  end

  defp resolve(tier) do
    pair = configured(tier)
    if valid?(tier, pair), do: pair, else: Map.fetch!(@defaults, tier)
  end

  # the configured pair, an absent / non-positive-integer half replaced by its default
  defp configured(tier) do
    {default_rate, default_burst} = Map.fetch!(@defaults, tier)
    {setting(tier, :per_min, default_rate), setting(tier, :burst, default_burst)}
  end

  defp setting(tier, part, default) do
    case Application.get_env(:nebu_http, Map.fetch!(@keys, {tier, part}), default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp valid?(tier, {rate, burst}) do
    burst <= @max_full_refill_minutes * rate and (tier != :invite or burst >= Nebu.Matrix.EventDispatcher.Server.invite_max_entries())
  end
end
