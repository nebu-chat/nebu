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

    {next_batch, rooms} =
      if is_binary(since) and since != "" do
        delta =
          Nebu.Matrix.EventDispatcher.Server.get_sync_delta(
            %Core.GetSyncDeltaRequest{
              user_id: user,
              since_token: since,
              timeout_ms: timeout_ms,
              device_id: ""
            },
            stream(user)
          )

        # get_sync_delta already returns the fully-resolved checkpoint: on an
        # unknown/stale since_token it transparently falls back to an initial
        # sync and sets delta.fallback_to_initial: true while putting the full
        # snapshot in delta.rooms and a fresh delta.since_token. The HTTP /sync
        # response shape is identical in both cases (next_batch + joined rooms),
        # so we use the resolved fields directly — the flag carries no extra
        # response semantics for this endpoint.
        {delta.since_token, delta.rooms}
      else
        initial =
          Nebu.Matrix.EventDispatcher.Server.get_initial_sync(
            %Core.GetInitialSyncRequest{user_id: user},
            stream(user)
          )

        {initial.since_token, initial.rooms}
      end

    send_json(conn, 200, put_device_e2e_counts(sync_response(next_batch, rooms), conn))
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

  # POST /keys/device_signing/upload — cross-signing key upload stub.
  # ADR-011: managed E2EE model; accept and acknowledge, no-op store.
  # Spec 200 response is {} (Matrix CS §Cross-signing, added v1.1).
  post "/client/v3/keys/device_signing/upload" do
    send_json(conn, 200, %{})
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

  # POST /keys/query — device-key lookup (Matrix CS §/keys/query). Echoes back the
  # device_keys objects published via /keys/upload so a client (incl. Element querying
  # its OWN user) sees its device as registered. Cross-signing maps stay empty (no
  # cross-signing). This is the key DIRECTORY only — it does not enable E2EE (ADR-011).
  post "/client/v3/keys/query" do
    requested = body_params(conn)["device_keys"]

    device_keys =
      if is_map(requested) and map_size(requested) > 0 do
        query_device_keys(requested)
      else
        %{}
      end

    send_json(conn, 200, %{
      "device_keys" => device_keys,
      "master_keys" => %{},
      "self_signing_keys" => %{},
      "user_signing_keys" => %{},
      "failures" => %{}
    })
  end

  # POST /keys/upload — publish device identity keys, one-time keys, and fallback keys
  # (Matrix CS §/keys/upload). Persists them in the device-key directory and returns the
  # real unclaimed one_time_key_counts. device_id comes from the body's device_keys object
  # (Required on first upload, "must match the device used at login") and falls back to the
  # token's bound device for opaque sessions. With nothing to attribute (empty body, JWT
  # session w/o a bound device) it's a no-op returning empty counts — does NOT touch the DB.
  post "/client/v3/keys/upload" do
    user = conn.assigns[:current_user]
    params = body_params(conn)
    device_keys = params["device_keys"]
    one_time_keys = params["one_time_keys"]
    fallback_keys = params["fallback_keys"]

    cond do
      # Bound the per-request write amplification (keys/upload is unauthenticated-rate-
      # limited only by the global body cap). A well-behaved client uploads ≤50 keys and
      # stops once /sync reports the target count is reached; the cap stops a malicious
      # client from packing one body with a huge key set. 100 comfortably exceeds Element.
      oversized?(one_time_keys) or oversized?(fallback_keys) ->
        error(conn, 400, "M_INVALID_PARAM", "Too many keys in a single upload")

      true ->
        case upload_device_id(device_keys, conn) do
          nil ->
            send_json(conn, 200, %{"one_time_key_counts" => %{}})

          device_id ->
            if is_map(device_keys), do: DeviceKeyStore.put_device_keys(user, device_id, device_keys)
            if is_map(one_time_keys), do: DeviceKeyStore.store_one_time_keys(user, device_id, one_time_keys)
            if is_map(fallback_keys), do: DeviceKeyStore.store_fallback_keys(user, device_id, fallback_keys)

            send_json(conn, 200, %{"one_time_key_counts" => DeviceKeyStore.otk_counts(user, device_id)})
        end
    end
  end

  # GET /devices — the user's registered devices (Matrix CS §/devices). Backed by the
  # device-key directory (a device appears once it has published keys).
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

  # GET/PUT /user/{userId}/account_data/{type} — ETS-backed per-user account data stub.
  # PUT stores the JSON body; GET reads it back. Volatile (in-memory ETS, lost on restart).
  # ADR-011: managed E2EE stub; ADR-002: ETS for volatile data.
  put "/client/v3/user/:user_id/account_data/:type" do
    authenticated_user = conn.assigns[:current_user]
    decoded_user = URI.decode_www_form(user_id)
    decoded_type = URI.decode_www_form(type)

    if decoded_user != authenticated_user do
      error(conn, 403, "M_FORBIDDEN", "You can only write your own account data")
    else
      json_body = Jason.encode!(body_params(conn))
      Nebu.Matrix.AccountDataStore.put(decoded_user, decoded_type, json_body)
      send_json(conn, 200, %{})
    end
  end

  get "/client/v3/user/:user_id/account_data/:type" do
    authenticated_user = conn.assigns[:current_user]
    decoded_user = URI.decode_www_form(user_id)
    decoded_type = URI.decode_www_form(type)

    if decoded_user != authenticated_user do
      error(conn, 403, "M_FORBIDDEN", "You can only read your own account data")
    else
      case Nebu.Matrix.AccountDataStore.get(decoded_user, decoded_type) do
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
  # expects. content is JSON bytes; synth event_id/ts since the state struct omits them.
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
  # No-op (200 {}). Nebu has no fully-read-marker store — it tracks read RECEIPTS
  # (m.read, via the /receipt endpoint) but not the separate `m.fully_read`
  # marker, which is best-effort client UI state. A 200 {} is spec-valid and
  # clients tolerate it; we deliberately do NOT forward m.read here to avoid
  # double-counting a receipt the client already sets via /receipt. Authenticated
  # (Protected pipeline); acting user is the token user, so there is no IDOR.
  post "/client/v3/rooms/:_room_id/read_markers" do
    send_json(conn, 200, %{})
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

  # Per-request key cap for /keys/upload (DoS bound — see handler comment).
  @max_keys_per_upload 100

  defp oversized?(map) when is_map(map), do: map_size(map) > @max_keys_per_upload
  defp oversized?(_), do: false

  # device_id for /keys/upload: the body's device_keys.device_id is authoritative
  # (Required on first upload), then the token's bound device (opaque sessions), then —
  # for OTK-only top-ups on a raw OIDC JWT (no bound device) — the user's sole registered
  # device. nil → nothing to attribute (no-op, no DB write).
  defp upload_device_id(device_keys, conn) do
    cond do
      is_map(device_keys) and is_binary(device_keys["device_id"]) and device_keys["device_id"] != "" ->
        device_keys["device_id"]

      is_binary(conn.assigns[:device_id]) and conn.assigns[:device_id] != "" ->
        conn.assigns[:device_id]

      true ->
        DeviceKeyStore.sole_device_id(conn.assigns[:current_user])
    end
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
