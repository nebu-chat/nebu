defmodule Nebu.Web.Router.Protected do
  @moduledoc """
  AUTHENTICATED Matrix Client-Server API routes (matrix-api-migration).

  `Nebu.Web.Plugs.OidcPlug` runs in this router's pipeline, so every matched
  route requires a valid Bearer token. On failure OidcPlug halts with a 401
  Matrix-error envelope; on success it assigns `current_user` (the `@user:server`
  Matrix id) which the handlers below pass as the trusted identity.

  The top-level `Nebu.Web.Router` forwards everything under `/_matrix` here
  EXCEPT the explicitly unauthenticated paths (login, GET profile, MSC2965
  discovery), which it routes to `Nebu.Matrix.HttpPublic` first.

  ## No gRPC hop

  Each handler calls the SAME `Nebu.Matrix.EventDispatcher.Server` function the gRPC
  server exposes, passing a fake stream (`Nebu.Matrix.Http.stream/1`) that carries
  the trusted identity in the metadata shape `Nebu.Matrix.RequestMetadata` reads. The
  server functions delegate to the Room GenServers / session store / `:pg`
  fan-out directly — no serialization across a gRPC boundary (AC2 hot path).
  """
  use Plug.Router

  import Nebu.Matrix.Http

  require Logger

  alias Nebu.Matrix.DeviceKeyStore
  alias Nebu.Matrix.CrossSigningKeyStore

  # Server-managed account data types: clients MUST NOT set them (405 M_BAD_JSON), global
  # and room scope (Matrix CS, Client Config). Reading them is allowed.
  @server_managed_account_data_types ["m.fully_read", "m.push_rules"]

  # Per-USER rate limit of the account-data PUT routes (global + room scope): 60 writes/min,
  # burst 30. Real clients write a handful of entries per minute (tags, marked_unread);
  # this only stops scripted floods. Bucketed by user (not IP), separate tier "account_data".
  @account_data_write_rate_limit Nebu.Web.Plugs.RateLimit.init(
                                   rate_per_min: 60,
                                   burst: 30,
                                   tier: "account_data",
                                   key: :user
                                 )

  # Pipeline (story oauth-room-summary-unrecognized, RU10): :match runs BEFORE authentication so the
  # catch-all (`match _`, marked `nebu_unrecognized: true`) can answer an unimplemented endpoint with a
  # spec `M_UNRECOGNIZED` without any credential check. Every real route still runs the OidcPlug in
  # :authenticate; a halted conn (401) never dispatches.
  plug :fetch_query_params
  plug :match
  plug :authenticate
  plug :dispatch

  @doc """
  Pipeline step after `:match`: runs `Nebu.Web.Plugs.OidcPlug` for every matched route and skips it ONLY
  when the catch-all marked the conn (`conn.private[:nebu_unrecognized] === true`, strict boolean:
  `false`, `"true"`, `1`, `nil` or an absent key all authenticate). Fail closed by construction.
  """
  @spec authenticate(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def authenticate(%Plug.Conn{private: %{nebu_unrecognized: true}} = conn, _opts), do: conn
  def authenticate(conn, _opts), do: Nebu.Web.Plugs.OidcPlug.call(conn, Nebu.Web.Plugs.OidcPlug.init([]))

  # ── GET /_matrix/client/v3/sync ───────────────────────────────────────────
  # BEAM-native long-poll: get_sync_delta / get_initial_sync subscribe to :pg
  # groups and block in the request process up to `timeout` ms (AC2). The Go
  # gateway's two-call pattern (delta then fallback-to-initial) is reproduced.
  # F-3: a sensible per-IP rate limit on /sync. /sync is a legitimate
  # high-frequency long-poll, so the ceiling is generous (600 req/min, burst 100)
  # — it does not impede a normal client but caps a single IP that hammers the
  # endpoint to exhaust BEAM long-poll processes. Authenticated, so this is a
  # secondary control behind OidcPlug; the brute-force-sensitive endpoint is
  # /login (handled with a much tighter 30/min limit in MatrixPublic).
  @sync_rate_limit Nebu.Web.Plugs.RateLimit.init(rate_per_min: 600, burst: 100, tier: "sync")

  get "/client/v3/sync" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @sync_rate_limit)

    if conn.halted do
      conn
    else
      do_sync(conn)
    end
  end

  defp do_sync(conn) do
    user = conn.assigns[:current_user]
    q = conn.query_params
    since = q["since"]
    timeout_ms = parse_timeout(q["timeout"])

    # story sync-token-per-device (D1 / D2): the since token is stored under (user, AUTHENTICATED device): the device of the
    # opaque session or of the server-side binding of a raw IdP JWT, never a request parameter. A request without a device
    # (an unbound raw IdP JWT) is "" = the per-user row and the consume-once flags, as before.
    device_id = authenticated_device_id(conn)

    # room-account-data-and-read-markers: Nebu's `next_batch`/`since` token is
    # `<core token>[.<room account data position>]`. The core token (opaque, `s2_` + base64url since story
    # sync-stream-position: no '.') is only compared with the token stored in the caller's own sync_tokens row
    # (per device since story sync-token-per-device); the suffix is the
    # `stream_pos` up to which this client has received ROOM account data (per DEVICE,
    # because it lives in the client's own token). A token without a suffix (issued
    # before this feature) means position 0 = "all room account data" (delivered once).
    {core_since, since_pos} = split_since_token(since)
    has_since? = is_binary(core_since) and core_since != ""

    # S2 AC5: advance the device's last_seen_ts/last_seen_ip on this authenticated
    # activity, THROTTLED inside the store so back-to-back /syncs don't hammer the DB.
    # Best-effort: must never fail the /sync it rides on.
    touch_device_last_seen(conn)

    # story sync-token-per-device (D9): a device-bound request reads the two delivery positions of ITS row once, BEFORE the
    # core call (the core's token write does not advance them). A failed read is {0, 0}: everything is delivered again. Story
    # sync-stream-position (D8): the positions of the generation the client's core token names (a retry with the previous
    # next_batch gets the previous generation's).
    positions =
      if device_id != "",
        do: Nebu.Matrix.Session.PgStore.get_positions(user, device_id, if(has_since?, do: core_since)),
        else: nil

    # Room account data already waiting for this token → do not long-poll. Story sync-token-per-device (D11): the same for
    # GLOBAL account data this device has not been sent yet (a PUT committed between two requests; a PUT during the wait
    # wakes the core through `{:account_data_changed, nil}`). A device-less request has no position and no pre-check.
    timeout_ms =
      if has_since? and
           (Nebu.Matrix.RoomAccountDataStore.pending?(user, since_pos) or global_account_data_pending?(user, positions)),
         do: 0,
         else: timeout_ms

    # Story sync-membership-partition (D14): only the literal "true" asks for the full state; with a `since` the core then
    # returns at once (the spec ignores `timeout`) with every joined room's full state. Without a `since` it changes nothing.
    full_state? = q["full_state"] == "true"

    # A failed membership read is a 503 M_UNAVAILABLE (D10, fail closed) with no token saved: the client retries.
    case Nebu.Matrix.Http.call_core(fn -> core_sync(user, device_id, has_since?, core_since, timeout_ms, full_state?) end) do
      {:ok, sync} -> finish_sync(conn, user, {device_id, positions}, since_pos, has_since?, sync)
      {:error, err} -> send_error(conn, err)
    end
  end

  defp authenticated_device_id(conn) do
    case conn.assigns[:device_id] do
      device_id when is_binary(device_id) -> device_id
      _ -> ""
    end
  end

  defp global_account_data_pending?(_user, nil), do: false
  defp global_account_data_pending?(user, {ad_pos, _cs_pos}), do: Nebu.Matrix.AccountDataStore.pending_since?(user, ad_pos)

  # `get_sync_delta` already returns the fully-resolved checkpoint: on an unknown/stale since_token it transparently falls back
  # to an initial sync and sets `fallback_to_initial: true` while putting the full snapshot in `rooms` and a fresh `since_token`.
  # The HTTP /sync response shape is identical in both cases. Without a `since` the initial sync is the (fallback) snapshot.
  # Both persist the new token under the request's key (`device_id`, "" = the per-user row).
  defp core_sync(user, device_id, true, core_since, timeout_ms, full_state?) do
    Nebu.Matrix.EventDispatcher.Server.get_sync_delta(
      %Core.GetSyncDeltaRequest{
        user_id: user,
        since_token: core_since,
        timeout_ms: timeout_ms,
        device_id: device_id,
        full_state: full_state?
      },
      stream(user)
    )
  end

  defp core_sync(user, device_id, false, _core_since, _timeout_ms, _full_state?) do
    initial =
      Nebu.Matrix.EventDispatcher.Server.get_initial_sync(
        %Core.GetInitialSyncRequest{user_id: user, device_id: device_id},
        stream(user)
      )

    %Core.GetSyncDeltaResponse{
      since_token: initial.since_token,
      rooms: initial.rooms,
      fallback_to_initial: true,
      join_room_ids: initial.join_room_ids,
      invite_rooms: initial.invite_rooms,
      leave_rooms: initial.leave_rooms
    }
  end

  defp finish_sync(conn, user, key, since_pos, has_since?, sync) do
    rooms = sync.rooms
    fallback? = sync.fallback_to_initial

    # Rooms the user newly joined in this delta: the client has never seen their
    # account data, so deliver ALL of it (not only changes after the position).
    # Story sync-stream-position (D11): the core reports them from the device's cursors (a newest-20 timeline can omit the join event).
    full_rooms = if has_since? and not fallback?, do: sync.newly_joined_room_ids, else: []

    {latest_pos, ad_entries} =
      Nebu.Matrix.RoomAccountDataStore.list_for_sync(user, since_pos, full_rooms)

    # A room whose ONLY change is account data must still appear in rooms.join
    # (empty timeline/state). Only for true deltas — initial/fallback already carry
    # every joined room. Story sync-membership-partition (D11): only for rooms of the
    # JOIN class: a room the user was banned from / left / is only invited to has an
    # account data row but must never come back as an (empty) joined room.
    present = MapSet.new(rooms, & &1.room_id)
    join_class = MapSet.new(sync.join_room_ids)

    extra_rooms =
      if has_since? and not fallback? do
        ad_entries
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(present, &1))
        |> Enum.filter(&MapSet.member?(join_class, &1))
        |> Enum.map(fn rid ->
          %Core.SyncRoom{room_id: rid, state_events: [], timeline_events: [], limited: false, prev_batch: ""}
        end)
      else
        []
      end

    room_ad =
      Enum.group_by(
        ad_entries,
        fn {rid, _t, _c} -> rid end,
        fn {_rid, t, c} -> %{"type" => t, "content" => c} end
      )

    response =
      sync_response(
        sync.since_token <> "." <> Integer.to_string(latest_pos),
        rooms ++ extra_rooms,
        room_ad,
        sync.invite_rooms,
        sync.leave_rooms
      )
      |> put_device_e2e_counts(conn)
      |> put_global_deliveries(user, key, has_since?, fallback?, sync.since_token)

    send_json(conn, 200, response)
  end

  # `<core>[.<pos>]` → {core, pos}; nil → {nil, 0}.
  #
  # The position suffix is recognised ONLY as a trailing `.` + ASCII digits (so `+5`, `-1`,
  # `5x`, an empty suffix or `a.b.c` are NOT positions: the whole token stays the core and
  # an unknown core falls back to an initial sync). The core is the whole token minus that
  # trailing digit suffix (the real core is opaque base64 without '.'). A digit suffix with
  # more than 19 digits or a value above int8 max (9_223_372_036_854_775_807) is still
  # stripped but yields position 0 (= redeliver all room account data) so it can never
  # reach the database as an out-of-range parameter. A position above the user's latest
  # is clamped by `RoomAccountDataStore.list_for_sync/3` (it returns the real latest).
  @max_token_pos 9_223_372_036_854_775_807

  defp split_since_token(since) when is_binary(since) do
    case Regex.run(~r/\A(.+)\.([0-9]+)\z/s, since) do
      [_, core, digits] ->
        pos = if byte_size(digits) <= 19, do: String.to_integer(digits), else: 0
        {core, if(pos <= @max_token_pos, do: pos, else: 0)}

      _ ->
        {since, 0}
    end
  end

  defp split_since_token(_), do: {nil, 0}

  # Top-level `account_data.events` (Matrix CS §GET /sync) and the user's OWN id in `device_lists.changed` after a
  # cross-signing key change (CS §Cross-signing). Global account data is durable (PostgreSQL, story account-data-durability)
  # so Element's secret-storage / recovery material survives restarts and is delivered to the client. Each entry is
  # `{type, content}`; content is opaque (ADR-011 — never parsed/decrypted here). An initial-shaped answer (no `since`, or a
  # fallback) delivers ALL of the user's global account data, a true delta only what changed since the client's last response.
  #
  # story sync-token-per-device (D9): a DEVICE-bound request delivers both by the two POSITIONS of its own sync_tokens row
  # (read once before the core call): the account data rows with `stream_pos > account_data_pos` (every row when the answer
  # is initial-shaped) and the own user when `changed_pos > cross_signing_pos` on a true delta. Nothing is consumed, so every
  # device (the writer included) gets every change once. Then BOTH columns advance, each ONLY to the maximum read from ITS
  # OWN source (two sources read at different moments: one shared column could skip a row committed in between), with
  # GREATEST and only while the row still holds the token of THIS response (a superseded response never advances them).
  # A failed read / advance leads to delivering again, never to missing: a failed account data read in a true delta keeps
  # `account_data_pos` (the rows come with the next sync); a failed read in an INITIAL-SHAPED answer (which delivered none,
  # and whose client may have reset its state) sets `account_data_pos` back to 0 (plain SET under the same token guard,
  # review m1), so the next delta delivers every row. `full_state=true` only widens the ROOM state.
  #
  # D10: a fallback to a request that carried a `since` ALWAYS lists the own user (the client cannot know it got an
  # initial-shaped answer and would miss a cross-signing change); a real initial sync (no `since`) lists nobody. The own user
  # is never put in `device_lists.left`.
  #
  # D2: a DEVICE-LESS request (an unbound raw IdP JWT) keeps the per-user consume-once flags exactly as before (read and
  # cleared atomically, only with a `since` for the cross-signing flag); only D10 also applies to it.
  defp put_global_deliveries(response, user, {device_id, {ad_pos, cs_pos}}, has_since?, fallback?, core_token)
       when device_id != "" do
    initial_shaped? = fallback? or not has_since?

    ad_read = Nebu.Matrix.AccountDataStore.list_since_checked(user, if(initial_shaped?, do: 0, else: ad_pos))
    {cs_latest, cs_changed?} = CrossSigningKeyStore.changed_since?(user, cs_pos)
    cs_target = max(cs_latest, cs_pos)

    entries =
      case ad_read do
        {:ok, ad_latest, entries} ->
          _ = Nebu.Matrix.Session.PgStore.advance_positions(user, device_id, core_token, max(ad_latest, ad_pos), cs_target)
          entries

        :error when initial_shaped? ->
          _ = Nebu.Matrix.Session.PgStore.rewind_account_data_position(user, device_id, core_token, cs_target)
          []

        :error ->
          _ = Nebu.Matrix.Session.PgStore.advance_positions(user, device_id, core_token, ad_pos, cs_target)
          []
      end

    response
    |> put_global_account_data_events(entries)
    |> put_own_user_changed(user, (has_since? and fallback?) or (not initial_shaped? and cs_changed?))
  end

  defp put_global_deliveries(response, user, _device_less, has_since?, fallback?, _core_token) do
    entries =
      if has_since?,
        do: Nebu.Matrix.AccountDataStore.list_changed_and_clear(user),
        else: Nebu.Matrix.AccountDataStore.list_all_and_clear(user)

    # the flag is consumed by every request that carries a since (a fallback too), as before
    consumed? = has_since? and CrossSigningKeyStore.consume_changed_flag(user)

    response
    |> put_global_account_data_events(entries)
    |> put_own_user_changed(user, consumed? or (has_since? and fallback?))
  end

  defp put_global_account_data_events(response, entries) do
    events = Enum.map(entries, fn {type, content} -> %{"type" => type, "content" => content} end)
    Map.put(response, "account_data", %{"events" => events})
  end

  defp put_own_user_changed(response, user, true),
    do: update_in(response, ["device_lists", "changed"], fn changed -> Enum.uniq([user | changed || []]) end)

  defp put_own_user_changed(response, _user, false), do: response

  # E2E extension to /sync (Matrix CS §e2e-extensions-to-sync): report the unclaimed
  # one-time-key count + unused fallback-key algorithms so the client's crypto layer
  # stops re-uploading. Raw OIDC JWTs carry no device_id (see OidcPlug); for those we
  # fall back to the user-aggregate count (exact for a single-device user). This is the
  # key DIRECTORY only — it does not enable E2EE (ADR-011).
  defp put_device_e2e_counts(response, conn) do
    user = conn.assigns[:current_user]

    otk_counts =
      case conn.assigns[:device_id] do
        did when is_binary(did) and did != "" -> DeviceKeyStore.otk_counts(user, did)
        _ -> DeviceKeyStore.otk_counts_for_user(user)
      end

    response
    |> Map.put("device_one_time_keys_count", otk_counts)
    |> Map.put("device_unused_fallback_key_types", DeviceKeyStore.unused_fallback_key_types_for_user(user))
  end

  # ── POST /_matrix/client/v3/logout ────────────────────────────────────────
  #
  # story oauth-token-revocation-logout (R15): an OAuth access token ends ONLY its own device's
  # session through the SAME function as POST /oauth2/revoke (`Nebu.Matrix.oauth_revoke_token/1`:
  # session rows, device, keys); the user's other devices (OAuth and legacy) are untouched. OAuth vs
  # legacy is decided at AUTHENTICATION time (`:auth_api`, set by OidcPlug), never by a lookup here
  # (Trap 4: a concurrent revocation would turn a lookup miss into the user-wide legacy wipe).
  #
  # bugfix legacy-logout-per-device (LL1-LL8, gate r): a LEGACY caller (opaque Nebu token, raw IdP JWT
  # bound or unbound) ends ONLY the device its credential is bound to server-side (`:device_id` of the
  # authentication, never request input) with the same locked teardown (`Nebu.Matrix.legacy_logout_device/1`):
  # every session row of the device, the device, its keys. A bound JWT is then denylisted CHECKED, also when
  # the re-check under the lock found the device taken over (`{:ok, :unknown}`); an unbound JWT is only
  # denylisted. A storage failure is `500 M_UNKNOWN` (never a silent 200 with a live credential). The
  # request body is ignored. The user-wide wipe is `/logout/all`'s legacy part only (`legacy_user_wipe/2`).
  post "/client/v3/logout" do
    if conn.assigns[:auth_api] == "oauth" do
      case Nebu.Matrix.oauth_revoke_token(conn.assigns[:access_token]) do
        {:ok, _} -> send_json(conn, 200, %{})
        {:ok, :revoked, _info} -> send_json(conn, 200, %{})
        {:error, :unavailable} -> error(conn, 500, "M_UNKNOWN", "Logout failed, please try again.")
      end
    else
      legacy_device_logout(conn)
    end
  end

  # ── POST /_matrix/client/v3/logout/all ────────────────────────────────────
  #
  # story oauth-token-revocation-logout (R17): invalidates EVERY token of the user (including the
  # caller's) and deletes ALL devices of the user with their keys (Matrix spec; cross-signing keys are
  # per user and stay). Both APIs: (1) every OAuth session with its device, (2) the legacy part =
  # exactly the legacy `/logout` body, (3) every remaining device (legacy too). A failed part answers
  # `500 M_UNKNOWN` while the other parts still ran (the tokens are dead anyway; the client may retry).
  post "/client/v3/logout/all" do
    user = conn.assigns[:current_user]

    oauth_result = Nebu.Matrix.oauth_end_user_sessions(user)

    # The legacy part keeps its best-effort contract (LL11) but its failure is no longer invisible here:
    # an exception counts as a failure, and the caller's raw JWT must be denylisted DURABLY (checked).
    legacy_result =
      try do
        legacy_user_wipe(conn, user)
        checked_revoke_jwt(conn)
      rescue
        _ -> :error
      catch
        :exit, _ -> :error
      end

    # Every device AND every matrix_sessions row of the user, atomically per device (review cycle 1,
    # Kassandra F-1/F-2): a legacy session that survives is a failure, never a silent 200.
    devices_result = Nebu.Matrix.end_all_user_devices(user)

    case {oauth_result, legacy_result, devices_result} do
      {{:ok, _}, :ok, :ok} -> send_json(conn, 200, %{})
      _ -> error(conn, 500, "M_UNKNOWN", "Logout failed, please try again.")
    end
  end

  # The presented raw JWT must be on the denylist in the DATABASE (cluster wide); a failed insert is a
  # failure (500). Opaque tokens are covered by the checked matrix_sessions teardown.
  defp checked_revoke_jwt(conn) do
    token = conn.assigns[:access_token]
    claims = conn.assigns[:oidc_claims] || %{}

    with exp when is_integer(exp) <- claims["exp"],
         true <- Nebu.Web.Plugs.OidcPlug.jwt_token?(token) do
      case Nebu.Web.TokenDenylist.revoke_checked(claims["jti"], token, exp) do
        :ok -> :ok
        {:error, _} -> :error
      end
    else
      _ -> :ok
    end
  end

  # The legacy user-wide wipe, used by `/logout/all` ONLY (LL11, unchanged behaviour): revoke the presented
  # token, then end every session of the user (`device_id: ""`).
  defp legacy_user_wipe(conn, user) do
    # F-1: revoke the access token so it cannot be reused. OidcPlug returns the
    # verified OIDC token verbatim as the access_token, so destroying the session
    # GenServer alone does NOT stop the token from re-validating on the next
    # request. We add the presented token to the denylist (keyed by jti or token
    # hash) until its own `exp`, mirroring the Go gateway's logout → Invalidate
    # path. OidcPlug then rejects it with 401 M_UNKNOWN_TOKEN. Best-effort: a
    # missing token/exp just means nothing to revoke.
    revoke_access_token(conn)

    req = %Core.InvalidateUserSessionsRequest{user_id: user, device_id: ""}

    # Best-effort (mirrors Go: a cleanup failure does not block); `/logout/all` reports the other parts.
    _ =
      call_core(fn ->
        Nebu.Matrix.EventDispatcher.Server.invalidate_user_sessions(req, stream(user))
      end)

    :ok
  end

  # Legacy `POST /logout` (LL1-LL8): the presented credential's device only. Exactly one INFO line per call, a static
  # message with Logger METADATA (user, device, kind, outcome; never a token, hash or jti; Kassandra L3).
  defp legacy_device_logout(conn) do
    user = conn.assigns[:current_user]
    token = conn.assigns[:access_token]
    jwt? = Nebu.Web.Plugs.OidcPlug.jwt_token?(token)

    {kind, log_device, outcome} =
      cond do
        is_binary(token) and not jwt? ->
          device_id = conn.assigns[:device_id]
          did = if is_binary(device_id), do: device_id, else: ""
          result = Nebu.Matrix.legacy_logout_device(%{kind: :opaque, token: token, user_id: user, device_id: did})
          {"opaque", did, logout_outcome(result)}

        jwt? ->
          jwt_logout(conn, user, token)

        true ->
          {"jwt_unbound", "-", if(checked_revoke_jwt(conn) == :ok, do: "ended", else: "failed")}
      end

    Logger.info("legacy logout", user_id: user, device_id: log_device, kind: kind, outcome: outcome)

    if outcome == "failed" do
      error(conn, 500, "M_UNKNOWN", "Logout failed, please try again.")
    else
      send_json(conn, 200, %{})
    end
  end

  # A JWT with a (non-empty) device binding: teardown, then the checked denylist write. A JWT that `OidcPlug` resolved
  # as UNBOUND is re-checked with an uncached binding read: the auth-time lookup degrades to "unbound" (and used to
  # cache that) on a database error, which must not turn a bound JWT into the unbound path (Kassandra L2); a failing
  # re-read fails closed (`failed`, 500) and nothing is denylisted or deleted.
  defp jwt_logout(conn, user, token) do
    case conn.assigns[:device_id] do
      did when is_binary(did) and did != "" ->
        {"jwt_bound", did, bound_jwt_outcome(conn, user, token, did)}

      _ ->
        case Nebu.Matrix.Session.DeviceBinding.lookup_fresh(token) do
          {:ok, did, _refused?} when is_binary(did) and did != "" ->
            {"jwt_bound", did, bound_jwt_outcome(conn, user, token, did)}

          {:ok, _, _} ->
            {"jwt_unbound", "-", if(checked_revoke_jwt(conn) == :ok, do: "ended", else: "failed")}

          {:error, _} ->
            {"jwt_unbound", "-", "failed"}
        end
    end
  end

  defp bound_jwt_outcome(conn, user, token, device_id) do
    case Nebu.Matrix.legacy_logout_device(%{kind: :jwt, token: token, user_id: user, device_id: device_id}) do
      {:error, _} -> "failed"
      {:ok, ended_or_unknown} -> if checked_revoke_jwt(conn) == :ok, do: logout_outcome(ended_or_unknown), else: "failed"
    end
  end

  defp logout_outcome({:ok, :ended}), do: "ended"
  defp logout_outcome({:ok, :unknown}), do: "unknown"
  defp logout_outcome(:ended), do: "ended"
  defp logout_outcome(:unknown), do: "unknown"
  defp logout_outcome(_), do: "failed"

  defp revoke_access_token(conn) do
    token = conn.assigns[:access_token]
    claims = conn.assigns[:oidc_claims] || %{}

    cond do
      # oidc-session-refresh: an opaque Nebu session token (no JWT dots) is hard-
      # revoked by deleting its matrix_sessions row, so neither the AT nor its RT
      # can be reused after logout. JWTs have no row here and take the denylist path.
      is_binary(token) and not Nebu.Web.Plugs.OidcPlug.jwt_token?(token) ->
        _ = Nebu.Matrix.Session.MatrixSessionStore.revoke(token)
        :ok

      true ->
        revoke_jwt_access_token(token, claims)
    end
  end

  defp revoke_jwt_access_token(token, claims) do
    case claims["exp"] do
      exp when is_integer(exp) and is_binary(token) ->
        Nebu.Web.TokenDenylist.revoke(claims["jti"], token, exp)

      _ ->
        # No token/exp on the conn — unreachable post-OidcPlug: a verified token
        # cannot reach a protected route without an integer `exp` (OidcPlug
        # check_exp rejects missing/non-integer exp before assigning the token).
        # Defensive branch only; if check_exp ever loosens this would become a
        # logout-revocation gap, so the invariant lives in check_exp. Nothing to
        # revoke here → logout still returns 200.
        :ok
    end
  end

  # ── GET /_matrix/client/v3/account/whoami ─────────────────────────────────
  # Standard Matrix CS endpoint: echoes the identity behind the presented access
  # token. The token is already verified by OidcPlug (this router's pipeline), so
  # `conn.assigns[:current_user]` is the authenticated Matrix user_id — whoami simply
  # returns it. Real clients (Element) call this on startup, and the E2E harness uses
  # it to validate a warmed session before seeding rooms. `device_id` is optional per
  # spec and omitted (Nebu's OIDC access token is not per-device). `is_guest` is always
  # false — Nebu has no guest access.
  get "/client/v3/account/whoami" do
    base = %{"user_id" => conn.assigns[:current_user], "is_guest" => false}

    # device_id is Required when a device is bound to the token (spec §whoami), which
    # is the case for opaque Nebu sessions (OidcPlug assigns it). Raw OIDC JWTs are not
    # per-device, so the field is correctly omitted there.
    body =
      case conn.assigns[:device_id] do
        did when is_binary(did) and did != "" -> Map.put(base, "device_id", did)
        _ -> base
      end

    send_json(conn, 200, body)
  end

  # ── Client startup endpoints (Element compatibility) ───────────────────────
  # A full Matrix client (Element Web) fetches these on startup and BLOCKS on the
  # loading spinner — never reaching /sync — until they answer. Nebu's MVP did not
  # implement them, so Element hung. Return spec-valid minimal responses.

  # GET /thirdparty/protocols — no third-party protocols supported; return empty object.
  # Element retries on 404; 200 {} stops the retry loop. (Matrix CS §thirdparty)
  get "/client/v3/thirdparty/protocols" do
    send_json(conn, 200, %{})
  end

  # GET /voip/turnServer — no TURN server configured (optional feature).
  # Element tolerates 404 M_NOT_FOUND here.
  get "/client/v3/voip/turnServer" do
    error(conn, 404, "M_NOT_FOUND", "No TURN server configured")
  end

  # GET /room_keys/version — no key backup configured. 404 M_NOT_FOUND is the
  # spec-defined response (Matrix CS §Server-side key backups).
  get "/client/v3/room_keys/version" do
    error(conn, 404, "M_NOT_FOUND", "No backup found")
  end

  # POST /room_keys/version — key backup creation ACCEPTANCE STUB (story room-keys-version-post-stub).
  # Element Web creates a key backup right after the cross-signing bootstrap of a user's first login;
  # without a 2xx it shows "Unable to set up keys". The Go gateway had exactly this stub (dropped by the
  # Elixir migration). Nebu has no server-side key backup (ADR-011: no E2EE rooms, nothing to back up):
  # the body is ignored, NOTHING is stored (no DB access), the GET above keeps answering "no backup".
  # Every other room_keys/* route stays M_UNRECOGNIZED.
  post "/client/v3/room_keys/version" do
    send_json(conn, 200, %{"version" => "1"})
  end

  # GET MSC3814 dehydrated_device — not in CS API v1.18; unstable proposal only.
  # Return 404 M_NOT_FOUND — Element accepts this.
  get "/client/unstable/org.matrix.msc3814.v1/dehydrated_device" do
    error(conn, 404, "M_NOT_FOUND", "No dehydrated device found")
  end

  # GET MSC4143 rtc/transports — not in CS API v1.18; unstable proposal only.
  # Return 404 M_NOT_FOUND — Element accepts this.
  get "/client/unstable/org.matrix.msc4143/rtc/transports" do
    error(conn, 404, "M_NOT_FOUND", "No RTC transports")
  end

  # POST /keys/device_signing/upload — cross-signing key upload (Matrix CS §Cross-signing).
  # Persists the supplied master/self/user signing keys (opaque objects) in the
  # cross-signing directory so /keys/query reads them back and Element's cross-signing
  # bootstrap completes. This is the key DIRECTORY only — it does NOT enable E2EE
  # (ADR-011): the server never decrypts and never gains a private part.
  post "/client/v3/keys/device_signing/upload" do
    do_device_signing_upload(conn)
  end

  # GET /capabilities — advertise supported room versions + which actions are allowed.
  get "/client/v3/capabilities" do
    send_json(conn, 200, %{
      "capabilities" => %{
        # Story create-room-input-validation (D1): exactly the room versions createRoom / upgrade accept
        # (Nebu.Matrix.RoomVersions), so the capability never promises a version that answers
        # M_UNSUPPORTED_ROOM_VERSION. `default` MUST be one of `available`.
        "m.room_versions" => Nebu.Matrix.RoomVersions.capability(),
        "m.change_password" => %{"enabled" => false},
        "m.set_displayname" => %{"enabled" => true},
        "m.set_avatar_url" => %{"enabled" => true},
        "m.3pid_changes" => %{"enabled" => false}
      }
    })
  end

  # GET /pushrules/ — the user's push rules. Nebu has no server-side push processing
  # yet; return the empty-but-valid global ruleset so the client initialises. (Element
  # retries this endpoint on 404 and never proceeds, so a valid 200 is required.)
  @empty_pushrules %{
    "global" => %{
      "content" => [],
      "override" => [],
      "room" => [],
      "sender" => [],
      "underride" => []
    }
  }
  # Plug.Router normalises the trailing slash, so this single clause serves both
  # /pushrules and /pushrules/.
  get "/client/v3/pushrules/" do
    send_json(conn, 200, @empty_pushrules)
  end

  # POST /keys/query — device-key + cross-signing lookup (Matrix CS §/keys/query).
  # Echoes back the device_keys objects published via /keys/upload AND the
  # cross-signing keys published via /keys/device_signing/upload, so a client (incl.
  # Element querying its OWN user) sees its device registered and its cross-signing
  # state set up. Users without cross-signing keys get empty maps. This is the key
  # DIRECTORY only — it does not enable E2EE (ADR-011).
  post "/client/v3/keys/query" do
    requested = body_params(conn)["device_keys"]

    {device_keys, cross_signing} =
      if is_map(requested) and map_size(requested) > 0 do
        {query_device_keys(requested),
         CrossSigningKeyStore.query_cross_signing(Map.keys(requested))}
      else
        {%{}, %{}}
      end

    master_keys = collect_cross_signing(cross_signing, "master")
    self_signing_keys = collect_cross_signing(cross_signing, "self_signing")
    user_signing_keys = collect_cross_signing(cross_signing, "user_signing")

    send_json(conn, 200, %{
      "device_keys" => device_keys,
      "master_keys" => master_keys,
      "self_signing_keys" => self_signing_keys,
      "user_signing_keys" => user_signing_keys,
      "failures" => %{}
    })
  end

  # POST /keys/signatures/upload — merge cross-signing / device signatures (Matrix CS
  # §/keys/signatures/upload). Each (user_id, key_id, signedObject) carries new signatures
  # to merge into the stored key object (a device key or a cross-signing key). On a match
  # the new signatures are merged and persisted; on a mismatch (the non-signatures parts
  # differ, or no stored key) a per-(user,key) M_INVALID_SIGNATURE goes into `failures`.
  # Always 200 with {"failures": …}. Directory only — does not enable E2EE (ADR-011).
  post "/client/v3/keys/signatures/upload" do
    do_signatures_upload(conn)
  end

  # POST /keys/upload — publish device identity keys, one-time keys, and fallback keys
  # (Matrix CS §/keys/upload). Persists them in the device-key directory and returns the
  # real unclaimed one_time_key_counts.
  #
  # S2 AC4/AC6/G1: the device a write attributes to is determined SOLELY by the token's
  # server-side binding (`conn.assigns[:device_id]`, set by OidcPlug for BOTH opaque and
  # raw-JWT sessions). A body `device_keys.device_id` that CONTRADICTS the bound device is
  # rejected UP FRONT — before any write — so a token bound to DEV_A can never publish keys
  # for DEV_B (the spec: device_keys device_id "Must match the device ID used when logging
  # in"). With no bound device and no body device_id there is nothing to attribute → no-op,
  # empty counts, no DB touch.
  post "/client/v3/keys/upload" do
    user = conn.assigns[:current_user]
    params = body_params(conn)
    device_keys = params["device_keys"]
    one_time_keys = params["one_time_keys"]
    fallback_keys = params["fallback_keys"]

    bound_device = conn.assigns[:device_id]
    body_device = if is_map(device_keys), do: device_keys["device_id"]

    cond do
      # Bound the per-request write amplification (keys/upload is unauthenticated-rate-
      # limited only by the global body cap). A well-behaved client uploads ≤50 keys and
      # stops once /sync reports the target count is reached; the cap stops a malicious
      # client from packing one body with a huge key set. 100 comfortably exceeds Element.
      oversized?(one_time_keys) or oversized?(fallback_keys) ->
        error(conn, 400, "M_INVALID_PARAM", "Too many keys in a single upload")

      # S3 F-2: a body device_keys.device_id that is oversized (>255 bytes) or carries
      # control chars is rejected at ingress, before any store touch.
      is_binary(body_device) and body_device != "" and not Nebu.Matrix.DeviceId.valid?(body_device) ->
        error(conn, 400, "M_INVALID_PARAM", "Invalid device_id")

      # SECURITY G1: a body device_id that names a DIFFERENT device than the token is bound
      # to is a cross-device-transfer attempt → reject before any write touches the store.
      is_binary(bound_device) and bound_device != "" and
        is_binary(body_device) and body_device != "" and body_device != bound_device ->
        error(conn, 403, "M_FORBIDDEN", "device_keys device_id does not match the authenticated device")

      true ->
        case upload_device_id(device_keys, conn) do
          nil ->
            send_json(conn, 200, %{"one_time_key_counts" => %{}})

          device_id ->
            # A raw-JWT session minted before its device binding existed (e.g. a JWT that
            # did not run through the S2 login binding) establishes its binding the first
            # time it names a device by publishing that device's keys. This is secure: a
            # token can only ever bind to the device it ITSELF publishes keys for, the
            # device a request acts as is still never another device's (G1's up-front
            # mismatch check fires once a binding exists), and it lets a later OTK-only
            # top-up on the SAME token resolve the device without the removed
            # sole_device_id heuristic.
            #
            # story oauth-legacy-coexistence (C11, Trap 4): the bind runs FIRST and is CHECKED. A raw IdP
            # JWT may never bind to — and so never write the keys of — a device that has an OAuth session
            # (T25 b refused the binding silently, but the keys were still written): 403 with the G1 text,
            # no key write.
            case maybe_bind_jwt_device(conn, user, device_id) do
              {:error, :oauth_device} ->
                error(conn, 403, "M_FORBIDDEN", "device_keys device_id does not match the authenticated device")

              :ok ->
                if is_map(device_keys), do: DeviceKeyStore.put_device_keys(user, device_id, device_keys)
                if is_map(one_time_keys), do: DeviceKeyStore.store_one_time_keys(user, device_id, one_time_keys)
                if is_map(fallback_keys), do: DeviceKeyStore.store_fallback_keys(user, device_id, fallback_keys)

                send_json(conn, 200, %{"one_time_key_counts" => DeviceKeyStore.otk_counts(user, device_id)})
            end
        end
    end
  end

  # GET /devices — the user's registered devices (Matrix CS §/devices). Sourced from the
  # `devices` table (S1 device-registry-model), so it lists ALL of the user's devices,
  # including keyless ones that have not published any crypto keys.
  get "/client/v3/devices" do
    send_json(conn, 200, %{"devices" => DeviceKeyStore.list_devices(conn.assigns[:current_user])})
  end

  # GET /devices/{deviceId} — a single device, or 404 if unknown.
  get "/client/v3/devices/:device_id" do
    case DeviceKeyStore.get_device(conn.assigns[:current_user], URI.decode_www_form(device_id)) do
      nil -> error(conn, 404, "M_NOT_FOUND", "Unknown device")
      device -> send_json(conn, 200, device)
    end
  end

  # PUT /devices/{deviceId} — rename (S3 AC2). Owner-scoped, NOT UIA-gated. A rename
  # of an unknown / another user's device affects 0 rows → 404 M_NOT_FOUND (no IDOR,
  # no existence oracle). Success → 200 {}.
  put "/client/v3/devices/:device_id" do
    user = conn.assigns[:current_user]
    did = URI.decode_www_form(device_id)
    display_name = body_params(conn)["display_name"]

    if DeviceKeyStore.rename_device(user, did, display_name) == :ok do
      send_json(conn, 200, %{})
    else
      error(conn, 404, "M_NOT_FOUND", "Unknown device")
    end
  end

  # DELETE /devices/{deviceId} — delete (S3 AC3), UIA-gated (Option B). On success:
  # full per-device teardown (key material, opaque session, bound-JWT kill-switch).
  # Idempotent (deleting an absent device → 200 {}); another user's device → 404.
  #
  # story oauth-legacy-coexistence (C7/C8): an OAuth-session caller is refused FIRST — before the IDOR
  # guard (no existence oracle), before any UIA session is minted: "the User-Interactive Authentication
  # API is not compatible with the OAuth 2.0 API" (Matrix v1.18); device deletion for OAuth sessions is
  # the account management page. Decided by the `:auth_api` assign set at AUTHENTICATION time by
  # `OidcPlug` (never by a lookup here); an expired/superseded OAuth token never reaches this handler
  # (401 + soft_logout). Matrix v1.17 exempts application-service callers from UIA on device deletion;
  # Nebu has no appservice API (epic 10), so there is no exception to make.
  delete "/client/v3/devices/:device_id" do
    if conn.assigns[:auth_api] == "oauth" do
      refuse_oauth_device_deletion(conn)
    else
      user = conn.assigns[:current_user]
      did = URI.decode_www_form(device_id)

      # IDOR guard (S3 G3): a device_id owned by ANOTHER user → 404, BEFORE any UIA
      # challenge (no existence oracle, no cross-user delete). An absent-for-everyone
      # device falls through to an idempotent 200 no-op.
      if DeviceKeyStore.belongs_to_other_user?(user, did) do
        error(conn, 404, "M_NOT_FOUND", "Unknown device")
      else
        uia_gate(conn, "delete_devices", [did], fn conn, via_auth ->
          # If satisfied by the recent-login window (via_auth=false), the presented
          # token bound to this device must stop authenticating (AC3 → revoke it). If
          # the user just completed a fresh m.login.sso re-auth (via_auth=true), the
          # request token is preserved (they re-proved themselves this request) so it
          # can finish the request — for BOTH opaque sessions AND raw JWTs.
          preserve = if via_auth, do: caller_credential(conn), else: nil

          case delete_one_device(user, did, preserve) do
            :ok -> send_json(conn, 200, %{})
            {:error, _} -> error(conn, 500, "M_UNKNOWN", "Device deletion failed, please try again.")
          end
        end)
      end
    end
  end

  # POST /delete_devices — bulk delete (S3 AC4). Same UIA gate as DELETE, challenged
  # once for the whole batch. The "devices" key is required (missing → 400). Each id
  # is scoped to the caller: a foreign device_id in the array is silently skipped (no
  # cross-user delete — G3). Empty array → 200 {} no-op (still gated, but a fresh
  # session satisfies it). Idempotent → 200 {}.
  #
  # story oauth-legacy-coexistence (C7): OAuth-session callers are refused FIRST (before the body
  # validation and the UIA gate), exactly like DELETE /devices/{deviceId}, also for an empty or
  # non-JSON body; see there for the rationale (and the appservice note).
  post "/client/v3/delete_devices" do
    if conn.assigns[:auth_api] == "oauth" do
      refuse_oauth_device_deletion(conn)
    else
      user = conn.assigns[:current_user]
      params = body_params(conn)
      devices = params["devices"]

      cond do
        not Map.has_key?(params, "devices") ->
          error(conn, 400, "M_MISSING_PARAM", "devices is required")

        not is_list(devices) ->
          error(conn, 400, "M_INVALID_PARAM", "devices must be an array")

        # Bound the work + canonicalisation: a single request must not enumerate/delete an
        # unbounded device set. Cap at <=100 device_ids; reject larger with 400. The cap is
        # checked on the raw array length BEFORE filtering so a padded array cannot smuggle
        # more than 100 real ids through.
        length(devices) > 100 ->
          error(conn, 400, "M_INVALID_PARAM", "devices must contain at most 100 entries")

        true ->
          # Filter to binaries and dedupe so the UIA params canonicalisation and the
          # per-device loop are stable (a repeated id is processed once).
          ids = devices |> Enum.filter(&is_binary/1) |> Enum.uniq()

          uia_gate(conn, "delete_devices", ids, fn conn, _via_auth ->
            # Scope to the caller: only delete device_ids actually owned by this user.
            # Preserve the credential MAKING this batch request (its device may be in the
            # list) so the caller can finish the batch and keep managing devices after a
            # bulk delete — all OTHER targeted sessions are still revoked. The preserve is
            # symmetric: for an opaque caller it spares the matrix_sessions row, and for a
            # raw-JWT caller it spares the kill-switch denylist of THIS token's hash.
            preserve = caller_credential(conn)

            # Every id is attempted (a failing one stays intact, the others are still deleted); any
            # failure answers 500 (story oauth-legacy-coexistence C12).
            results =
              for id <- ids, not DeviceKeyStore.belongs_to_other_user?(user, id) do
                delete_one_device(user, id, preserve)
              end

            if Enum.all?(results, &(&1 == :ok)),
              do: send_json(conn, 200, %{}),
              else: error(conn, 500, "M_UNKNOWN", "Device deletion failed, please try again.")
          end)
      end
    end
  end

  # C7 / C8: the same answer for an own, a foreign and an unknown device id and for any body, and
  # nothing is looked up, minted or deleted. 403 M_FORBIDDEN (not 401 + UIA flows, not
  # M_UNRECOGNIZED): the endpoint exists and works for legacy sessions on this server.
  defp refuse_oauth_device_deletion(conn) do
    error(
      conn,
      403,
      "M_FORBIDDEN",
      "Device deletion is not available for OAuth sessions; use the account management page."
    )
  end

  # POST /user/{userId}/filter — a client uploads a sync filter and gets an id back BEFORE
  # its first /sync (Element blocks here). Nebu's /sync ignores filters, so accept any
  # filter and return a constant id; GET returns it back. (Server-side filtering is not
  # implemented — /sync returns the full delta regardless, which is spec-permissible.)
  post "/client/v3/user/:_user_id/filter" do
    send_json(conn, 200, %{"filter_id" => "0"})
  end

  get "/client/v3/user/:_user_id/filter/:_filter_id" do
    send_json(conn, 200, %{})
  end

  # GET/PUT /user/{userId}/account_data/{type} — DURABLE per-user global account data
  # (PostgreSQL, story account-data-durability). PUT stores the opaque JSON body; GET
  # reads it back; both survive a restart and are delivered via /sync. The user==auth
  # guard rejects cross-user access (403 M_FORBIDDEN); absent GET → 404 M_NOT_FOUND.
  # ADR-011: content is opaque (client-encrypted secret-storage / cross-signing keys);
  # the server never parses or decrypts it. Storing it enables NO encryption.
  put "/client/v3/user/:user_id/account_data/:type" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @account_data_write_rate_limit)

    if conn.halted do
      conn
    else
      do_put_global_account_data(conn, user_id, type)
    end
  end

  # `user_id` / `type` are used as Plug.Router already percent-decoded them (path params);
  # NO extra `URI.decode_www_form` (it would turn a literal `+` into a space and make the
  # global scope store `a+b` under a different key than the room scope).
  defp do_put_global_account_data(conn, user_id, type) do
    authenticated_user = conn.assigns[:current_user]

    cond do
      user_id != authenticated_user ->
        error(conn, 403, "M_FORBIDDEN", "You can only write your own account data")

      # Matrix CS (Client Config): servers MUST reject setting m.fully_read / m.push_rules
      # (server managed; global AND room scope). Reads stay allowed.
      type in @server_managed_account_data_types ->
        error(conn, 405, "M_BAD_JSON", "Cannot set account data of server-managed type #{type}")

      # Body > 1 MB: JsonBody replaced body_params with %{} — storing that would silently
      # overwrite the user's (secret-storage / cross-signing) value, so refuse BEFORE storing.
      conn.assigns[:body_too_large] == true ->
        error(conn, 413, "M_TOO_LARGE", "Account data content too large")

      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      true ->
        # Same discipline as the room scope: the RAW body decides. Empty / non-JSON /
        # no Content-Type (parser skipped) → 400 M_NOT_JSON (Synapse parity: clients
        # without a JSON Content-Type are rejected), non-object → 400 M_BAD_JSON, and an
        # oversized body (any Content-Type) → 413. The stored value is never silently
        # replaced by `{}`.
        put_global_account_data_body(conn, user_id, type)
    end
  end

  @global_account_data_max_bytes 1_000_000

  # story gdpr-erasure-global-data (D18 (c)): the answer to a write of a user whose erasure is under way or done: the same permanent
  # refusal as the deactivated-account answer of `/login` (the token of such a user dies with the teardown).
  defp user_erased(conn), do: error(conn, 403, "M_USER_DEACTIVATED", "This account has been deactivated")

  # The kind of a write error for the log: an exception's module or an atom, never its message (a Postgrex error can quote
  # row values).
  defp error_kind(%{__struct__: module}), do: inspect(module)
  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(_), do: "error"

  defp put_global_account_data_body(conn, user_id, type) do
    case conn.assigns[:raw_body] do
      raw when is_binary(raw) ->
        cond do
          byte_size(raw) > @global_account_data_max_bytes ->
            error(conn, 413, "M_TOO_LARGE", "Account data content too large")

          raw == "" or not valid_json?(raw) ->
            error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

          not json_object?(raw) ->
            error(conn, 400, "M_BAD_JSON", "Request body must be a JSON object")

          true ->
            case Nebu.Matrix.AccountDataStore.put(user_id, type, Jason.encode!(body_params(conn))) do
              :ok ->
                send_json(conn, 200, %{})

              {:error, :user_erased} ->
                # story gdpr-erasure-global-data (D10 / D18 (c)): a permanent condition, not a retryable 500
                Logger.info("global account data write refused: user_erased")
                user_erased(conn)

              {:error, reason} ->
                # never the content or the reason's details (opaque, often client-encrypted secret storage): its kind only
                Logger.error("global account data write failed: #{error_kind(reason)}")
                error(conn, 500, "M_UNKNOWN", "Account data could not be stored, please try again.")
            end
        end

      _ ->
        # Parser skipped (no / non-JSON Content-Type): size-check, then refuse.
        if byte_size(raw_request_body(conn, @global_account_data_max_bytes)) > @global_account_data_max_bytes do
          error(conn, 413, "M_TOO_LARGE", "Account data content too large")
        else
          error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON (Content-Type: application/json required)")
        end
    end
  end

  # ── Room-scoped account data (story room-account-data-and-read-markers) ───────
  # PUT/GET /user/{userId}/rooms/{roomId}/account_data/{type}. Durable PostgreSQL store
  # (Nebu.Matrix.RoomAccountDataStore), content VERBATIM (ADR-011), delivered in
  # /sync rooms.join.<roomId>.account_data.events. Check order (all BEFORE any room /
  # membership lookup, so they cannot leak room existence): user==auth (403), server-
  # managed type (405 M_BAD_JSON), roomId syntax (400 M_INVALID_PARAM), body size (413),
  # body JSON object (400 M_NOT_JSON). Then membership: a non-member and an unknown room
  # get the SAME 403 M_FORBIDDEN (Matrix does not require membership for account data,
  # but an unrestricted write would let anyone probe room ids and fill storage).
  put "/client/v3/user/:user_id/rooms/:room_id/account_data/:type" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @account_data_write_rate_limit)

    if conn.halted do
      conn
    else
      do_put_room_account_data(conn, user_id, room_id, type)
    end
  end

  defp do_put_room_account_data(conn, user_id, room_id, type) do
    authenticated_user = conn.assigns[:current_user]

    cond do
      user_id != authenticated_user ->
        error(conn, 403, "M_FORBIDDEN", "You can only write your own account data")

      type in @server_managed_account_data_types ->
        error(conn, 405, "M_BAD_JSON", "Cannot set account data of server-managed type #{type}")

      not valid_room_id?(room_id) ->
        error(conn, 400, "M_INVALID_PARAM", "Invalid room id")

      type == "" or byte_size(type) > 255 ->
        error(conn, 400, "M_INVALID_PARAM", "Invalid account data type")

      conn.assigns[:body_too_large] == true ->
        error(conn, 413, "M_TOO_LARGE", "Account data content too large")

      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      true ->
        raw = raw_request_body(conn)

        cond do
          byte_size(raw) > Nebu.Matrix.RoomAccountDataStore.max_bytes() ->
            error(conn, 413, "M_TOO_LARGE", "Account data content too large")

          not json_object?(raw) ->
            error(conn, 400, "M_NOT_JSON", "Request body must be a JSON object")

          true ->
            with :ok <- require_room_member(authenticated_user, room_id),
                 :ok <- Nebu.Matrix.RoomAccountDataStore.put(authenticated_user, room_id, type, raw) do
              send_json(conn, 200, %{})
            else
              {:error, :limit_exceeded} ->
                error(conn, 403, "M_RESOURCE_LIMIT_EXCEEDED", "Room account data limit exceeded")

              {:error, {status, errcode, message}} ->
                error(conn, status, errcode, message)

              {:error, _db} ->
                error(conn, 500, "M_UNKNOWN", "Internal server error")
            end
        end
    end
  end

  get "/client/v3/user/:user_id/rooms/:room_id/account_data/:type" do
    authenticated_user = conn.assigns[:current_user]

    cond do
      user_id != authenticated_user ->
        error(conn, 403, "M_FORBIDDEN", "You can only read your own account data")

      not valid_room_id?(room_id) ->
        error(conn, 400, "M_INVALID_PARAM", "Invalid room id")

      true ->
        with :ok <- require_room_member(authenticated_user, room_id),
             {:ok, json_body} <- Nebu.Matrix.RoomAccountDataStore.get(authenticated_user, room_id, type) do
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, json_body)
        else
          :error -> error(conn, 404, "M_NOT_FOUND", "Account data not found")
          {:error, {status, errcode, message}} -> error(conn, status, errcode, message)
        end
    end
  end

  # ── Room tags (story room-tags) ─────────────────────────────────────────────
  # GET    /user/{userId}/rooms/{roomId}/tags
  # PUT    /user/{userId}/rooms/{roomId}/tags/{tag}     body = tag object, e.g. {"order": 0.25}
  # DELETE /user/{userId}/rooms/{roomId}/tags/{tag}
  # Tags live in the room account data event `m.tag` ({"tags": {name => tag object}}) of
  # Nebu.Matrix.RoomAccountDataStore; PUT/DELETE are an atomic read-modify-write of that event
  # (RoomAccountDataStore.update/4: one transaction under the per-user advisory lock) so
  # concurrent tag writes never lose each other. Check order = room account data PUT:
  # user==auth (403), roomId syntax (400 M_INVALID_PARAM), tag name (400 M_INVALID_PARAM),
  # body size (413), body JSON object (400 M_NOT_JSON), `order` a JSON number (400 M_BAD_JSON),
  # then membership (identical 403 for non-member and unknown room). Writes share the
  # `account_data` rate-limit bucket (GET is not limited). The tag name is user content: it is
  # never echoed in an error message. PUT/DELETE without a name (`.../tags`, `.../tags/`) → 400.
  get "/client/v3/user/:user_id/rooms/:room_id/tags" do
    authenticated_user = conn.assigns[:current_user]

    cond do
      user_id != authenticated_user ->
        error(conn, 403, "M_FORBIDDEN", "You can only read your own tags")

      not valid_room_id?(room_id) ->
        error(conn, 400, "M_INVALID_PARAM", "Invalid room id")

      true ->
        with :ok <- require_room_member(authenticated_user, room_id) do
          tags =
            case Nebu.Matrix.RoomAccountDataStore.get(authenticated_user, room_id, "m.tag") do
              {:ok, json} -> json |> decode_tag_event() |> tags_of_event()
              :error -> %{}
            end

          send_json(conn, 200, %{"tags" => tags})
        else
          {:error, {status, errcode, message}} -> error(conn, status, errcode, message)
        end
    end
  end

  put "/client/v3/user/:user_id/rooms/:room_id/tags" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @account_data_write_rate_limit)
    if conn.halted, do: conn, else: do_room_tag_write(conn, user_id, room_id, "", :put)
  end

  delete "/client/v3/user/:user_id/rooms/:room_id/tags" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @account_data_write_rate_limit)
    if conn.halted, do: conn, else: do_room_tag_write(conn, user_id, room_id, "", :delete)
  end

  put "/client/v3/user/:user_id/rooms/:room_id/tags/:tag" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @account_data_write_rate_limit)
    if conn.halted, do: conn, else: do_room_tag_write(conn, user_id, room_id, tag, :put)
  end

  delete "/client/v3/user/:user_id/rooms/:room_id/tags/:tag" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @account_data_write_rate_limit)
    if conn.halted, do: conn, else: do_room_tag_write(conn, user_id, room_id, tag, :delete)
  end

  defp do_room_tag_write(conn, user_id, room_id, tag, method) do
    authenticated_user = conn.assigns[:current_user]

    cond do
      user_id != authenticated_user ->
        error(conn, 403, "M_FORBIDDEN", "You can only change your own tags")

      not valid_room_id?(room_id) ->
        error(conn, 400, "M_INVALID_PARAM", "Invalid room id")

      not valid_tag_name?(tag) ->
        error(conn, 400, "M_INVALID_PARAM", "Invalid tag name")

      method == :delete ->
        write_room_tag(conn, authenticated_user, room_id, &remove_tag(&1, tag))

      conn.assigns[:body_too_large] == true ->
        error(conn, 413, "M_TOO_LARGE", "Tag content too large")

      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      true ->
        put_room_tag_body(conn, authenticated_user, room_id, tag)
    end
  end

  # The RAW body decides (RawBodyReader keeps it for JSON content types). A body the JSON parser
  # skipped (no / non-JSON Content-Type) is size-checked, then refused (400 M_NOT_JSON), like the
  # global account-data scope: a tag is never stored from a body that was not sent as JSON.
  defp put_room_tag_body(conn, user, room_id, tag) do
    max = Nebu.Matrix.RoomAccountDataStore.max_bytes()

    case conn.assigns[:raw_body] do
      raw when is_binary(raw) ->
        cond do
          byte_size(raw) > max ->
            error(conn, 413, "M_TOO_LARGE", "Tag content too large")

          not json_object?(raw) ->
            error(conn, 400, "M_NOT_JSON", "Request body must be a JSON object")

          true ->
            {:ok, tag_object} = Jason.decode(raw)

            if Map.has_key?(tag_object, "order") and not is_number(tag_object["order"]) do
              error(conn, 400, "M_BAD_JSON", "Tag order must be a number")
            else
              write_room_tag(conn, user, room_id, &put_tag(&1, tag, tag_object))
            end
        end

      _ ->
        if byte_size(raw_request_body(conn)) > max,
          do: error(conn, 413, "M_TOO_LARGE", "Tag content too large"),
          else: error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON (Content-Type: application/json required)")
    end
  end

  defp write_room_tag(conn, user, room_id, fun) do
    with :ok <- require_room_member(user, room_id),
         :ok <- Nebu.Matrix.RoomAccountDataStore.update(user, room_id, "m.tag", fun) do
      send_json(conn, 200, %{})
    else
      {:error, :limit_exceeded} ->
        error(conn, 403, "M_RESOURCE_LIMIT_EXCEEDED", "Room account data limit exceeded")

      {:error, :too_large} ->
        error(conn, 413, "M_TOO_LARGE", "Tag content too large")

      {:error, {status, errcode, message}} ->
        error(conn, status, errcode, message)

      {:error, _db} ->
        error(conn, 500, "M_UNKNOWN", "Internal server error")
    end
  end

  # Tag name: 1..255 BYTES after URL-decoding (Matrix CS), valid UTF-8, no NUL (Nebu decision).
  defp valid_tag_name?(tag),
    do: tag != "" and byte_size(tag) <= 255 and String.valid?(tag) and not String.contains?(tag, <<0>>)

  # Pure merge functions run inside RoomAccountDataStore.update/4 (transaction + advisory
  # lock). A malformed stored event is treated as {} (`tags` missing / not an object → %{});
  # unknown top-level keys are preserved.
  defp put_tag(current_json, tag, tag_object) do
    event = decode_tag_event(current_json)
    tags = Map.put(tags_of_event(event), tag, tag_object)
    {:ok, Jason.encode!(Map.put(event, "tags", tags))}
  end

  defp remove_tag(nil, _tag), do: :unchanged

  defp remove_tag(current_json, tag) do
    event = decode_tag_event(current_json)
    tags = tags_of_event(event)

    if Map.has_key?(tags, tag),
      do: {:ok, Jason.encode!(Map.put(event, "tags", Map.delete(tags, tag)))},
      else: :unchanged
  end

  defp decode_tag_event(nil), do: %{}

  defp decode_tag_event(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp tags_of_event(%{"tags" => tags}) when is_map(tags), do: tags
  defp tags_of_event(_event), do: %{}

  get "/client/v3/user/:user_id/account_data/:type" do
    authenticated_user = conn.assigns[:current_user]

    if user_id != authenticated_user do
      error(conn, 403, "M_FORBIDDEN", "You can only read your own account data")
    else
      case Nebu.Matrix.AccountDataStore.get(user_id, type) do
        {:ok, json_body} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, json_body)

        :error ->
          error(conn, 404, "M_NOT_FOUND", "Account data not found")
      end
    end
  end

  # ── POST /_matrix/client/v3/createRoom ────────────────────────────────────
  post "/client/v3/createRoom" do
    user = conn.assigns[:current_user]
    params = body_params(conn)

    # story rate-limits-join-invite-create-room (D2): the per-user charge comes FIRST, before any body check or DB read: one
    # all-or-nothing take over the create_room bucket and (with invitees) one invite unit per distinct invitee
    with_membership_charge(conn, create_room_charge(user, params), fn -> create_room_request(conn, user, params) end)
  end

  # The createRoom handler proper (everything after the rate-limit charge).
  defp create_room_request(conn, user, params) do
    # raw, any JSON type: the core validates it (non-string / NUL -> 400 M_BAD_JSON, > 255 code points -> 400
    # M_INVALID_PARAM) before a room exists (story create-room-input-validation, D5b/c, D7)
    name = params["name"]

    # Matrix Spaces (spaces-elixir s1): creation_content is merged into the
    # m.room.create event content (Matrix CS §createRoom). We carry the raw object
    # as JSON so create_room can merge extra keys, and lift creation_content.type
    # into room_type for the denormalised rooms.room_type column. A Space is a room
    # with creation_content.type == "m.space" (MSC1772).
    creation_content = params["creation_content"]

    {room_type, creation_content_json} =
      case creation_content do
        m when is_map(m) ->
          type = m["type"]
          {if(is_binary(type), do: type, else: ""), Jason.encode!(m)}

        _ ->
          {"", ""}
      end

    # Matrix CS §createRoom `initial_state`: an array of
    # { "type", "state_key", "content" } objects applied as creator-authored
    # state events on the new room (e.g. m.space.parent linking a child room
    # back to its Space, restricted m.room.join_rules). Carried as JSON so
    # create_room can replay each entry through the signed, persisted state-event
    # path. Story create-room-initial-state-conformance: the structure is validated
    # BEFORE the room exists (a bad request creates nothing): 400 M_BAD_JSON for a
    # non-array / non-object entry / missing type / non-string state_key / missing
    # content, 400 M_INVALID_PARAM above 64 entries (createRoom is charged against the
    # per-user `create_room` tier since story rate-limits-join-invite-create-room; the cap bounds the per-request
    # sign+insert+pg-fanout cost; Element sends ~5).
    initial_state = params["initial_state"]
    validation = Nebu.Matrix.EventDispatcher.Server.validate_initial_state(initial_state)

    cond do
      # story event-size-limit (D2 (d)): the authenticated creator is the `sender` of every event of the new room; a user id
      # above 255 bytes (a session of before the user ids were bounded at their source) is a 403, nothing is created
      Nebu.Matrix.EventSize.check_keys("", nil, user) != :ok ->
        key_error(conn, :sender_too_long)

      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      # valid JSON that is not an object (Plug.Parsers wraps it as %{"_json" => value})
      Map.has_key?(params, "_json") ->
        error(conn, 400, "M_BAD_JSON", "Request body must be a JSON object")

      # story create-room-presets-power-levels-topic (D5 / D11): in Core.CreateRoomRequest an absent topic and a JSON
      # null are both nil, so the router (the only place that still sees the key) refuses a PRESENT null. Unlike `name`
      # (null = absent, previous story) the spec says a `topic` that is included overwrites the initial_state topic.
      Map.has_key?(params, "topic") and is_nil(params["topic"]) ->
        error(conn, 400, "M_BAD_JSON", "topic must be a string")

      # story create-room-invites-direct (D7): `is_direct` is a boolean; a PRESENT value of any other type (null is the same
      # as absent) is refused here, the only place that still sees the raw value (Core.CreateRoomRequest.is_direct stays a
      # boolean)
      not is_nil(params["is_direct"]) and not is_boolean(params["is_direct"]) ->
        error(conn, 400, "M_BAD_JSON", "is_direct must be a boolean")

      validation == {:error, :too_many} ->
        error(conn, 400, "M_INVALID_PARAM", "initial_state must not exceed 64 events")

      validation == {:error, :malformed} ->
        error(
          conn,
          400,
          "M_BAD_JSON",
          "initial_state must be an array of state events with a string type, an optional string state_key and an object content"
        )

      true ->
        initial_state_json =
          case initial_state do
            list when is_list(list) and list != [] -> Jason.encode!(list)
            _ -> ""
          end

        req = %Core.CreateRoomRequest{
          creator_id: user,
          name: name,
          is_direct: params["is_direct"] == true,
          room_type: room_type,
          creation_content_json: creation_content_json,
          initial_state_json: initial_state_json,
          # raw client values (any JSON type): Server.validate_create_room_request/1 tells a wrong type
          # (M_BAD_JSON) from a wrong value (story create-room-input-validation, D7)
          room_version: params["room_version"],
          room_alias_name: params["room_alias_name"],
          # story create-room-presets-power-levels-topic (D11): raw client values of any JSON type as well; the core
          # validates them (wrong type M_BAD_JSON, wrong value M_INVALID_PARAM, lock-out M_INVALID_ROOM_STATE)
          # before a room exists. A present topic: null was refused above.
          topic: params["topic"],
          preset: params["preset"],
          visibility: params["visibility"],
          power_level_content_override: params["power_level_content_override"],
          # story create-room-invites-direct (D14): raw client values as well; the core validates the lists (shape, cap,
          # eligibility) before a room exists and invites through the same path as POST /rooms/{roomId}/invite
          invite: params["invite"],
          invite_3pid: params["invite_3pid"]
        }

        case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.create_room(req, stream(user)) end) do
          {:ok, resp} -> send_json(conn, 200, %{"room_id" => resp.room_id})
          {:error, err} -> send_error(conn, err)
        end
    end
  end

  # ── POST /_matrix/client/v3/join/{roomIdOrAlias} ──────────────────────────
  post "/client/v3/join/:room_id_or_alias" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id_or_alias)

    # story rate-limits-join-invite-create-room (D2): ONE `join` token FIRST, before the room lookup (an idempotent re-join of a
    # joined user is charged too). `POST /rooms/{roomId}/join` and `POST /knock` are unrouted; when either is ever routed it MUST
    # charge this same bucket, so that no limiter-free join path exists.
    with_membership_charge(conn, [join_bucket(user)], fn ->
      req = %Core.JoinRoomRequest{user_id: user, room_id_or_alias: room}

      case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.join_room(req, stream(user)) end) do
        {:ok, resp} -> send_json(conn, 200, %{"room_id" => resp.room_id})
        {:error, err} -> send_error(conn, err)
      end
    end)
  end

  # ── POST /_matrix/client/v3/rooms/{roomId}/invite ─────────────────────────
  # Standard Matrix CS invite. The backend (EventDispatcher.Server.invite_user) already
  # exists and is reachable over the in-process gRPC layer; only the HTTP route was
  # missing. Body: {"user_id": "@invitee:server"}. Inviter is the authenticated user.
  post "/client/v3/rooms/:room_id/invite" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)
    params = body_params(conn)

    # story rate-limits-join-invite-create-room (D2): ONE `invite` token FIRST, before the body checks, the room lookup and the
    # already-invited no-op (a throttled user costs no work, and the existence oracle of the invite path is bounded)
    with_membership_charge(conn, [invite_bucket(user, 1)], fn ->
      cond do
        # story create-room-invites-direct (D4): the body checks come BEFORE any room check (they reveal nothing about the room)
        conn.assigns[:json_parse_error] == true ->
          error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

        # valid JSON that is not an object (Plug.Parsers wraps it as %{"_json" => value})
        Map.has_key?(params, "_json") ->
          error(conn, 400, "M_BAD_JSON", "Request body must be a JSON object")

        true ->
          # a present user_id selects the user-id form (3pid keys are then ignored); `reason` is not read (known deviation, D2)
          result =
            call_core(fn ->
              {:ok, invitee} = Nebu.Matrix.EventDispatcher.Server.invite_body_user_id(params)

              req = %Core.InviteUserRequest{room_id: room, inviter_id: user, invitee_id: invitee}
              Nebu.Matrix.EventDispatcher.Server.invite_user(req, stream(user))
            end)

          case result do
            {:ok, _resp} -> send_json(conn, 200, %{})
            {:error, err} -> send_error(conn, err)
          end
      end
    end)
  end

  # ── POST /_matrix/client/v3/rooms/{roomId}/kick | ban | unban (story moderation-routes-atomic-ban) ──
  # Body {"user_id", "reason"?}, answer 200 {}. D6 order, first failure wins: (1) ONE `moderation` token (a labelled divergence
  # from the spec's "Rate-limited: No"; 429 with Retry-After), (2) M_NOT_JSON / M_BAD_JSON, (3) user_id and (4) reason
  # (`EventDispatcher.Server.moderation_body!/1`), (5) the sender guard of story event-size-limit (a session user id above 255
  # bytes), (6) the core: the room (404), then the decision and the write in the room process (`Room.Server.moderate/6`).
  # The room id of the path is decoded like /invite. Fixed texts only, no client value is echoed.
  post "/client/v3/rooms/:room_id/kick" do
    moderation_request(conn, :kick, room_id)
  end

  post "/client/v3/rooms/:room_id/ban" do
    moderation_request(conn, :ban, room_id)
  end

  post "/client/v3/rooms/:room_id/unban" do
    moderation_request(conn, :unban, room_id)
  end

  defp moderation_request(conn, action, raw_room_id) do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(raw_room_id)
    params = body_params(conn)

    with_membership_charge(conn, [moderation_bucket(user)], fn ->
      cond do
        conn.assigns[:json_parse_error] == true ->
          error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

        # valid JSON that is not an object (Plug.Parsers wraps it as %{"_json" => value})
        Map.has_key?(params, "_json") ->
          error(conn, 400, "M_BAD_JSON", "Request body must be a JSON object")

        true ->
          case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.moderation_body!(params) end) do
            {:error, err} -> send_error(conn, err)
            {:ok, {target, reason}} -> moderation_call(conn, action, user, room, target, reason)
          end
      end
    end)
  end

  defp moderation_call(conn, action, user, room, target, reason) do
    case Nebu.Matrix.EventSize.check_keys("m.room.member", nil, user) do
      :ok ->
        server = Nebu.Matrix.EventDispatcher.Server
        fields = [room_id: room, caller_id: user, target_id: target, reason: reason || ""]

        result =
          call_core(fn ->
            case action do
              :kick -> server.kick_user(struct!(Core.KickUserRequest, fields), stream(user))
              :ban -> server.ban_user(struct!(Core.BanUserRequest, fields), stream(user))
              :unban -> server.unban_user(struct!(Core.UnbanUserRequest, fields), stream(user))
            end
          end)

        case result do
          {:ok, _resp} -> send_json(conn, 200, %{})
          {:error, err} -> send_error(conn, err)
        end

      key_check ->
        key_error(conn, key_check)
    end
  end

  # ── per-user charge of the room membership writes (story rate-limits-join-invite-create-room, D1-D3) ──
  # Buckets are `{{tier, user}, cost, rate_per_min, burst}` (the key shape of the plug's `key: :user`), the values come from
  # `Nebu.Web.RateLimitTiers`. A denied charge answers the unchanged 429 envelope (`retry_after_ms` + `Retry-After` seconds) with
  # the larger wait of the buckets that could not pay, and nothing else runs; `NEBU_RATE_LIMIT_DISABLED` turns the charge off.
  defp with_membership_charge(conn, buckets, fun) do
    case Nebu.Web.Plugs.RateLimit.take_all(buckets) do
      :ok -> fun.()
      {:deny, retry_after_s} -> Nebu.Web.Plugs.RateLimit.respond_limited(conn, retry_after_s)
    end
  end

  defp create_room_bucket(user) do
    {rate, burst} = Nebu.Web.RateLimitTiers.create_room()
    {{"create_room", user}, 1, rate, burst}
  end

  defp invite_bucket(user, units) do
    {rate, burst} = Nebu.Web.RateLimitTiers.invite()
    {{"invite", user}, units, rate, burst}
  end

  defp join_bucket(user) do
    {rate, burst} = Nebu.Web.RateLimitTiers.join()
    {{"join", user}, 1, rate, burst}
  end

  # story membership-state-model (D14): GET /members and GET /initialSync draw from ONE bucket (the initial /sync is not charged)
  defp members_read_bucket(user) do
    {rate, burst} = Nebu.Web.RateLimitTiers.members_read()
    {{"members_read", user}, 1, rate, burst}
  end

  # story moderation-routes-atomic-ban (D5): kick, ban and unban draw from ONE bucket
  defp moderation_bucket(user) do
    {rate, burst} = Nebu.Web.RateLimitTiers.moderation()
    {{"moderation", user}, 1, rate, burst}
  end

  # createRoom: ONE create_room token plus one invite unit per DISTINCT string entry of an `invite` list of at most 50 raw entries
  # (the cap of the core). Anything else charges no invite units: a longer list is a 400 anyway and must not drain the bucket, a
  # non-list is a 400. The count only decides the price; the core still validates the list.
  defp create_room_charge(user, params) do
    case invite_units(params["invite"]) do
      0 -> [create_room_bucket(user)]
      units -> [create_room_bucket(user), invite_bucket(user, units)]
    end
  end

  defp invite_units(list) when is_list(list) do
    if length(list) <= Nebu.Matrix.EventDispatcher.Server.invite_max_entries(),
      do: list |> Enum.filter(&is_binary/1) |> Enum.uniq() |> length(),
      else: 0
  end

  defp invite_units(_other), do: 0

  # ── PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId} ─────────
  put "/client/v3/rooms/:room_id/send/:event_type/:txn_id" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)

    # Parity fix (regression gate, matrix-api-migration): a malformed JSON body
    # must return 400 M_BAD_JSON, mirroring the typing handler above and matching
    # the Go gateway. Nebu.Web.Plugs.JsonBody assigns :json_parse_error on a body
    # that fails to parse; without this guard body_params/1 maps it to %{} and we
    # would silently send an empty-content event (200).
    key_check = Nebu.Matrix.EventSize.check_keys(event_type, nil, user)

    cond do
      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_BAD_JSON", "Request body is not valid JSON")

      # as on PUT state: a path value that is not valid UTF-8 is a 400 before the size pre-check encodes it
      not path_values_utf8?([room, event_type]) ->
        error(conn, 400, "M_BAD_JSON", "Path parameters must be valid UTF-8")

      # Story event-size-limit (D5): `type` above 255 bytes (decoded) is a 413, before the room lookup (an oversized request to
      # an unknown room is a 413, not a 404); the sender above 255 bytes is a 403. A message event has no state key.
      key_check != :ok ->
        key_error(conn, key_check)

      true ->
        # the content is encoded once: the size check and the request both use these bytes
        content_json = Jason.encode!(body_params(conn))

        # the complete signed event (`"state_key":null` is part of what Nebu signs) above 65 536 canonical bytes is a 413;
        # Room.Server.do_send_event/7 re-checks the signed bytes before the insert, the txn-dedup entry and the broadcast
        envelope = Nebu.Matrix.EventSize.envelope(room, user, event_type, nil, Nebu.DB.Helpers.now_ms())

        case Nebu.Matrix.EventSize.check(envelope, byte_size(content_json)) do
          {:error, :event_too_large} ->
            error(conn, 413, "M_TOO_LARGE", Nebu.Matrix.EventSize.message(:event_too_large))

          :ok ->
            req = %Core.SendEventRequest{
              room_id: room,
              sender_id: user,
              event_type: event_type,
              txn_id: txn_id,
              content: content_json,
              is_state_event: false
            }

            case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.send_event(req, stream(user)) end) do
              {:ok, resp} -> send_json(conn, 200, %{"event_id" => resp.event_id})
              {:error, err} -> send_error(conn, err)
            end
        end
    end
  end

  # ── PUT /_matrix/client/v3/rooms/{roomId}/redact/{eventId}/{txnId} (story state-writer-redaction, D1 - D3, D7, D13) ──
  # Body `{"reason"?}`, answer 200 {event_id}. NOT rate-limited (spec: Rate-limited: No). D13 order, first failure wins: M_NOT_JSON,
  # M_BAD_JSON (not an object, path values, depth, NUL, `reason` type), M_INVALID_PARAM (`reason` above 1024 bytes), the sender guard
  # (403), the envelope size (413), then the core: the room (404), the decision and the write in the room process.
  put "/client/v3/rooms/:room_id/redact/:event_id/:txn_id" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)
    target = URI.decode_www_form(event_id)
    params = body_params(conn)
    reason = params["reason"]
    key_check = Nebu.Matrix.EventSize.check_keys("m.room.redaction", nil, user)

    cond do
      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      Map.has_key?(params, "_json") ->
        error(conn, 400, "M_BAD_JSON", "Request body must be a JSON object")

      Nebu.Matrix.EventDispatcher.Server.contains_nul?([room, target, txn_id]) ->
        error(conn, 400, "M_BAD_JSON", "Path parameters must not contain NUL characters")

      not path_values_utf8?([room, target, txn_id]) ->
        error(conn, 400, "M_BAD_JSON", "Path parameters must be valid UTF-8")

      Nebu.Matrix.EventDispatcher.Server.content_too_deep?(params) ->
        error(conn, 400, "M_BAD_JSON", "State event content is nested too deeply")

      Nebu.Matrix.EventDispatcher.Server.contains_nul?(params) ->
        error(conn, 400, "M_BAD_JSON", "State event content must not contain NUL characters")

      not (is_nil(reason) or is_binary(reason)) ->
        error(conn, 400, "M_BAD_JSON", "reason must be a string")

      is_binary(reason) and byte_size(reason) > 1024 ->
        error(conn, 400, "M_INVALID_PARAM", "reason exceeds 1024 bytes")

      key_check != :ok ->
        key_error(conn, key_check)

      true ->
        content = params |> Map.delete("redacts") |> then(fn c -> if reason in [nil, ""], do: Map.delete(c, "reason"), else: c end)
        content_json = Jason.encode!(content)
        envelope = Nebu.Matrix.EventSize.envelope(room, user, "m.room.redaction", nil, Nebu.DB.Helpers.now_ms())

        case Nebu.Matrix.EventSize.check(Map.put(envelope, "redacts", target), byte_size(content_json)) do
          {:error, :event_too_large} ->
            error(conn, 413, "M_TOO_LARGE", Nebu.Matrix.EventSize.message(:event_too_large))

          :ok ->
            req = %Core.RedactEventRequest{room_id: room, sender_id: user, event_id: target, txn_id: txn_id, content_json: content_json}

            case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.redact_event(req, stream(user)) end) do
              {:ok, resp} -> send_json(conn, 200, %{"event_id" => resp.event_id})
              {:error, err} -> send_error(conn, err)
            end
        end
    end
  end

  # ── GET /_matrix/client/v3/rooms/{roomId}/messages ────────────────────────
  get "/client/v3/rooms/:room_id/messages" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)
    q = conn.query_params

    dir = q["dir"]

    cond do
      is_nil(dir) ->
        error(conn, 400, "M_MISSING_PARAM", "Missing required 'dir' parameter")

      dir not in ["f", "b"] ->
        error(conn, 400, "M_INVALID_PARAM", "dir must be 'f' or 'b'")

      true ->
        case parse_limit(q["limit"]) do
          :error ->
            error(conn, 400, "M_INVALID_PARAM", "limit must be an integer")

          {:ok, limit} ->
            req = %Core.GetMessagesRequest{
              room_id: room,
              from_token: q["from"] || "",
              to_token: q["to"],
              limit: limit,
              direction: dir
            }

            case call_core(fn ->
                   Nebu.Matrix.EventDispatcher.Server.get_messages(req, stream(user))
                 end) do
              {:ok, resp} ->
                chunk = Enum.map(resp.events, &message_event/1)

                send_json(conn, 200, %{
                  "chunk" => chunk,
                  "start" => resp.prev_batch,
                  "end" => resp.next_batch,
                  "state" => []
                })

              {:error, err} ->
                send_error(conn, err)
            end
        end
    end
  end

  # ── GET /_matrix/client/v3/rooms/{roomId}/initialSync ─────────────────────
  # Legacy room-load endpoint. Element Web calls it when the user navigates directly to
  # a room by URL (deep link) whose timeline isn't yet in the client's sync store — and
  # blocks on a "Joining…" spinner until it answers. Assemble the response from the
  # existing get_room_state (full state events) + get_messages (recent timeline), so a
  # client can render the room view without waiting for the next /sync cycle.
  # Story membership-state-model (D7, D10): `state` = the full current state with the EVENT-based member slots, real ids and
  # `unsigned`; members only (no peeking, `gf`); `visibility` stays the constant `private` (`gf`).
  get "/client/v3/rooms/:room_id/initialSync" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)

    # story membership-state-model (D14): ONE `members_read` token FIRST, before the room resolution
    with_membership_charge(conn, [members_read_bucket(user)], fn ->
      state_req = %Core.GetRoomStateRequest{room_id: room, event_type: "", state_key: ""}
      msg_req = %Core.GetMessagesRequest{room_id: room, from_token: "", to_token: nil, limit: 20, direction: "b"}

      with {:ok, state_resp} <-
             call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_room_state(state_req, stream(user)) end),
           {:ok, msg_resp} <-
             call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_messages(msg_req, stream(user)) end) do
        now = System.system_time(:millisecond)

        state = Enum.map(state_resp.state_events, &Nebu.Matrix.Http.state_event_json(&1, now, room))
        chunk = Enum.map(msg_resp.events, &message_event/1)

        send_json(conn, 200, %{
          "room_id" => room,
          "membership" => "join",
          "state" => state,
          "messages" => %{
            "chunk" => chunk,
            "start" => msg_resp.prev_batch,
            "end" => msg_resp.next_batch
          },
          "presence" => [],
          "account_data" => [],
          "visibility" => "private"
        })
      else
        {:error, err} -> send_error(conn, err)
      end
    end)
  end

  # ── PUT /_matrix/client/v3/rooms/{roomId}/typing/{userId} ─────────────────
  put "/client/v3/rooms/:room_id/typing/:path_user_id" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)
    target = URI.decode_www_form(path_user_id)
    params = body_params(conn)
    typing = params["typing"] == true

    cond do
      target != user ->
        error(conn, 403, "M_FORBIDDEN", "userId in path does not match authenticated user")

      # Matrix spec: when typing=true, a timeout is required.
      typing and not is_integer(params["timeout"]) ->
        error(conn, 400, "M_BAD_JSON", "typing:true requires an integer timeout")

      true ->
        timeout_ms = if typing, do: params["timeout"], else: 0

        req = %Core.SetTypingRequest{
          room_id: room,
          user_id: user,
          typing: typing,
          timeout_ms: timeout_ms
        }

        case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.set_typing(req, stream(user)) end) do
          {:ok, _resp} -> send_json(conn, 200, %{})
          {:error, err} -> send_error(conn, err)
        end
    end
  end

  # ── POST /_matrix/client/v3/rooms/{roomId}/receipt/{receiptType}/{eventId} ─
  post "/client/v3/rooms/:room_id/receipt/:receipt_type/:event_id" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)
    event = URI.decode_www_form(event_id)

    if receipt_type not in ["m.read", "m.read.private"] do
      error(conn, 400, "M_INVALID_PARAM", "Only m.read and m.read.private receipts are supported")
    else
      req = %Core.SendReceiptRequest{
        room_id: room,
        user_id: user,
        receipt_type: receipt_type,
        event_id: event
      }

      case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.send_receipt(req, stream(user)) end) do
        {:ok, _resp} -> send_json(conn, 200, %{})
        {:error, err} -> send_error(conn, err)
      end
    end
  end

  # ── GET /_matrix/client/v3/presence/{userId}/status ───────────────────────
  get "/client/v3/presence/:path_user_id/status" do
    user = conn.assigns[:current_user]
    target = URI.decode_www_form(path_user_id)

    req = %Core.GetPresenceRequest{user_id: target}

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_presence(req, stream(user)) end) do
      {:ok, resp} ->
        send_json(conn, 200, %{
          "presence" => resp.presence,
          "last_active_ago" => resp.last_active_ago
        })

      {:error, _err} ->
        error(conn, 503, "M_UNAVAILABLE", "Presence service unavailable")
    end
  end

  # ── PUT /_matrix/client/v3/presence/{userId}/status ───────────────────────
  put "/client/v3/presence/:path_user_id/status" do
    user = conn.assigns[:current_user]
    target = URI.decode_www_form(path_user_id)

    if target != user do
      error(conn, 403, "M_FORBIDDEN", "You can only set your own presence")
    else
      params = body_params(conn)

      req = %Core.SetPresenceRequest{user_id: user, presence: params["presence"] || ""}

      case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.set_presence(req, stream(user)) end) do
        {:ok, _resp} -> send_json(conn, 200, %{})
        {:error, _err} -> error(conn, 503, "M_UNAVAILABLE", "Presence service unavailable")
      end
    end
  end

  # ── POST /_matrix/client/v3/rooms/{roomId}/leave ──────────────────────────
  # Standard Matrix CS leave (also declines a pending invite). The backend
  # (EventDispatcher.Server.leave_room) already exists; only the HTTP route was
  # missing (go-removal regression). Acting user is the authenticated user — the
  # room can only be left on one's own behalf (no path/body user → no IDOR).
  post "/client/v3/rooms/:room_id/leave" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)

    req = %Core.LeaveRoomRequest{user_id: user, room_id: room}

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.leave_room(req, stream(user)) end) do
      {:ok, _resp} -> send_json(conn, 200, %{})
      {:error, err} -> send_error(conn, err)
    end
  end

  # ── POST /_matrix/client/v3/rooms/{roomId}/forget ─────────────────────────
  # Per spec, forgetting is only valid AFTER leaving — the backend raises
  # failed_precondition while still joined, which call_core maps to 400
  # M_BAD_STATE. Acting user is always the authenticated user.
  post "/client/v3/rooms/:room_id/forget" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)

    req = %Core.ForgetRoomRequest{room_id: room, user_id: user}

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.forget_room(req, stream(user)) end) do
      {:ok, _resp} -> send_json(conn, 200, %{})
      {:error, err} -> send_error(conn, err)
    end
  end

  # ── GET /_matrix/client/v1/rooms/{roomId}/relations/{eventId}[/{relType}[/{eventType}]]
  # Loads event relations (threads, edits, reactions). The backend
  # (EventDispatcher.Server.get_relations) enforces membership and scopes the
  # parent-event existence check to the room (no cross-room probing); it clamps
  # `limit` to 1–100. relType/eventType are optional path segments (empty = all).
  # Matrix spec uses the /v1 path; the top router's catch-all `/_matrix` forward
  # routes it here (the explicit /v1/auth_* forwards are exact-prefix and do not
  # shadow /v1/rooms).
  get "/client/v1/rooms/:room_id/relations/:event_id" do
    do_relations(conn, room_id, event_id, "", "")
  end

  get "/client/v1/rooms/:room_id/relations/:event_id/:rel_type" do
    do_relations(conn, room_id, event_id, rel_type, "")
  end

  get "/client/v1/rooms/:room_id/relations/:event_id/:rel_type/:event_type" do
    do_relations(conn, room_id, event_id, rel_type, event_type)
  end

  defp do_relations(conn, raw_room, raw_event, rel_type, event_type) do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(raw_room)
    event = URI.decode_www_form(raw_event)
    q = conn.query_params

    req = %Core.GetRelationsRequest{
      user_id: user,
      room_id: room,
      event_id: event,
      rel_type: URI.decode_www_form(rel_type),
      event_type: URI.decode_www_form(event_type),
      dir: q["dir"] || "",
      from: q["from"] || "",
      limit: relations_limit(q["limit"])
    }

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_relations(req, stream(user)) end) do
      {:ok, resp} ->
        send_json(conn, 200, %{
          "chunk" => Enum.map(resp.events, &message_event/1),
          "next_batch" => resp.next_batch,
          "prev_batch" => resp.prev_batch
        })

      {:error, err} ->
        send_error(conn, err)
    end
  end

  # ── GET /_matrix/client/v1/rooms/{roomId}/hierarchy ───────────────────────
  # Spaces S3 (MSC2946): BFS-ordered tree of rooms reachable via m.space.child.
  # The backend (EventDispatcher.Server.get_space_hierarchy) enforces the ROOT
  # visibility gate (non-member of a private / non-world-readable space → 403)
  # and the per-room visibility filter (hidden rooms excluded, their children
  # still traversed). Matrix uses the /v1 path; the top router's catch-all
  # `/_matrix` forward routes it here (same as relations). The acting user is the
  # authenticated token user (no path/body user → no IDOR). Query params:
  #   limit          — page size; negative → 400; > 1000 clamped to 1000
  #   max_depth      — BFS depth cap; negative → 400
  #   suggested_only — must be "true" / "false"; anything else → 400
  #   from           — opaque pagination cursor; forged → 400 (backend, fail closed)
  get "/client/v1/rooms/:room_id/hierarchy" do
    do_space_hierarchy(conn, room_id)
  end

  defp do_space_hierarchy(conn, raw_room) do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(raw_room)
    q = conn.query_params

    with {:ok, suggested_only} <- parse_bool_param(q["suggested_only"], false),
         {:ok, limit} <- parse_hierarchy_limit(q["limit"]),
         {:ok, max_depth} <- parse_hierarchy_depth(q["max_depth"]) do
      req = %Core.GetSpaceHierarchyRequest{
        root_room_id: room,
        user_id: user,
        limit: limit,
        max_depth: max_depth,
        suggested_only: suggested_only,
        from_token: q["from"] || ""
      }

      case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_space_hierarchy(req, stream(user)) end) do
        {:ok, resp} ->
          body = %{"rooms" => Enum.map(resp.rooms, &hierarchy_room/1)}

          body =
            if resp.next_batch_token != "",
              do: Map.put(body, "next_batch", resp.next_batch_token),
              else: body

          send_json(conn, 200, body)

        {:error, err} ->
          send_error(conn, err)
      end
    else
      {:error, :invalid_param} ->
        error(conn, 400, "M_INVALID_PARAM", "Invalid query parameter")
    end
  end

  # suggested_only: only "true" / "false" are valid (spec). Absent → default.
  defp parse_bool_param(nil, default), do: {:ok, default}
  defp parse_bool_param("true", _default), do: {:ok, true}
  defp parse_bool_param("false", _default), do: {:ok, false}
  defp parse_bool_param(_other, _default), do: {:error, :invalid_param}

  # limit: non-negative integer; > 1000 is clamped server-side (no error). A
  # negative limit or non-integer → 400. Absent → a generous server default
  # (100) so the full small tree is returned in one page without pagination.
  defp parse_hierarchy_limit(nil), do: {:ok, 100}

  defp parse_hierarchy_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {v, ""} when v >= 0 -> {:ok, min(v, 1000)}
      _ -> {:error, :invalid_param}
    end
  end

  # max_depth: non-negative integer or absent (→ 0 sentinel meaning "default,"
  # the backend treats 0 as root-only; we send a large default when absent).
  defp parse_hierarchy_depth(nil), do: {:ok, 1000}

  defp parse_hierarchy_depth(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {v, ""} when v >= 0 -> {:ok, v}
      _ -> {:error, :invalid_param}
    end
  end

  # Core.HierarchyRoom → Matrix hierarchy room JSON (MSC2946 shape). room_type is
  # omitted when empty; children_state is decoded back from its JSON array.
  defp hierarchy_room(%Core.HierarchyRoom{} = r) do
    base = %{
      "room_id" => r.room_id,
      "name" => r.name,
      "topic" => r.topic,
      "canonical_alias" => r.canonical_alias,
      "num_joined_members" => r.num_joined_members,
      "world_readable" => r.world_readable,
      "guest_can_join" => r.guest_can_join,
      "join_rule" => r.join_rule,
      "avatar_url" => r.avatar_url,
      "children_state" => decode_children_state(r.children_state_json)
    }

    if r.room_type != "", do: Map.put(base, "room_type", r.room_type), else: base
  end

  defp decode_children_state(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_children_state(_), do: []

  # Relations limit: default 0 (backend clamps 0 → 1..100). A non-integer is
  # ignored (0). The backend re-clamps, so this is just best-effort parsing.
  defp relations_limit(nil), do: 0

  defp relations_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {v, _} -> v
      :error -> 0
    end
  end

  # ── GET /_matrix/client/v1/room_summary/{roomIdOrAlias} ───────────────────
  # Matrix v1.15 core ("Room Summaries"), story oauth-room-summary-unrecognized (RU1 - RU8): a LOCAL-ONLY
  # preview of a room by id or alias (no federation, `via` and every other query parameter ignored).
  # Authentication is required (the OidcPlug of `authenticate/2`). Existence is checked BEFORE the room
  # state is read (the state read lazy-starts a Room and would insert a `rooms` row for any attacker-chosen
  # id, RU3); unknown, archived and not-visible rooms all answer the byte-identical
  # `404 M_NOT_FOUND "Room not found"` (anti-enumeration). Rate limited per user although the spec says
  # "Rate-limited: No" (RU7, recorded deviation: each call may lazy-start a Room).
  @room_summary_rate_limit Nebu.Web.Plugs.RateLimit.init(
                             rate_per_min: 300,
                             burst: 60,
                             tier: "room_summary",
                             key: :user
                           )

  get "/client/v1/room_summary/:room_id_or_alias" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @room_summary_rate_limit)

    if conn.halted do
      conn
    else
      do_room_summary(conn, room_id_or_alias)
    end
  end

  # RU8: the param is used exactly as Plug decoded the path segment (NO second www-form decoding: `+` and
  # `%25` stay literal). `!` room id or `#` alias, at most 255 bytes; a `:` is required only for an alias
  # (room version 12 ids may carry no domain). Invalid => 400 before any DB access.
  defp do_room_summary(conn, raw) do
    user = conn.assigns[:current_user]

    if valid_room_summary_param?(raw) do
      req = %{room_id_or_alias: raw, user_id: user}

      case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_room_summary(req, stream(user)) end) do
        {:ok, summary} -> send_json(conn, 200, summary)
        {:error, err} -> send_error(conn, err)
      end
    else
      error(conn, 400, "M_INVALID_PARAM", "roomIdOrAlias must be a room id (!...) or a room alias (#...:server)")
    end
  end

  # Also valid UTF-8 without control characters (review cycle 1, MINOR 2): `!%00x` / `#a%FF:b` would otherwise
  # reach Postgres, which rejects them (22021) => a 500 plus a warning for attacker input.
  defp valid_room_summary_param?(raw) do
    byte_size(raw) <= 255 and String.valid?(raw) and not (raw =~ ~r/\p{Cc}/u) and shape_ok?(raw)
  end

  defp shape_ok?("!" <> _), do: true
  defp shape_ok?("#" <> _ = raw), do: String.contains?(raw, ":")
  defp shape_ok?(_), do: false

  # ── GET /_matrix/client/v1/mutual_rooms ───────────────────────────────────
  # MSC2666 (Matrix CS API v1.19): rooms the caller currently shares with
  # `user_id` (both hold membership: join). Pure direct-DB-read — the backend
  # (EventDispatcher.Server.get_mutual_rooms) calls get_rooms_for_user/1 twice
  # and intersects; no Room GenServer/:pg/Horde touch.
  #
  # Validation order: user_id present → Nebu.Matrix.UserId.valid?/1 → user_id
  # != caller, all before any DB touch. A forged/malformed `from` pagination
  # token (decoded inside get_mutual_rooms, own "mr1:" opaque offset token)
  # fails the same way. All four 400 causes (missing/malformed/self user_id,
  # bad `from`) use M_INVALID_PARAM uniformly, per MSC2666 — not this
  # project's usual M_MISSING_PARAM convention for an absent param. A
  # syntactically-valid but unknown `user_id` returns 200 {count: 0,
  # joined: []}, never 404 (anti-enumeration).
  #
  # Rate-limited via the shared Nebu.Web.Plugs.RateLimit plug, which keys its
  # token bucket by IP alone, not `{ip, tier}`. This tier's burst: 30 draws
  # from and can clamp down the SAME per-IP bucket that /sync (burst: 100)
  # and /login (burst: 10, http_public.ex) also use — a single mutual_rooms
  # request can temporarily reduce those endpoints' available headroom until
  # the shared bucket re-accrues. This is a pre-existing property of the
  # shared plug (keyed by IP, not per endpoint), not something unique to or
  # fixed by this endpoint.
  @mutual_rooms_rate_limit Nebu.Web.Plugs.RateLimit.init(
                             rate_per_min: 120,
                             burst: 30,
                             tier: "mutual_rooms"
                           )

  get "/client/v1/mutual_rooms" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @mutual_rooms_rate_limit)

    if conn.halted do
      conn
    else
      do_mutual_rooms(conn, unstable: false)
    end
  end

  # ── GET /client/unstable/uk.half-shot.msc2666/user/mutual_rooms ───────────
  # Alias for the handler above. The `unstable_features
  # ["uk.half-shot.msc2666.query_mutual_rooms"]` flag in /versions is what
  # real clients (matrix-js-sdk/Element) check to decide whether to call this
  # feature at all, and that flag has always signalled this unstable path
  # rather than the stable v1 one — so both routes need to exist and work,
  # sharing one handler.
  #
  # This path never paginates: it always returns the complete `joined` list,
  # never emits `next_batch`, and ignores any `from` query param it receives.
  # The historical/real-world unstable MSC2666 endpoint never had a
  # pagination concept (verified against actual historical server
  # implementations, not assumed), so this calls
  # EventDispatcher.Server.get_mutual_rooms/4 with `unpaginated: true` rather
  # than forwarding to the paginated logic unchanged — which would otherwise
  # silently truncate a legacy client's response once shared rooms exceed one
  # page. `count` is kept in the body (harmless extra field, costs nothing)
  # for consistency with the v1 shape. The stable v1 route's own pagination
  # (page size, `from`/`next_batch`) is unchanged and independent of this
  # alias.
  get "/client/unstable/uk.half-shot.msc2666/user/mutual_rooms" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @mutual_rooms_rate_limit)

    if conn.halted do
      conn
    else
      do_mutual_rooms(conn, unstable: true)
    end
  end

  defp do_mutual_rooms(conn, opts) do
    unstable? = Keyword.get(opts, :unstable, false)
    user = conn.assigns[:current_user]
    q = conn.query_params
    target = q["user_id"]

    case validate_mutual_rooms_user_id(target, user) do
      {:error, :invalid_param} ->
        error(conn, 400, "M_INVALID_PARAM", "user_id is required and must be a valid, non-self Matrix user ID")

      {:ok, target} ->
        # The unstable path has no pagination concept, so any `from` it
        # receives is simply ignored rather than decoded/validated.
        from = if unstable?, do: nil, else: q["from"]

        case call_core(fn ->
               Nebu.Matrix.EventDispatcher.Server.get_mutual_rooms(user, target, from,
                 unpaginated: unstable?
               )
             end) do
          {:ok, resp} ->
            body = %{"count" => resp.count, "joined" => resp.joined}
            body = if resp.next_batch, do: Map.put(body, "next_batch", resp.next_batch), else: body
            send_json(conn, 200, body)

          {:error, err} ->
            send_error(conn, err)
        end
    end
  end

  # user_id must be present, pass Nebu.Matrix.UserId.valid?/1's shape check, and
  # not equal the caller's own mxid — all cheap, DB-free, default-deny checks
  # (consistent with admin_add_room_member/3's existing "validate before any
  # write" pattern, even though this endpoint only reads).
  defp validate_mutual_rooms_user_id(user_id, caller) when is_binary(user_id) and user_id != "" do
    cond do
      not Nebu.Matrix.UserId.valid?(user_id) -> {:error, :invalid_param}
      user_id == caller -> {:error, :invalid_param}
      true -> {:ok, user_id}
    end
  end

  defp validate_mutual_rooms_user_id(_user_id, _caller), do: {:error, :invalid_param}

  # ── GET /_matrix/client/v3/rooms/{roomId}/members ─────────────────────────
  # The latest member EVENT of every user (story membership-state-model, D6; Element's member list), real ids, `unsigned`.
  # `membership` / `not_membership` are validated BEFORE any room access (first failure wins, fixed texts, the last value of a
  # repeated parameter) and combine as AND (Synapse parity); `at` is ignored. Joined members only (`get_room_members/2`).
  get "/client/v3/rooms/:room_id/members" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)

    # D14: ONE `members_read` token FIRST, before the query validation and the room resolution
    with_membership_charge(conn, [members_read_bucket(user)], fn ->
      q = conn.query_params

      with :ok <- validate_membership_filter(q, "membership"),
           :ok <- validate_membership_filter(q, "not_membership") do
        req = %{room_id: room, membership: q["membership"], not_membership: q["not_membership"]}

        case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_room_members(req, stream(user)) end) do
          {:ok, resp} ->
            now = System.system_time(:millisecond)
            send_json(conn, 200, %{"chunk" => Enum.map(resp.state_events, &Nebu.Matrix.Http.state_event_json(&1, now, room))})

          {:error, err} ->
            send_error(conn, err)
        end
      else
        {:invalid, name} -> error(conn, 400, "M_INVALID_PARAM", "#{name} must be one of join, invite, knock, leave, ban")
      end
    end)
  end

  # absent or one of the five memberships (case-sensitive); the empty string or a Plug list / map (`name[]=`) is invalid
  defp validate_membership_filter(query, name) do
    case Map.fetch(query, name) do
      :error -> :ok
      {:ok, value} when value in ["join", "invite", "knock", "leave", "ban"] -> :ok
      {:ok, _value} -> {:invalid, name}
    end
  end

  # ── GET /_matrix/client/v3/rooms/{roomId}/event/{eventId} ─────────────────
  # Single-event fetch (Element's thread.ts loads thread roots through this). The
  # backend (EventDispatcher.Server.get_event) enforces membership (403 for a
  # non-member, no cross-room leak) and returns 404 for an unknown event in the
  # room. Acting user is the authenticated user (no path/body user → no IDOR);
  # the Core.Event is serialised with the shared message_event/1 mapper.
  get "/client/v3/rooms/:room_id/event/:event_id" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)
    event = URI.decode_www_form(event_id)

    req = %Core.GetEventRequest{room_id: room, event_id: event, user_id: user}

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_event(req, stream(user)) end) do
      {:ok, resp} -> send_json(conn, 200, message_event(resp.event))
      {:error, err} -> send_error(conn, err)
    end
  end

  # ── POST /_matrix/client/v3/rooms/{roomId}/read_markers ───────────────────
  # Body: {"m.fully_read": "$ev", "m.read": "$ev", "m.read.private": "$ev"} (all optional).
  #   * membership/authorization = /receipt (Server.ensure_room_member!: 404 unknown room,
  #     403 non-member) — checked FIRST for every marker;
  #   * m.read / m.read.private go through Server.send_receipt, i.e. exactly the /receipt
  #     path (same validation, same upsert);
  #   * m.fully_read is stored as the user's room account data event `m.fully_read`
  #     ({"event_id": ...}) and delivered via /sync. The event must belong to the room
  #     (400 M_INVALID_PARAM otherwise). m.fully_read is server-managed and EXEMPT from the
  #     per-user row/total caps, so validation (member, event) is the only refusal before
  #     the first write; the m.fully_read store runs FIRST and the receipts after it, so a
  #     failing m.fully_read store (DB error) writes no receipts.
  post "/client/v3/rooms/:room_id/read_markers" do
    user = conn.assigns[:current_user]
    params = body_params(conn)
    markers = Map.take(params, ["m.fully_read", "m.read", "m.read.private"])

    cond do
      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      not Enum.all?(markers, fn {_k, v} -> is_binary(v) and v != "" end) ->
        error(conn, 400, "M_INVALID_PARAM", "Read marker values must be event ids")

      true ->
        with {:ok, _} <-
               call_core(fn -> Nebu.Matrix.EventDispatcher.Server.ensure_room_member!(room_id, user) end),
             :ok <- check_fully_read_event(room_id, user, markers["m.fully_read"]),
             :ok <- store_fully_read(user, room_id, markers["m.fully_read"]),
             :ok <- send_marker_receipts(user, room_id, markers) do
          send_json(conn, 200, %{})
        else
          {:error, {status, errcode, message}} -> error(conn, status, errcode, message)
        end
    end
  end

  defp check_fully_read_event(_room_id, _user, nil), do: :ok

  # story history-visibility-enforcement (security cycle 1, LOW #4): the event must be one the user may SEE (a hidden event is
  # refused exactly like an unknown one: no existence oracle)
  defp check_fully_read_event(room_id, user, event_id) do
    if Nebu.Matrix.EventDispatcher.Server.visible_event?(room_id, user, event_id),
      do: :ok,
      else: {:error, {400, "M_INVALID_PARAM", "m.fully_read event does not belong to this room"}}
  end

  defp send_marker_receipts(user, room_id, markers) do
    Enum.reduce_while(["m.read", "m.read.private"], :ok, fn type, :ok ->
      case markers[type] do
        nil ->
          {:cont, :ok}

        event_id ->
          req = %Core.SendReceiptRequest{room_id: room_id, user_id: user, receipt_type: type, event_id: event_id}

          case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.send_receipt(req, stream(user)) end) do
            {:ok, _} -> {:cont, :ok}
            {:error, err} -> {:halt, {:error, err}}
          end
      end
    end)
  end

  defp store_fully_read(_user, _room_id, nil), do: :ok

  defp store_fully_read(user, room_id, event_id) do
    case Nebu.Matrix.RoomAccountDataStore.put(user, room_id, "m.fully_read", Jason.encode!(%{"event_id" => event_id})) do
      :ok -> :ok
      {:error, :limit_exceeded} -> {:error, {403, "M_RESOURCE_LIMIT_EXCEEDED", "Too many room account data entries"}}
      {:error, _} -> {:error, {500, "M_UNKNOWN", "Internal server error"}}
    end
  end

  # Room-account-data helpers ---------------------------------------------------

  # Matrix room id syntax: "!" + opaque localpart, no whitespace, max 255 bytes.
  defp valid_room_id?(room_id),
    do: byte_size(room_id) <= 255 and Regex.match?(~r/\A![^\s\/]+\z/u, room_id)

  # Same 403 for "unknown room" and "not a member" → no room-existence leak.
  defp require_room_member(user, room_id) do
    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.ensure_room_member!(room_id, user) end) do
      {:ok, _} -> :ok
      {:error, {404, _, _}} -> {:error, {403, "M_FORBIDDEN", "You are not a member of this room"}}
      {:error, err} -> {:error, err}
    end
  end

  # The raw bytes the client sent (cached by RawBodyReader for account-data routes).
  defp raw_request_body(conn, max_bytes \\ Nebu.Matrix.RoomAccountDataStore.max_bytes()) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) ->
        body

      _ ->
        # Parser skipped (non-JSON content type): read it here, bounded.
        case Plug.Conn.read_body(conn, length: max_bytes + 1) do
          {:ok, body, _conn} -> body
          _ -> String.duplicate("x", max_bytes + 1)
        end
    end
  end

  defp valid_json?(raw), do: match?({:ok, _}, Jason.decode(raw))

  defp json_object?(raw) do
    match?({:ok, m} when is_map(m), Jason.decode(raw))
  end

  # ── POST /_matrix/client/v3/rooms/{roomId}/upgrade ────────────────────────
  # Creates a replacement room and tombstones the old one. The backend
  # (EventDispatcher.Server.upgrade_room) takes the requester from the trusted
  # stream identity (NOT request.requester_id) and requires the upgrade level
  # (PowerLevels.upgrade_level/1: the tombstone level, at least 100), so a
  # requester below it is rejected with 403. Body: {"new_version": "<v>"}.
  post "/client/v3/rooms/:room_id/upgrade" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)
    params = body_params(conn)

    # story rate-limits-join-invite-create-room (review cycle 1, Kassandra L-1): an upgrade creates a NEW room, so it spends one
    # `create_room` unit of the user, charged FIRST like createRoom (an upgrade chain can no longer mint rooms without limit)
    with_membership_charge(conn, [create_room_bucket(user)], fn -> upgrade_room_request(conn, user, room, params) end)
  end

  # The upgrade handler proper (everything after the rate-limit charge).
  defp upgrade_room_request(conn, user, room, params) do
    # Story create-room-input-validation (D1, Oracle): `new_version` is REQUIRED (Matrix CS v1.18). Absent / null ->
    # 400 M_MISSING_PARAM, a non-string -> 400 M_BAD_JSON, both decided here before any room is touched; an
    # empty / unsupported string is 400 M_UNSUPPORTED_ROOM_VERSION from the core (also before the room lookup).
    # A body that is not JSON (M_NOT_JSON) or not an object (M_BAD_JSON) is told apart first, as in createRoom.
    case (cond do
            conn.assigns[:json_parse_error] == true -> :not_json
            Map.has_key?(params, "_json") -> :not_object
            true -> params["new_version"]
          end) do
      :not_json ->
        error(conn, 400, "M_NOT_JSON", "Request body is not valid JSON")

      :not_object ->
        error(conn, 400, "M_BAD_JSON", "Request body must be a JSON object")

      nil ->
        error(conn, 400, "M_MISSING_PARAM", "new_version is required")

      new_version when not is_binary(new_version) ->
        error(conn, 400, "M_BAD_JSON", "new_version must be a string")

      new_version ->
        req = %Core.UpgradeRoomRequest{
          old_room_id: room,
          requester_id: user,
          new_version: new_version
        }

        case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.upgrade_room(req, stream(user)) end) do
          {:ok, resp} -> send_json(conn, 200, %{"replacement_room" => resp.new_room_id})
          {:error, err} -> send_error(conn, err)
        end
    end
  end

  # ── POST /_matrix/client/v3/search ────────────────────────────────────────
  # Full-text message search. The backend (EventDispatcher.Server.search_messages)
  # takes the user from the trusted stream identity and enforces membership
  # scoping at the SQL layer (parameterised — no interpolation, ADR-018), clamps
  # the limit to 1–100, and decodes the next_batch pagination token. The Matrix
  # request nests the term under search_categories.room_events.search_term; the
  # response is search_categories.room_events.{count,results,next_batch}.
  post "/client/v3/search" do
    user = conn.assigns[:current_user]
    params = body_params(conn)
    room_events = get_in(params, ["search_categories", "room_events"]) || %{}

    filter = room_events["filter"] || %{}

    req = %Core.SearchMessagesRequest{
      user_id: user,
      search_term: room_events["search_term"] || "",
      room_filter: list_param(filter["rooms"]),
      sender_filter: list_param(filter["senders"]),
      limit: search_limit(filter["limit"]),
      next_batch: conn.query_params["next_batch"] || ""
    }

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.search_messages(req, stream(user)) end) do
      {:ok, resp} ->
        results = Enum.map(resp.results, &search_result/1)

        send_json(conn, 200, %{
          "search_categories" => %{
            "room_events" => %{
              "count" => resp.total_count,
              "results" => results,
              "next_batch" => resp.next_batch,
              "highlights" => [],
              "groups" => %{}
            }
          }
        })

      {:error, err} ->
        send_error(conn, err)
    end
  end

  # Maps a Core.SearchResult to the Matrix `room_events.results[]` shape. The
  # backend packs the matched event as a JSON string in `result.event`.
  defp search_result(%Core.SearchResult{} = r) do
    %{
      "rank" => r.rank,
      "result" => decode_event(r.event),
      "context" => %{
        "events_before" => Enum.map(r.events_before, &decode_event/1),
        "events_after" => Enum.map(r.events_after, &decode_event/1)
      }
    }
  end

  defp decode_event(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp decode_event(_), do: %{}

  defp list_param(l) when is_list(l), do: Enum.filter(l, &is_binary/1)
  defp list_param(_), do: []

  defp search_limit(n) when is_integer(n), do: n
  defp search_limit(_), do: 0

  # ── PUT profile subfields (authenticated) ─────────────────────────────────
  # GET profile is unauthenticated (Nebu.Matrix.HttpPublic). PUT requires auth and
  # is normally reached via MatrixPublic's inline OidcPlug; these routes are a
  # belt-and-suspenders fallback if the path is dispatched here directly.
  put "/client/v3/profile/:path_user_id/displayname" do
    update_profile_field(conn, path_user_id, :displayname)
  end

  put "/client/v3/profile/:path_user_id/avatar_url" do
    update_profile_field(conn, path_user_id, :avatar_url)
  end

  # ── PUT /_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey} ─────
  # ── PUT /_matrix/client/v3/rooms/{roomId}/state/{eventType} (empty stateKey) ─
  # Spaces S2: generic Matrix state-event write. The backend
  # (EventDispatcher.Server.set_room_state) enforces an ALLOWLIST of writable
  # state types (m.space.child/parent, m.room.name/topic/avatar/join_rules/
  # canonical_alias/history_visibility/guest_access) and a power-level check
  # (sender PL >= events[type] else state_default; non-member → 403; a state key
  # starting with `@` must be the sender's id). m.room.power_levels goes to the
  # room-process power-level writer (story power-levels-enforcement: the v10 change
  # rules, the `moderation` rate tier). m.room.member / m.room.create are rejected
  # (403) — they have dedicated authorized paths and must NOT be forgeable here. For m.space.parent the parent
  # space must exist (404) and the sender must be a member of it (403). The acting
  # user is the authenticated token user (no path/body user → no IDOR); the
  # server builds all top-level event fields — the body is the content only.
  put "/client/v3/rooms/:room_id/state/:event_type/:state_key" do
    do_set_room_state(conn, room_id, event_type, state_key)
  end

  put "/client/v3/rooms/:room_id/state/:event_type" do
    do_set_room_state(conn, room_id, event_type, "")
  end

  # ── Fall-through (story oauth-room-summary-unrecognized, RU9 - RU12) ──────
  # Marked `nebu_unrecognized` so `authenticate/2` skips the OidcPlug: an unimplemented endpoint has no
  # authentication requirement (RU10). Only requests that reach this clause change; every handler-level
  # error (`M_NOT_FOUND`, `M_BAD_JSON`, ...) is produced inside the route clauses above and untouched.
  match _, private: %{nebu_unrecognized: true} do
    if unimplemented_state_read?(conn) do
      # RU11a carve-out: `GET /rooms/{id}/state[/{type}[/{key}]]` is not implemented (only PUT is).
      # Clients (matrix-js-sdk getStateEvent, Element, Dart SDK) read `404 M_NOT_FOUND` as "state
      # absent": keep exactly that answer until the GET endpoints exist (follow-up bf).
      error(conn, 404, "M_NOT_FOUND", "Unrecognized request")
    else
      Nebu.Web.Unrecognized.respond(conn, allowed_methods(conn))
    end
  end

  defp unimplemented_state_read?(%Plug.Conn{method: "GET", path_info: ["client", "v3", "rooms", _room, "state" | _]}), do: true
  defp unimplemented_state_read?(_conn), do: false

  # The methods for which THIS router has a real clause at the request path (RU11): a probe selects a
  # `do_match/4` clause, it never dispatches. The marker is removed first, a probe is a real match only
  # when the catch-all (which sets the marker) was not the clause chosen.
  defp allowed_methods(conn) do
    path = Plug.Router.Utils.decode_path_info!(conn)
    conn = %{conn | private: Map.delete(conn.private, :nebu_unrecognized)}

    Nebu.Web.Unrecognized.probe(conn, fn c ->
      do_match(c, c.method, path, c.host).private[:nebu_unrecognized] !== true
    end)
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # S3 AC5 / G1 / G2 — User-Interactive-Authentication gate (Option B, m.login.sso).
  #
  # `op` + `params` (the sorted target device_ids) bind the UIA session. `proceed` is
  # the success continuation run once UIA is satisfied. Flow:
  #
  #   * An `auth: {"session": id}` block in the body → atomically consume the bound,
  #     stage-complete, single-use UIA session (Uia.consume); on success proceed, on
  #     failure (foreign user / wrong op / already-consumed / not-completed) re-challenge
  #     with a FRESH session (401). This is what makes a replayed/foreign session a 401
  #     rather than a free pass (G2).
  #   * No auth block → if the caller's last fresh auth is within the window, proceed
  #     directly (G1 fresh path); otherwise mint a UIA session bound to (user, op, params)
  #     and return the 401 challenge.
  defp uia_gate(conn, op, device_ids, proceed) do
    user = conn.assigns[:current_user]
    canonical = Nebu.Matrix.Uia.canonical_params(device_ids)
    auth = body_params(conn)["auth"]

    cond do
      is_map(auth) and is_binary(auth["session"]) ->
        case Nebu.Matrix.Uia.consume(auth["session"], user, op, canonical) do
          # `true` = satisfied via a FRESH m.login.sso re-auth (auth block). The user
          # just re-authenticated, so the token making this request is preserved.
          :ok -> proceed.(conn, true)
          :error -> challenge(conn, user, op, canonical)
        end

      Nebu.Matrix.Uia.fresh?(caller_auth_time(conn)) ->
        # Satisfied by the recent-login window (no fresh re-auth this request): the
        # presented token bound to a deleted device is revoked as normal.
        proceed.(conn, false)

      true ->
        challenge(conn, user, op, canonical)
    end
  end

  defp challenge(conn, user, op, canonical) do
    session_id = Nebu.Matrix.Uia.mint_session(user, op, canonical)
    send_json(conn, 401, Nebu.Matrix.Uia.challenge_body(session_id))
  end

  # The caller's last-fresh-auth time (unix seconds) for the UIA window. An opaque
  # session reads matrix_sessions.auth_time; a raw JWT uses its auth_time/iat claim.
  defp caller_auth_time(conn) do
    token = conn.assigns[:access_token]

    cond do
      is_binary(token) and not String.contains?(token, ".") ->
        case Nebu.Matrix.Session.MatrixSessionStore.get_auth_context(token) do
          {:ok, %{auth_time: at}} -> at
          :error -> nil
        end

      true ->
        claims = conn.assigns[:oidc_claims] || %{}

        case claims["auth_time"] do
          t when is_integer(t) -> t
          _ -> if is_integer(claims["iat"]), do: claims["iat"], else: nil
        end
    end
  end

  # S3 AC3 per-device teardown: key material + opaque session + bound-JWT kill-switch.
  # Scoped to the OWNING user (the caller must already be confirmed as the owner / the
  # id must not belong to another user). Best-effort and idempotent throughout.
  #
  # TRUE SEMANTICS (single, coherent rule — IDENTICAL for opaque AND raw-JWT sessions):
  # deleting a device revokes that device's session (AC3). The ONLY exception is the
  # live credential MAKING this request: when the device being deleted is the caller's
  # own current device AND `preserve` carries that credential, the request token is
  # spared so it can finish the batch. The preserve covers THE REQUEST, not the device:
  #   * opaque caller — its `matrix_sessions` row (matched by current_device) is NOT
  #     dropped, so the session simply continues (its device row is gone, which opaque
  #     auth does not consult);
  #   * raw-JWT caller — the kill-switch SKIPS the binding row whose token_hash equals
  #     the SHA-256 of the live request token (so it is not denylisted), even though
  #     other JWTs bound to the same device ARE revoked. The device row IS deleted and
  #     the kept binding now points at a missing device, so `DeviceBinding.lookup/1`
  #     REFUSES that JWT on its next request after the node's 60 s lookup-cache TTL
  #     (`401 M_UNKNOWN_TOKEN` "Access token has been revoked", no soft_logout): the
  #     JWT of a caller that deleted its own device lives for this request (and the
  #     cache TTL) only. Deliberate, fail closed (story oauth-legacy-coexistence C13
  #     c; before story 5 the binding row was deleted and the JWT silently became an
  #     unbound credential). The kinds are therefore NOT symmetric after the request.
  # `preserve == nil` (e.g. a single DELETE satisfied by the recent-login window, NOT a
  # fresh re-auth) preserves nothing — the presented token bound to the deleted device
  # stops authenticating, which is what the F-1 kill-switch / AC3 require.
  #
  # `preserve` is `nil` or `{current_device, current_token_hash}` where
  # `current_token_hash` may be `nil` (no resolvable token, e.g. opaque caller — only
  # the device match matters there).
  defp delete_one_device(user, device_id, preserve) do
    {preserve_device, preserve_token_hash} =
      case preserve do
        {dev, hash} -> {dev, hash}
        nil -> {nil, nil}
      end

    if device_id == preserve_device do
      # The caller's OWN device after a fresh UIA (legacy only: an OAuth caller never gets here, C7). Its
      # credential survives by design, so today's per-step code stays: kill the OTHER bound JWTs (the
      # caller's current token hash is neither denylisted nor its binding row deleted), keep the opaque
      # matrix_sessions row of the caller, remove the device identity + all key material.
      _ = Nebu.Matrix.Session.DeviceBinding.kill_device_jwts(user, device_id, except_hash: preserve_token_hash)
      _ = DeviceKeyStore.delete_device(user, device_id)
      :ok
    else
      # Every other device: the atomic, locked teardown (story oauth-legacy-coexistence C12): devices
      # row lock, ALL matrix_sessions rows of the device (so a concurrent OAuth rotation cannot leave a
      # working token behind), device tables, then the confirmed JWT kill-switch (C13) + legacy
      # sessions/sync_tokens rows.
      Nebu.Matrix.end_device_session(user, device_id)
    end
  end

  # The credential MAKING this request, as `{current_device, current_token_hash}` for
  # the symmetric self-delete preserve. `current_device` is the bound device (opaque or
  # raw-JWT, set by OidcPlug). `current_token_hash` is the SHA-256 hex of the live
  # access token (same digest the F-1 kill-switch enumerates and OidcPlug resolves
  # `revoked?` by), or `nil` when no token is resolvable.
  defp caller_credential(conn) do
    token = conn.assigns[:access_token]
    hash = if is_binary(token), do: Nebu.Matrix.Session.DeviceBinding.hash(token), else: nil
    {conn.assigns[:device_id], hash}
  end

  # S2 AC5: throttled, best-effort last_seen refresh for the request's bound device.
  # Only fires when the token carries a bound device (opaque or raw-JWT via the S2
  # binding); the DeviceKeyStore write itself is throttled and never raises.
  defp touch_device_last_seen(conn) do
    case conn.assigns[:device_id] do
      did when is_binary(did) and did != "" ->
        _ = DeviceKeyStore.touch_last_seen(conn.assigns[:current_user], did, Nebu.Web.ClientIP.get(conn))
        :ok

      _ ->
        :ok
    end
  end

  # Lazily bind a raw-JWT access token to the device it publishes keys for, the first
  # time, when no server-side binding exists yet (token has a "." → JWT; no
  # conn.assigns[:device_id]). Opaque sessions already carry their device in
  # matrix_sessions, so they are skipped. Idempotent and best-effort, except that a binding REFUSED because
  # the device has an OAuth session is reported (`{:error, :oauth_device}`, C11).
  defp maybe_bind_jwt_device(conn, user, device_id) do
    token = conn.assigns[:access_token]

    cond do
      is_binary(conn.assigns[:device_id]) and conn.assigns[:device_id] != "" ->
        :ok

      is_binary(token) and String.contains?(token, ".") ->
        # S3 F-1: carry the verified token's exp into the binding so the kill-switch
        # can denylist it on device delete.
        exp = (conn.assigns[:oidc_claims] || %{})["exp"]
        Nebu.Matrix.Session.DeviceBinding.put(token, user, device_id, exp)

      true ->
        :ok
    end
  end

  # Per-request key cap for /keys/upload (DoS bound — see handler comment).
  @max_keys_per_upload 100

  defp oversized?(map) when is_map(map), do: map_size(map) > @max_keys_per_upload
  defp oversized?(_), do: false

  # device_id for /keys/upload (S2 AC4/AC6/G1). The token's server-side bound device
  # (`conn.assigns[:device_id]`, set by OidcPlug for BOTH opaque and raw-JWT sessions) is
  # AUTHORITATIVE — this is what removes the old `sole_device_id/1` heuristic that
  # mis-attributed OTK-only uploads for multi-device users and let a token act as another
  # device. A contradicting body device_id is already rejected up front in the handler
  # (G1), so by the time we get here the body device_id (when present) agrees with the
  # bound device. Order:
  #   1. the token's bound device (the secure, reliable source), else
  #   2. the body device_keys.device_id (first upload on a JWT session minted before the
  #      binding existed — still the device's own claim, never another device's), else
  #   3. nil → nothing to attribute (no-op, no DB write).
  defp upload_device_id(device_keys, conn) do
    cond do
      is_binary(conn.assigns[:device_id]) and conn.assigns[:device_id] != "" ->
        conn.assigns[:device_id]

      is_map(device_keys) and is_binary(device_keys["device_id"]) and device_keys["device_id"] != "" ->
        device_keys["device_id"]

      true ->
        nil
    end
  end

  # ── cross-signing (story: cross-signing-readback) ──────────────────────────

  # device_signing/upload: normalize the keys, MUST-guard the device/cross-signing ID namespace, then
  # persist with first-upload / idempotent / overwrite-protection handling.
  defp do_device_signing_upload(conn) do
    user = conn.assigns[:current_user]

    # story oauth-authorize-freshness (FR16 (1), gate ak): the supplied keys are normalized FIRST, for EVERY
    # caller and BEFORE the guard, the digest and the merge: an explicit JSON `null` key is an absent key; a
    # key that is not a JSON object (a string, a list, a number, a boolean) is `400 M_BAD_JSON`.
    case normalize_cross_signing_body(body_params(conn)) do
      {:ok, body} ->
        # AC6 MUST-GUARD FIRST, before any write: a cross-signing key whose ID collides
        # with an existing device ID is rejected (shared ed25519: namespace, CS spec).
        existing_device_ids = MapSet.new(DeviceKeyStore.device_ids(user))
        upload_key_ids = CrossSigningKeyStore.key_ids_in_upload(body)

        cond do
          Enum.any?(upload_key_ids, &MapSet.member?(existing_device_ids, &1)) ->
            error(conn, 400, "M_INVALID_PARAM", "Key ID in use as a device ID")

          true ->
            do_persist_cross_signing(conn, user, body)
        end

      :invalid ->
        error(conn, 400, "M_BAD_JSON", "Invalid cross-signing key")
    end
  end

  # `{:ok, body}` where each of the three keys is either an object or ABSENT (`null` dropped), `:invalid` when
  # one is anything else. Every other member of the body (`auth`) is kept.
  defp normalize_cross_signing_body(body) do
    Enum.reduce_while(["master_key", "self_signing_key", "user_signing_key"], {:ok, body}, fn key, {:ok, acc} ->
      case Map.get(acc, key) do
        nil -> {:cont, {:ok, Map.delete(acc, key)}}
        %{} -> {:cont, {:ok, acc}}
        _not_an_object -> {:halt, :invalid}
      end
    end)
  end

  defp do_persist_cross_signing(conn, user, body) do
    supplied = Map.take(body, ["master_key", "self_signing_key", "user_signing_key"])

    # Review cycle 1 (M2 / Kassandra L-4): the branch decision (first upload = UIA-free!) reads the stored keys
    # with the ERROR-AWARE locked read inside a transaction; the first upload is written in the same
    # transaction. A failed read is a `500`, never "no master stored" (the error-blind `get_keys/1` answered an
    # outage with the UIA-free first-upload branch and a write of the supplied keys).
    #
    # story cross-signing-upload-races (`cq` (g), D2): the decision read is `CrossSigningKeyStore.lock_keys/1`: the
    # cross_signing_keys row lock, then the per-user `sync_global|` advisory lock, then the read (row -> advisory -> read).
    # The row of a user without keys locks nothing, so the ADVISORY lock serialises two concurrent first uploads: the
    # second one reads the keys the first one committed and answers like any upload against stored keys (200 for
    # identical keys, otherwise the replacement answer), never a second UIA-free first upload.
    outcome =
      try do
        Nebu.Repo.transaction(fn ->
          case CrossSigningKeyStore.lock_keys(user) do
            {:ok, %{"master_key" => nil}} ->
              case CrossSigningKeyStore.put_keys(user, supplied) do
                :ok ->
                  :first_upload

                {:error, :user_erased} ->
                  Nebu.Repo.rollback(:user_erased)

                {:error, reason} ->
                  # the error KIND only, never key material or an error message
                  Logger.error("cross-signing key write failed: #{error_kind(reason)}")
                  Nebu.Repo.rollback(:write_failed)
              end

            {:ok, stored} ->
              {:stored, stored}

            {:error, _reason} ->
              Nebu.Repo.rollback(:read_failed)
          end
        end)
      rescue
        e ->
          Logger.error("cross-signing key read failed: #{inspect(e.__struct__)}")
          {:error, :read_failed}
      end

    case outcome do
      # AC2: first upload (no existing master key) → persisted, plain 200 {} (no UIA).
      # INFO-1: the first-upload gate is keyed on master_key presence — real clients
      # always upload the master key first, so its absence reliably means "no keys yet".
      {:ok, :first_upload} ->
        send_json(conn, 200, %{})

      {:error, :user_erased} ->
        Logger.info("cross-signing key upload refused: user_erased")
        user_erased(conn)

      {:error, _} ->
        error(conn, 500, "M_UNKNOWN", "Cross-signing key upload failed, please try again.")

      {:ok, {:stored, stored}} ->
        cond do
          # story oauth-authorize-freshness (FR16 (1), oracle correction 9): a body that supplies NO key (`{}`, or
          # every key `null`) while a master is stored is `400 M_MISSING_PARAM` for EVERY caller, without UIA and
          # before any approval is looked at (a Nebu choice: the legacy answer was 403, the OAuth answer a challenge
          # for nothing).
          map_size(supplied) == 0 ->
            error(conn, 400, "M_MISSING_PARAM", "No cross-signing keys supplied")

          # AC2: idempotent re-upload of the SAME keys → 200 {} (no UIA), also with an `auth` block and
          # BEFORE the approval is looked at (a lost-response retry of an approved request is a 200 that
          # consumes nothing). Compares the SUPPLIED keys only, after normalization.
          cross_signing_unchanged?(stored, supplied) ->
            send_json(conn, 200, %{})

          # REPLACEMENT of existing keys. Decided by the `:auth_api` assign set at AUTHENTICATION time by
          # OidcPlug (story oauth-token-revocation-logout Trap 4), never by a token lookup here.
          #
          # story oauth-account-management (A14): an OAuth caller gets the `m.oauth` UIA stage (approval on
          # the account page); a LEGACY caller keeps the minimal `403 M_FORBIDDEN` byte for byte (a known,
          # unchanged deviation: the spec asks for a UIA challenge, docs/matrix-api-scope.md).
          conn.assigns[:auth_api] == "oauth" ->
            oauth_cross_signing_replacement(conn, user, body, supplied)

          true ->
            cannot_replace_cross_signing_keys(conn)
        end
    end
  end

  defp cannot_replace_cross_signing_keys(conn),
    do: error(conn, 403, "M_FORBIDDEN", "Cannot replace existing cross-signing keys")

  # Spec v1.18 (`POST /keys/device_signing/upload`): a request whose `master_key` equals the stored one
  # AND whose additionally SUPPLIED self-/user-signing keys equal the stored ones needs no UIA; keys
  # that are not supplied are not compared. A request WITHOUT `master_key` while a master is stored
  # (e.g. SSK-only) is a replacement. (story oauth-account-management A14 step 3: the earlier rule
  # compared all three keys, so a master-only re-upload was answered 403.)
  defp cross_signing_unchanged?(stored, supplied) do
    case supplied["master_key"] do
      nil ->
        false

      master ->
        master == stored["master_key"] and
          Enum.all?(["self_signing_key", "user_signing_key"], fn k ->
            is_nil(supplied[k]) or supplied[k] == stored[k]
          end)
    end
  end

  # ── m.oauth UIA for the replacement of cross-signing keys (story oauth-account-management, A14) ──

  defp oauth_cross_signing_replacement(conn, user, body, supplied) do
    case Nebu.OAuth.cross_signing_reset_url() do
      {:ok, url} ->
        # the approval is bound to the requesting device AND to ALL supplied (normalized) keys (A14)
        device_id = to_string(conn.assigns[:device_id] || "")
        params = Nebu.Matrix.Uia.reset_params(device_id, keys_digest(supplied))

        case approved_session(body) do
          nil -> m_oauth_challenge(conn, user, device_id, url, params)
          session_id -> replace_with_approval(conn, user, device_id, url, params, session_id, supplied)
        end

      # OAuth is not live (A3): never a challenge pointing at a dead page — the legacy answer
      :unavailable ->
        cannot_replace_cross_signing_keys(conn)
    end
  end

  # `auth.session` (a binary) with `auth.type` absent, `m.oauth` or `org.matrix.cross_signing_reset`
  # (Element sends `{type: "m.oauth", session}`); any other type (e.g. `m.login.sso`) and any malformed
  # `auth` is a plain re-challenge.
  defp approved_session(%{"auth" => %{"session" => session} = auth}) when is_binary(session) and session != "" do
    if Map.get(auth, "type") in [nil, "m.oauth", "org.matrix.cross_signing_reset"], do: session
  end

  defp approved_session(_body), do: nil

  # ONE transaction: the atomic single-use consume of the approval AND the key write. A failed key
  # write rolls the consume back (the approval is not burned) => 500.
  #
  # story oauth-authorize-freshness (FR16 (2), gate ak): the merge base is read INSIDE the transaction, AFTER
  # the consume, with the locked read `CrossSigningKeyStore.lock_keys/1` (story cross-signing-upload-races D3, the
  # order: uia_sessions row (consume) -> cross_signing_keys row -> sync_global| advisory lock -> read), so a concurrent writer
  # cannot slip a stale base in between (review cycle 1, Kassandra F-2 kept: a PARTIAL replacement keeps the
  # stored keys that were not supplied, because `put_keys/2` upserts all three columns and an absent one
  # would wipe it and reopen the UIA-free first-upload branch). A failing locked read is an ERROR (never an
  # all-nil "no master stored"): the transaction rolls back (the approval is not consumed) => 500.
  defp replace_with_approval(conn, user, device_id, url, params, session_id, supplied) do
    result =
      try do
        Nebu.Repo.transaction(fn ->
          case Nebu.Matrix.Uia.consume(session_id, user, "cross_signing_reset", params) do
            :ok ->
              case CrossSigningKeyStore.lock_keys(user) do
                {:ok, current} ->
                  keys = Map.merge(Map.take(current, ["master_key", "self_signing_key", "user_signing_key"]), supplied)
                  case CrossSigningKeyStore.put_keys(user, keys) do
                    :ok ->
                      :ok

                    {:error, :user_erased} ->
                      Nebu.Repo.rollback(:user_erased)

                    {:error, reason} ->
                      # the error KIND only, never key material or an error message
                      Logger.error("m.oauth cross-signing key write failed: #{error_kind(reason)}")
                      Nebu.Repo.rollback(:write_failed)
                  end

                {:error, _reason} ->
                  Nebu.Repo.rollback(:read_failed)
              end

            :error ->
              Nebu.Repo.rollback(:not_approved)
          end
        end)
      rescue
        e ->
          Logger.error("m.oauth cross-signing replacement failed: #{inspect(e.__struct__)}")
          {:error, :write_failed}
      end

    case result do
      {:ok, :ok} -> send_json(conn, 200, %{})
      {:error, :not_approved} -> m_oauth_challenge(conn, user, device_id, url, params)

      {:error, :user_erased} ->
        Logger.info("m.oauth cross-signing key replacement refused: user_erased")
        user_erased(conn)

      {:error, _} -> error(conn, 500, "M_UNKNOWN", "Cross-signing key upload failed, please try again.")
    end
  end

  # The 401 challenge: the caller's still-PENDING session for the same `(user, params)` is reused
  # (Element's `makeRequest(null)` + dialog request, and a retry before approval, get the SAME id),
  # else a new one is minted with a CHECKED insert; one pending request per `(user, device)` and a cap
  # per user (`Uia.open_reset_request/3`, serialized). No `errcode` / `error` / `completed` (Element
  # would enter its error state).
  defp m_oauth_challenge(conn, user, device_id, url, params) do
    case Nebu.Matrix.Uia.open_reset_request(user, device_id, params) do
      {:ok, session_id} ->
        send_json(conn, 401, %{
          "flows" => [%{"stages" => ["m.oauth"]}],
          "params" => %{"m.oauth" => %{"url" => url}},
          "session" => session_id
        })

      :error ->
        error(conn, 500, "M_UNKNOWN", "Cross-signing key upload failed, please try again.")
    end
  end

  defp keys_digest(supplied), do: Nebu.Matrix.CanonicalJson.sha256_hex(supplied)

  # signatures/upload: merge each supplied signature into the targeted stored key
  # object (device key or cross-signing key); build a per-(user,key) failures map.
  defp do_signatures_upload(conn) do
    body = body_params(conn)
    caller = conn.assigns[:current_user]

    failures =
      Enum.reduce(body, %{}, fn {user_id, keyed}, acc ->
        merge_user_signatures(caller, user_id, keyed, acc)
      end)

    send_json(conn, 200, %{"failures" => failures})
  end

  # MINOR-1: a user may only upload signatures attached to their OWN keys in this
  # story scope (cross-user signing is out of scope per the story guardrail). For a
  # body keyed under another user, mark every one of that user's keys M_FORBIDDEN
  # and touch NO storage.
  defp merge_user_signatures(caller, user_id, keyed, acc)
       when is_map(keyed) and user_id != caller do
    Enum.reduce(keyed, acc, fn {key_id, _signed_object}, inner ->
      put_forbidden_failure(inner, user_id, key_id)
    end)
  end

  defp merge_user_signatures(_caller, user_id, keyed, acc) when is_map(keyed) do
    Enum.reduce(keyed, acc, fn {key_id, signed_object}, inner ->
      case merge_one_signature(user_id, key_id, signed_object) do
        :ok -> inner
        :invalid -> put_signature_failure(inner, user_id, key_id)
      end
    end)
  end

  defp merge_user_signatures(_caller, _user_id, _keyed, acc), do: acc

  # The signed_object MUST match the stored key object for that key_id EXCEPT its
  # `signatures` (which carries the new sigs to merge). Try device key first, then
  # cross-signing key. Both paths are validate-THEN-persist: a mismatch (or no
  # stored key) writes NOTHING.
  #
  # story cross-signing-upload-races (code review MINOR-1, Kassandra F-1): the SHAPE of `signatures` is validated first.
  # `signatures` must be a map (an absent one is an empty map) whose every per-signer value is a map; anything else
  # (null, a string, a list, a non-map per-signer value) is a failure entry in the 200, never a crash: the stores guard
  # on maps, and a crash report would carry the call arguments (key id, submitted object) into the error log.
  defp merge_one_signature(user_id, key_id, signed_object) when is_map(signed_object) do
    new_sigs = Map.get(signed_object, "signatures", %{})

    if valid_signatures_shape?(new_sigs) do
      case merge_device_key_signature(user_id, key_id, signed_object, new_sigs) do
        :ok ->
          :ok

        :not_found ->
          merge_cross_signing_signature(user_id, key_id, signed_object, new_sigs)

        :mismatch ->
          :invalid
      end
    else
      :invalid
    end
  end

  defp merge_one_signature(_user_id, _key_id, _signed_object), do: :invalid

  defp valid_signatures_shape?(sigs) when is_map(sigs), do: Enum.all?(sigs, fn {_signer, per_signer} -> is_map(per_signer) end)
  defp valid_signatures_shape?(_sigs), do: false

  # A device-key signature merge. Returns :ok | :not_found | :mismatch.
  defp merge_device_key_signature(user_id, key_id, signed_object, new_sigs) do
    case DeviceKeyStore.query_devices([user_id]) do
      %{^user_id => devices} ->
        case Map.get(devices, key_id) do
          nil ->
            :not_found

          stored ->
            stored_clean = stored |> Map.delete("signatures") |> Map.delete("unsigned")
            # MINOR-2: drop `unsigned` from the submitted object too, so a client that
            # includes `unsigned` does not falsely mismatch (symmetric with stored_clean).
            submitted_clean = signed_object |> Map.delete("signatures") |> Map.delete("unsigned")

            if stored_clean == submitted_clean do
              merged_sigs = deep_merge_sig_map(Map.get(stored, "signatures", %{}), new_sigs)
              # Persist the device key with merged signatures (drop the read-only `unsigned`).
              to_store =
                stored
                |> Map.delete("unsigned")
                |> Map.put("signatures", merged_sigs)

              DeviceKeyStore.put_device_keys(user_id, key_id, to_store)
              :ok
            else
              :mismatch
            end
        end

      _ ->
        :not_found
    end
  end

  # MAJOR-1: a cross-signing signature merge, mirroring the device-key path: validate FIRST, persist ONLY on a
  # match (the parts other than `signatures` / `unsigned` of the stored and the submitted object are equal). Returns
  # :ok | :invalid.
  #
  # story cross-signing-upload-races (D4, D5, D-A1): the check and the write run in ONE transaction under the per-user
  # lock, in the store (`CrossSigningKeyStore.merge_signatures/4`: `lock_keys/1`, the key found by its id in that read,
  # the object comparison against the LOCKED object, the merge, all three columns written from that read). There is
  # deliberately no unlocked pre-check here: an error-blind early read would turn a failed read into a failure entry of
  # a 200, while the locked read lets a failed read crash the request (500), like a failed write. `:not_found` (-> a
  # failure entry): no such cross-signing key, a different object under the same key id, or an erased user; nothing is
  # stored then.
  defp merge_cross_signing_signature(user_id, key_id, signed_object, new_sigs) do
    case CrossSigningKeyStore.merge_signatures(user_id, key_id, new_sigs, signed_object) do
      :ok -> :ok
      :not_found -> :invalid
    end
  end

  # story cross-signing-upload-races (fix cycle 2, Kassandra D-1): the STORED device-key `signatures` may be malformed (the key upload does
  # not validate their shape). A stored value or a stored per-signer value that is not a map counts as no signatures (dropped), so the
  # merge never crashes (the crash report would log the submitted signatures) and the result is always a map of maps.
  defp deep_merge_sig_map(existing, new) do
    Map.merge(sig_map(existing), sig_map(new), fn _signer, old_map, new_map -> Map.merge(old_map, new_map) end)
  end

  defp sig_map(sigs) when is_map(sigs), do: for({signer, per_signer} <- sigs, is_map(per_signer), into: %{}, do: {signer, per_signer})
  defp sig_map(_sigs), do: %{}

  defp put_signature_failure(failures, user_id, key_id) do
    entry = %{"errcode" => "M_INVALID_SIGNATURE", "error" => "Signature does not match stored key"}
    Map.update(failures, user_id, %{key_id => entry}, &Map.put(&1, key_id, entry))
  end

  # MINOR-1: caller-identity guard failure — uploading signatures for another user.
  defp put_forbidden_failure(failures, user_id, key_id) do
    entry = %{"errcode" => "M_FORBIDDEN", "error" => "Cannot upload signatures for another user"}
    Map.update(failures, user_id, %{key_id => entry}, &Map.put(&1, key_id, entry))
  end

  # Builds a /keys/query cross-signing map (master_keys/self_signing_keys/user_signing_keys)
  # from CrossSigningKeyStore.query_cross_signing/1 output, selecting the given short key.
  defp collect_cross_signing(cross_signing, short_key) do
    Enum.reduce(cross_signing, %{}, fn {uid, entry}, acc ->
      case Map.get(entry, short_key) do
        nil -> acc
        obj -> Map.put(acc, uid, obj)
      end
    end)
  end

  # Resolves a /keys/query `device_keys` request (`%{user_id => [device_ids]}`) against
  # the directory. An empty device list selects all of that user's devices (per spec);
  # users/devices with no published keys are omitted (no `failures` entry).
  defp query_device_keys(requested) do
    all = DeviceKeyStore.query_devices(Map.keys(requested))

    Enum.reduce(requested, %{}, fn {user_id, device_list}, acc ->
      case Map.get(all, user_id) do
        nil ->
          acc

        devices ->
          selected =
            case device_list do
              list when is_list(list) and list != [] -> Map.take(devices, list)
              _ -> devices
            end

          if map_size(selected) > 0, do: Map.put(acc, user_id, selected), else: acc
      end
    end)
  end

  # Story history-visibility-enforcement (security cycle 1, HIGH #1 (b)): the PUT of m.room.history_visibility,
  # m.room.guest_access and m.room.join_rules is charged like the power levels (the access settings of a room; the history
  # visibility events are the cost input of every member's reads, follow-up `gk`).
  @moderation_state_types ~w(m.room.power_levels m.room.history_visibility m.room.guest_access m.room.join_rules)

  # Story power-levels-enforcement (D9): a PUT of m.room.power_levels costs ONE `moderation` token, charged FIRST (before the
  # body checks, like `/kick`): power-level changes and moderation are the same actors and the same abuse class. A labelled
  # divergence from the spec's "Rate-limited: No"; the three access types below are charged the same way, every other state
  # type stays uncharged (follow-up `fp`).
  defp do_set_room_state(conn, raw_room, raw_event_type, raw_state_key) do
    if URI.decode_www_form(raw_event_type) in @moderation_state_types do
      with_membership_charge(conn, [moderation_bucket(conn.assigns[:current_user])], fn ->
        set_room_state_request(conn, raw_room, raw_event_type, raw_state_key)
      end)
    else
      set_room_state_request(conn, raw_room, raw_event_type, raw_state_key)
    end
  end

  defp set_room_state_request(conn, raw_room, raw_event_type, raw_state_key) do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(raw_room)
    event_type = URI.decode_www_form(raw_event_type)
    state_key = URI.decode_www_form(raw_state_key)
    key_check = Nebu.Matrix.EventSize.check_keys(event_type, state_key, user)

    cond do
      # E2EE guardrail (ADR-011 managed-decryption model): a room must never flip to
      # client-side end-to-end encryption, or the server could no longer read its content.
      # Enabling E2EE is done solely by sending an m.room.encryption state event (CS §E2E),
      # so we reject that event type outright. The device-key directory stays fully
      # functional — it is orthogonal to encryption.
      event_type == "m.room.encryption" ->
        error(conn, 403, "M_FORBIDDEN", "End-to-end encryption is not supported on this server")

      conn.assigns[:json_parse_error] == true ->
        error(conn, 400, "M_BAD_JSON", "Request body is not valid JSON")

      # story power-levels-enforcement (D3): the levels content must be an object (valid JSON that is not one is wrapped by
      # Plug.Parsers as %{"_json" => value}, the ONLY key; review cycle 0 I1: an object that merely has a "_json" key among
      # others is a content like any other); the other state types keep their behaviour
      event_type == "m.room.power_levels" and non_object_body?(body_params(conn)) ->
        error(conn, 400, "M_BAD_JSON", "Request body must be a JSON object")

      # a NUL in a path-derived identifier (room id, event type, state key) is not storable either: 400, not a 500
      Nebu.Matrix.EventDispatcher.Server.contains_nul?([room, event_type, state_key]) ->
        error(conn, 400, "M_BAD_JSON", "Path parameters must not contain NUL characters")

      # a percent-encoded path value that is not UTF-8 (`%FF`) cannot be stored or encoded as JSON: 400, never a 500 from the size pre-check
      not path_values_utf8?([room, event_type, state_key]) ->
        error(conn, 400, "M_BAD_JSON", "Path parameters must be valid UTF-8")

      # Story event-size-limit (D4): `type` / `state_key` above 255 BYTES (decoded, the stored value) are a 413, before the depth
      # check, the room lookup and the type allowlist (nothing about the room is revealed, no statement runs). The authenticated
      # sender above 255 bytes (a session of before the user ids were bounded) is a 403.
      key_check != :ok ->
        key_error(conn, key_check)

      # Story create-room-input-validation (D5a/d): bounded descent BEFORE anything recursive walks the body (the
      # NUL scan, CanonicalJson), then a NUL anywhere (keys or values) is a 400 here, not a 500 from the failing insert.
      Nebu.Matrix.EventDispatcher.Server.content_too_deep?(body_params(conn)) ->
        error(conn, 400, "M_BAD_JSON", "State event content is nested too deeply")

      Nebu.Matrix.EventDispatcher.Server.contains_nul?(body_params(conn)) ->
        error(conn, 400, "M_BAD_JSON", "State event content must not contain NUL characters")

      true ->
        # body is the raw content object; re-encode to JSON for the request struct (once: the size check reuses these bytes).
        content_json = Jason.encode!(body_params(conn))

        # Story event-size-limit (D4): the complete signed event above 65 536 canonical bytes is a 413, still before the room lookup
        # (an unknown room id gets no rooms row). EventDispatcher.Server.emit_state_event_at/6 re-checks the signed bytes.
        envelope = Nebu.Matrix.EventSize.envelope(room, user, event_type, state_key, Nebu.DB.Helpers.now_ms())

        case Nebu.Matrix.EventSize.check(envelope, byte_size(content_json)) do
          {:error, :event_too_large} ->
            error(conn, 413, "M_TOO_LARGE", Nebu.Matrix.EventSize.message(:event_too_large))

          :ok ->
            req = %Core.SetRoomStateRequest{
              room_id: room,
              sender_id: user,
              event_type: event_type,
              state_key: state_key,
              content_json: content_json
            }

            case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.set_room_state(req, stream(user)) end) do
              {:ok, resp} -> send_json(conn, 200, %{"event_id" => resp.event_id})
              {:error, err} -> send_error(conn, err)
            end
        end
    end
  end

  defp path_values_utf8?(values), do: Enum.all?(values, &String.valid?/1)

  # Plug.Parsers wraps a JSON body that is not an object as %{"_json" => value} (its only key). Known limitation (review cycle 0 I1):
  # an OBJECT body whose only key is "_json" cannot be told apart and is refused too (no levels content consists of that key alone)
  defp non_object_body?(params), do: map_size(params) == 1 and Map.has_key?(params, "_json")

  # Story event-size-limit (D2): the refusals of Nebu.Matrix.EventSize.check_keys/3. A `type` / `state_key` above 255 bytes is a
  # 413 M_TOO_LARGE with a fixed text; a sender above 255 bytes cannot be fixed by changing the request: 403 M_FORBIDDEN.
  defp key_error(conn, {:error, reason}), do: key_error(conn, reason)

  defp key_error(conn, :sender_too_long),
    do: error(conn, 403, "M_FORBIDDEN", Nebu.Matrix.EventSize.message(:sender_too_long))

  defp key_error(conn, reason) when reason in [:type_too_long, :state_key_too_long],
    do: error(conn, 413, "M_TOO_LARGE", Nebu.Matrix.EventSize.message(reason))

  defp update_profile_field(conn, raw_user_id, field) do
    user = conn.assigns[:current_user]
    path_user_id = URI.decode_www_form(raw_user_id)

    if path_user_id != user do
      error(conn, 403, "M_FORBIDDEN", "You can only update your own profile")
    else
      params = body_params(conn)

      {displayname, avatar_url} =
        case field do
          :displayname -> {params["displayname"], nil}
          :avatar_url -> {nil, params["avatar_url"]}
        end

      req = %Core.UpdateProfileRequest{
        user_id: user,
        displayname: displayname || "",
        avatar_url: avatar_url || ""
      }

      case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.update_profile(req, stream(user)) end) do
        {:ok, _resp} -> send_json(conn, 200, %{})
        {:error, err} -> send_error(conn, err)
      end
    end
  end

  # body_params is set by the top-level Plug.Parsers. For a missing/empty body it
  # is an empty map (parser `pass: ["*/*"]`); normalise the unfetched case too.
  defp body_params(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> %{}
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  # Capped at 25_000ms (not 30_000ms) to leave headroom against upstream proxy
  # timeouts (Stackit ALB backend timeout is typically 60s; 25s hold + overhead
  # stays comfortably within that window). Promoted to `def` for unit testability.
  @doc false
  def parse_timeout(nil), do: 0

  @doc false
  def parse_timeout(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {v, _} -> v |> max(0) |> min(25_000)
      :error -> 0
    end
  end

  defp parse_limit(nil), do: {:ok, 10}

  defp parse_limit(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {v, ""} -> {:ok, v |> max(1) |> min(100)}
      _ -> :error
    end
  end
end
