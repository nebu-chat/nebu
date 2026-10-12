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

  plug Nebu.Web.Plugs.OidcPlug
  plug :fetch_query_params
  plug :match
  plug :dispatch

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

    # room-account-data-and-read-markers: Nebu's `next_batch`/`since` token is
    # `<core token>[.<room account data position>]`. The core token (opaque base64, no
    # '.') keeps its existing per-user stored-token semantics; the suffix is the
    # `stream_pos` up to which this client has received ROOM account data (per DEVICE,
    # because it lives in the client's own token). A token without a suffix (issued
    # before this feature) means position 0 = "all room account data" (delivered once).
    {core_since, since_pos} = split_since_token(since)
    has_since? = is_binary(core_since) and core_since != ""

    # S2 AC5: advance the device's last_seen_ts/last_seen_ip on this authenticated
    # activity, THROTTLED inside the store so back-to-back /syncs don't hammer the DB.
    # Best-effort: must never fail the /sync it rides on.
    touch_device_last_seen(conn)

    # Room account data already waiting for this token → do not long-poll.
    timeout_ms =
      if has_since? and Nebu.Matrix.RoomAccountDataStore.pending?(user, since_pos),
        do: 0,
        else: timeout_ms

    {next_batch, rooms, fallback?} =
      if has_since? do
        delta =
          Nebu.Matrix.EventDispatcher.Server.get_sync_delta(
            %Core.GetSyncDeltaRequest{
              user_id: user,
              since_token: core_since,
              timeout_ms: timeout_ms,
              device_id: ""
            },
            stream(user)
          )

        # get_sync_delta already returns the fully-resolved checkpoint: on an
        # unknown/stale since_token it transparently falls back to an initial
        # sync and sets delta.fallback_to_initial: true while putting the full
        # snapshot in delta.rooms and a fresh delta.since_token. The HTTP /sync
        # response shape is identical in both cases (next_batch + joined rooms).
        {delta.since_token, delta.rooms, delta.fallback_to_initial}
      else
        initial =
          Nebu.Matrix.EventDispatcher.Server.get_initial_sync(
            %Core.GetInitialSyncRequest{user_id: user},
            stream(user)
          )

        {initial.since_token, initial.rooms, true}
      end

    # Rooms the user newly joined in this delta: the client has never seen their
    # account data, so deliver ALL of it (not only changes after the position).
    full_rooms = if has_since? and not fallback?, do: newly_joined_room_ids(rooms, user), else: []

    {latest_pos, ad_entries} =
      Nebu.Matrix.RoomAccountDataStore.list_for_sync(user, since_pos, full_rooms)

    # A room whose ONLY change is account data must still appear in rooms.join
    # (empty timeline/state). Only for true deltas — initial/fallback already carry
    # every joined room.
    present = MapSet.new(rooms, & &1.room_id)

    extra_rooms =
      if has_since? and not fallback? do
        ad_entries
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(present, &1))
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
      sync_response(next_batch <> "." <> Integer.to_string(latest_pos), rooms ++ extra_rooms, room_ad)
      |> put_device_e2e_counts(conn)
      |> put_cross_signing_device_lists(conn, core_since)
      |> put_global_account_data(conn, core_since)

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

  defp newly_joined_room_ids(rooms, user) do
    for room <- rooms,
        Enum.any?(room.timeline_events, fn ev ->
          ev.event_type == "m.room.member" and ev.state_key == user and
            match?({:ok, %{"membership" => "join"}}, Jason.decode(ev.content))
        end),
        do: room.room_id
  end

  # Top-level `account_data.events` (Matrix CS §GET /sync). Global account data is
  # durable (PostgreSQL, story account-data-durability) so Element's secret-storage /
  # recovery material survives restarts and is delivered to the client. Initial sync
  # (no `since`) delivers ALL of the user's global account data; incremental sync
  # (`since` present) delivers ONLY entries changed since the prior sync — the store
  # uses a consume-once `changed` flag, read-and-cleared atomically. Each entry is
  # `{type, content}`; content is opaque (ADR-011 — never parsed/decrypted here).
  defp put_global_account_data(response, conn, since) do
    user = conn.assigns[:current_user]

    entries =
      if is_binary(since) and since != "" do
        Nebu.Matrix.AccountDataStore.list_changed_and_clear(user)
      else
        Nebu.Matrix.AccountDataStore.list_all_and_clear(user)
      end

    events = Enum.map(entries, fn {type, content} -> %{"type" => type, "content" => content} end)
    Map.put(response, "account_data", %{"events" => events})
  end

  # AC5: after a cross-signing key change, the uploading user's OWN id must appear in
  # device_lists.changed of their next INCREMENTAL /sync (CS §Cross-signing). The store
  # carries a consume-once `cross_signing_changed` flag per user; an incremental sync
  # reads-and-clears it (atomic UPDATE ... RETURNING, cluster-correct) and surfaces the
  # user once. Initial sync (no since) does not consume the flag.
  defp put_cross_signing_device_lists(response, conn, since) do
    if is_binary(since) and since != "" do
      user = conn.assigns[:current_user]

      if CrossSigningKeyStore.consume_changed_flag(user) do
        update_in(response, ["device_lists", "changed"], fn changed ->
          Enum.uniq([user | changed || []])
        end)
      else
        response
      end
    else
      response
    end
  end

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
  post "/client/v3/logout" do
    user = conn.assigns[:current_user]

    # F-1: revoke the access token so it cannot be reused. OidcPlug returns the
    # verified OIDC token verbatim as the access_token, so destroying the session
    # GenServer alone does NOT stop the token from re-validating on the next
    # request. We add the presented token to the denylist (keyed by jti or token
    # hash) until its own `exp`, mirroring the Go gateway's logout → Invalidate
    # path. OidcPlug then rejects it with 401 M_UNKNOWN_TOKEN. Best-effort: a
    # missing token/exp just means nothing to revoke (still returns 200 {}).
    revoke_access_token(conn)

    req = %Core.InvalidateUserSessionsRequest{user_id: user, device_id: ""}

    case call_core(fn ->
           Nebu.Matrix.EventDispatcher.Server.invalidate_user_sessions(req, stream(user))
         end) do
      # Logout is best-effort (mirrors Go: a cleanup failure still returns 200 {}).
      _ -> send_json(conn, 200, %{})
    end
  end

  defp revoke_access_token(conn) do
    token = conn.assigns[:access_token]
    claims = conn.assigns[:oidc_claims] || %{}

    cond do
      # oidc-session-refresh: an opaque Nebu session token (no JWT dots) is hard-
      # revoked by deleting its matrix_sessions row, so neither the AT nor its RT
      # can be reused after logout. JWTs have no row here and take the denylist path.
      is_binary(token) and not String.contains?(token, ".") ->
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
        "m.room_versions" => %{
          "default" => "10",
          "available" => Map.new(~w(1 2 3 4 5 6 7 8 9 10 11), &{&1, "stable"})
        },
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
            maybe_bind_jwt_device(conn, user, device_id)

            if is_map(device_keys), do: DeviceKeyStore.put_device_keys(user, device_id, device_keys)
            if is_map(one_time_keys), do: DeviceKeyStore.store_one_time_keys(user, device_id, one_time_keys)
            if is_map(fallback_keys), do: DeviceKeyStore.store_fallback_keys(user, device_id, fallback_keys)

            send_json(conn, 200, %{"one_time_key_counts" => DeviceKeyStore.otk_counts(user, device_id)})
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
  delete "/client/v3/devices/:device_id" do
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
        delete_one_device(user, did, preserve)
        send_json(conn, 200, %{})
      end)
    end
  end

  # POST /delete_devices — bulk delete (S3 AC4). Same UIA gate as DELETE, challenged
  # once for the whole batch. The "devices" key is required (missing → 400). Each id
  # is scoped to the caller: a foreign device_id in the array is silently skipped (no
  # cross-user delete — G3). Empty array → 200 {} no-op (still gated, but a fresh
  # session satisfies it). Idempotent → 200 {}.
  post "/client/v3/delete_devices" do
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

          for id <- ids do
            unless DeviceKeyStore.belongs_to_other_user?(user, id),
              do: delete_one_device(user, id, preserve)
          end

          send_json(conn, 200, %{})
        end)
    end
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
            Nebu.Matrix.AccountDataStore.put(user_id, type, Jason.encode!(body_params(conn)))
            send_json(conn, 200, %{})
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
    # back to its Space, restricted m.room.join_rules, m.room.encryption).
    # Carried as JSON so create_room can replay each entry through the signed,
    # persisted state-event path.
    # Bound the per-request sign+insert+pg-fanout cost of replaying initial_state
    # (createRoom has no rate limit): cap the array length. 64 comfortably exceeds
    # what real Matrix clients send (Element sends ~5) while preventing a single
    # ~1 MB body from packing tens of thousands of state events.
    initial_state = params["initial_state"]

    if is_list(initial_state) and length(initial_state) > 64 do
      error(conn, 400, "M_INVALID_PARAM", "initial_state must not exceed 64 events")
    else
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
        initial_state_json: initial_state_json
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

    req = %Core.JoinRoomRequest{user_id: user, room_id_or_alias: room}

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.join_room(req, stream(user)) end) do
      {:ok, resp} -> send_json(conn, 200, %{"room_id" => resp.room_id})
      {:error, err} -> send_error(conn, err)
    end
  end

  # ── POST /_matrix/client/v3/rooms/{roomId}/invite ─────────────────────────
  # Standard Matrix CS invite. The backend (EventDispatcher.Server.invite_user) already
  # exists and is reachable over the in-process gRPC layer; only the HTTP route was
  # missing. Body: {"user_id": "@invitee:server"}. Inviter is the authenticated user.
  post "/client/v3/rooms/:room_id/invite" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)
    params = body_params(conn)

    req = %Core.InviteUserRequest{
      room_id: room,
      inviter_id: user,
      invitee_id: params["user_id"]
    }

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.invite_user(req, stream(user)) end) do
      {:ok, _resp} -> send_json(conn, 200, %{})
      {:error, err} -> send_error(conn, err)
    end
  end

  # ── PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId} ─────────
  put "/client/v3/rooms/:room_id/send/:event_type/:txn_id" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)

    # Parity fix (regression gate, matrix-api-migration): a malformed JSON body
    # must return 400 M_BAD_JSON, mirroring the typing handler above and matching
    # the Go gateway. Nebu.Web.Plugs.JsonBody assigns :json_parse_error on a body
    # that fails to parse; without this guard body_params/1 maps it to %{} and we
    # would silently send an empty-content event (200).
    if conn.assigns[:json_parse_error] == true do
      error(conn, 400, "M_BAD_JSON", "Request body is not valid JSON")
    else
      content = body_params(conn)

      req = %Core.SendEventRequest{
        room_id: room,
        sender_id: user,
        event_type: event_type,
        txn_id: txn_id,
        content: Jason.encode!(content),
        is_state_event: false
      }

      case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.send_event(req, stream(user)) end) do
        {:ok, resp} -> send_json(conn, 200, %{"event_id" => resp.event_id})
        {:error, err} -> send_error(conn, err)
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
  get "/client/v3/rooms/:room_id/initialSync" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)

    state_req = %Core.GetRoomStateRequest{room_id: room, event_type: "", state_key: ""}
    msg_req = %Core.GetMessagesRequest{room_id: room, from_token: "", to_token: nil, limit: 20, direction: "b"}

    with {:ok, state_resp} <-
           call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_room_state(state_req, stream(user)) end),
         {:ok, msg_resp} <-
           call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_messages(msg_req, stream(user)) end) do
      now = System.system_time(:millisecond)

      state = Enum.map(state_resp.state_events, &initial_sync_state_event(&1, room, now))
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
  end

  # Flatten a Core.SyncRoomStateEvent into the Matrix state-event JSON shape initialSync
  # expects. content is JSON bytes. Code-review cycle 1 (MINOR-4): real
  # event_id/origin_server_ts are now available on `se` (bugfix
  # sync-state-events-missing-fields widened Core.SyncRoomStateEvent and
  # threaded real identity through build_state_events/2) — this helper still
  # synthesizes a fake event_id/`now` timestamp here deliberately, NOT because
  # the struct omits them. Using the real values here is tracked as a
  # separate, agreed follow-up (see bug-context.md's Dev Notes:
  # "/initialSync and /members would still return synthetic values" is flagged
  # as a loud note, not silently expanded into this bug's scope) — out of scope
  # for this fix.
  defp initial_sync_state_event(se, room, now) do
    content =
      case se.content do
        b when is_binary(b) and b != "" ->
          case Jason.decode(b) do
            {:ok, m} -> m
            _ -> %{}
          end

        _ ->
          %{}
      end

    %{
      "type" => se.type,
      "state_key" => se.state_key,
      "content" => content,
      "sender" => se.sender,
      "room_id" => room,
      "event_id" => "$synth_" <> Base.url_encode64(se.type <> "|" <> se.state_key, padding: false),
      "origin_server_ts" => now
    }
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
  # Returns the room's m.room.member state events (Element renders the member
  # list from this). Built from the existing get_room_state/2 backend (which
  # enforces membership — a non-member is rejected with 403, no cross-room leak)
  # by filtering its full state-event list down to type == "m.room.member" and
  # serialising each via the same flattener initialSync uses. Matrix /members
  # returns full member EVENTS (not just user ids), so we map the whole event.
  get "/client/v3/rooms/:room_id/members" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)

    req = %Core.GetRoomStateRequest{room_id: room, event_type: "", state_key: ""}

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.get_room_state(req, stream(user)) end) do
      {:ok, resp} ->
        now = System.system_time(:millisecond)

        chunk =
          resp.state_events
          |> Enum.filter(&(&1.type == "m.room.member"))
          |> Enum.map(&initial_sync_state_event(&1, room, now))

        send_json(conn, 200, %{"chunk" => chunk})

      {:error, err} ->
        send_error(conn, err)
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
             :ok <- check_fully_read_event(room_id, markers["m.fully_read"]),
             :ok <- store_fully_read(user, room_id, markers["m.fully_read"]),
             :ok <- send_marker_receipts(user, room_id, markers) do
          send_json(conn, 200, %{})
        else
          {:error, {status, errcode, message}} -> error(conn, status, errcode, message)
        end
    end
  end

  defp check_fully_read_event(_room_id, nil), do: :ok

  defp check_fully_read_event(room_id, event_id) do
    if Nebu.Matrix.RoomAccountDataStore.event_in_room?(room_id, event_id),
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
  # stream identity (NOT request.requester_id) and requires power_level >= 100,
  # so a non-owner is rejected with 403. Body: {"new_version": "<v>"}.
  post "/client/v3/rooms/:room_id/upgrade" do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(room_id)
    params = body_params(conn)

    req = %Core.UpgradeRoomRequest{
      old_room_id: room,
      requester_id: user,
      new_version: params["new_version"] || ""
    }

    case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.upgrade_room(req, stream(user)) end) do
      {:ok, resp} -> send_json(conn, 200, %{"replacement_room" => resp.new_room_id})
      {:error, err} -> send_error(conn, err)
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
  # (sender PL >= state_default; non-member → 403). m.room.member /
  # m.room.power_levels / m.room.create are rejected (403) — they have dedicated
  # authorized paths and must NOT be forgeable here. For m.space.parent the parent
  # space must exist (404) and the sender must be a member of it (403). The acting
  # user is the authenticated token user (no path/body user → no IDOR); the
  # server builds all top-level event fields — the body is the content only.
  put "/client/v3/rooms/:room_id/state/:event_type/:state_key" do
    do_set_room_state(conn, room_id, event_type, state_key)
  end

  put "/client/v3/rooms/:room_id/state/:event_type" do
    do_set_room_state(conn, room_id, event_type, "")
  end

  match _ do
    error(conn, 404, "M_NOT_FOUND", "Unrecognized request")
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
  # spared so it can finish the batch and the caller keeps managing devices. This
  # preserve is SYMMETRIC across token kinds:
  #   * opaque caller — its `matrix_sessions` row (matched by current_device) is NOT
  #     dropped;
  #   * raw-JWT caller — the kill-switch SKIPS the binding row whose token_hash equals
  #     the SHA-256 of the live request token (so it is not denylisted), even though
  #     other JWTs bound to the same device ARE revoked.
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

    # F-1 kill-switch: denylist every raw-JWT bound to this device (by token hash,
    # which equals the SHA-256 the live token resolves to in OidcPlug.revoked?) until
    # its own exp, then drop the binding rows. When this IS the caller's own device,
    # the caller's CURRENT token hash is SKIPPED so the live request credential survives
    # to finish the batch (symmetric with the opaque matrix_sessions preserve below).
    for {token_hash, exp} <- Nebu.Matrix.Session.DeviceBinding.list_for_user_device(user, device_id) do
      unless device_id == preserve_device and token_hash == preserve_token_hash do
        Nebu.Web.TokenDenylist.revoke_by_hash(token_hash, exp)
      end
    end

    _ = Nebu.Matrix.Session.DeviceBinding.delete_for_user_device(user, device_id)

    # Revoke the opaque session bound to this device (logout-equivalent) UNLESS it is
    # the live request token's own device (preserve just that one).
    unless device_id == preserve_device do
      _ = Nebu.Matrix.Session.MatrixSessionStore.delete_for_user_device(user, device_id)
    end

    # Remove the device identity + all key material.
    _ = DeviceKeyStore.delete_device(user, device_id)
    :ok
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
        _ = DeviceKeyStore.touch_last_seen(conn.assigns[:current_user], did, client_ip(conn))
        :ok

      _ ->
        :ok
    end
  end

  defp client_ip(conn) do
    case conn.remote_ip do
      ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
      _ -> nil
    end
  end

  # Lazily bind a raw-JWT access token to the device it publishes keys for, the first
  # time, when no server-side binding exists yet (token has a "." → JWT; no
  # conn.assigns[:device_id]). Opaque sessions already carry their device in
  # matrix_sessions, so they are skipped. Idempotent and best-effort.
  defp maybe_bind_jwt_device(conn, user, device_id) do
    token = conn.assigns[:access_token]

    cond do
      is_binary(conn.assigns[:device_id]) and conn.assigns[:device_id] != "" ->
        :ok

      is_binary(token) and String.contains?(token, ".") ->
        # S3 F-1: carry the verified token's exp into the binding so the kill-switch
        # can denylist it on device delete.
        exp = (conn.assigns[:oidc_claims] || %{})["exp"]
        _ = Nebu.Matrix.Session.DeviceBinding.put(token, user, device_id, exp)
        :ok

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

  # device_signing/upload: MUST-guard the device/cross-signing ID namespace, then
  # persist with first-upload / idempotent / overwrite-protection handling.
  defp do_device_signing_upload(conn) do
    user = conn.assigns[:current_user]
    body = body_params(conn)

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
  end

  defp do_persist_cross_signing(conn, user, body) do
    stored = CrossSigningKeyStore.get_keys(user)
    supplied = Map.take(body, ["master_key", "self_signing_key", "user_signing_key"])

    cond do
      # AC2: first upload (no existing master key) → persist, plain 200 {} (no UIA).
      # INFO-1: the first-upload gate is keyed on master_key presence — real clients
      # always upload the master key first, so its absence reliably means "no keys yet".
      is_nil(stored["master_key"]) ->
        :ok = CrossSigningKeyStore.put_keys(user, supplied)
        send_json(conn, 200, %{})

      # AC2: idempotent re-upload of the SAME keys → 200 {} (no UIA).
      cross_signing_unchanged?(stored, supplied) ->
        send_json(conn, 200, %{})

      # AC2: overwriting existing DIFFERENT keys without valid auth → 403 M_FORBIDDEN.
      # (Full UIA is out of scope for this story — minimal 403 contract per CS spec.)
      true ->
        error(conn, 403, "M_FORBIDDEN", "Cannot replace existing cross-signing keys")
    end
  end

  defp cross_signing_unchanged?(stored, supplied) do
    Enum.all?(["master_key", "self_signing_key", "user_signing_key"], fn k ->
      stored[k] == supplied[k]
    end)
  end

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
  defp merge_one_signature(user_id, key_id, signed_object) when is_map(signed_object) do
    new_sigs = Map.get(signed_object, "signatures", %{})

    case merge_device_key_signature(user_id, key_id, signed_object, new_sigs) do
      :ok ->
        :ok

      :not_found ->
        merge_cross_signing_signature(user_id, key_id, signed_object, new_sigs)

      :mismatch ->
        :invalid
    end
  end

  defp merge_one_signature(_user_id, _key_id, _signed_object), do: :invalid

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

  # MAJOR-1: a cross-signing signature merge, mirroring the device-key path exactly —
  # validate FIRST, persist ONLY on a match. Returns :ok | :invalid. The store's
  # find_key_object/2 returns the stored cross-signing key object for key_id (or nil).
  # We compare the non-signatures parts (dropping `signatures` AND `unsigned` on both
  # sides) BEFORE writing; on a mismatch (or no stored key) NOTHING is persisted.
  defp merge_cross_signing_signature(user_id, key_id, signed_object, new_sigs) do
    case CrossSigningKeyStore.find_key_object(user_id, key_id) do
      nil ->
        :invalid

      stored ->
        stored_clean = stored |> Map.delete("signatures") |> Map.delete("unsigned")
        submitted_clean = signed_object |> Map.delete("signatures") |> Map.delete("unsigned")

        if stored_clean == submitted_clean do
          :ok = CrossSigningKeyStore.merge_signatures(user_id, key_id, new_sigs)
          :ok
        else
          :invalid
        end
    end
  end

  defp deep_merge_sig_map(existing, new) when is_map(existing) and is_map(new) do
    Map.merge(existing, new, fn _signer, old_map, new_map ->
      Map.merge(old_map || %{}, new_map || %{})
    end)
  end

  defp deep_merge_sig_map(_existing, new) when is_map(new), do: new
  defp deep_merge_sig_map(existing, _new), do: existing

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

  defp do_set_room_state(conn, raw_room, raw_event_type, raw_state_key) do
    user = conn.assigns[:current_user]
    room = URI.decode_www_form(raw_room)
    event_type = URI.decode_www_form(raw_event_type)
    state_key = URI.decode_www_form(raw_state_key)

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

      true ->
        # body is the raw content object; re-encode to JSON for the request struct.
        content = body_params(conn)

        req = %Core.SetRoomStateRequest{
          room_id: room,
          sender_id: user,
          event_type: event_type,
          state_key: state_key,
          content_json: Jason.encode!(content)
        }

        case call_core(fn -> Nebu.Matrix.EventDispatcher.Server.set_room_state(req, stream(user)) end) do
          {:ok, resp} -> send_json(conn, 200, %{"event_id" => resp.event_id})
          {:error, err} -> send_error(conn, err)
        end
    end
  end

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
