defmodule Nebu.Matrix.EventDispatcher.Server do
  require Logger

  # the two fixed texts of a refused join (story create-room-presets-power-levels-topic, D1)
  @join_banned_text "You are banned from this room"
  @join_not_invited_text "You are not invited to this room"

  # ─── Configurable room registry module for testability ─────────────────────
  # Override via Application.put_env(:event_dispatcher, :room_registry_module, FakeModule) in tests.
  defp room_registry_module do
    Application.get_env(:event_dispatcher, :room_registry_module, Nebu.Matrix.Room.Server)
  end

  # ─── Configurable invite DB module for testability ──────────────────────────
  # Override via Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB) in tests.
  defp db_module_invite do
    Application.get_env(:event_dispatcher, :invite_db_module, Nebu.Matrix.Room.InviteDB)
  end

  # ─── Configurable messages DB module for testability ─────────────────────────
  # Override via Application.put_env(:event_dispatcher, :messages_db_module, FakeDB) in tests.
  defp messages_db_module do
    Application.get_env(:event_dispatcher, :messages_db_module, Nebu.Matrix.Room.DB)
  end

  # ─── Configurable rooms DB module for testability ─────────────────────────────
  # Override via Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB) in tests.
  defp rooms_db_module do
    Application.get_env(:event_dispatcher, :rooms_db_module, Nebu.Matrix.Room.DB)
  end

  # ─── forget-room-membership-purge: forgotten-room set for sync exclusion ───────
  # Returns the MapSet of room_ids the user has forgotten — read fresh on every sync
  # so a forget (or a re-join that clears it) takes effect on the very next sync.
  #
  # get_forgotten_room_ids/1 is intentionally NOT a DBBehaviour callback (adding one
  # would force every injected FakeDB to implement it → warnings-as-errors). The
  # function_exported?/3 guard makes injected fakes that lack it degrade safely to the
  # empty set, so unit tests with a Repo-less FakeDB never hit Ecto here.
  defp forgotten_room_ids(user_id) do
    mod = rooms_db_module()

    if function_exported?(mod, :get_forgotten_room_ids, 1) do
      case mod.get_forgotten_room_ids(user_id) do
        {:ok, ids} -> MapSet.new(ids)
        {:error, _reason} -> MapSet.new()
      end
    else
      MapSet.new()
    end
  end

  # forget-room-membership-purge (AC6): clear a forgotten-room record on re-join so
  # the room reappears in sync. Best-effort and idempotent (no-op if not forgotten).
  #
  # Guarded two ways so it never breaks Repo-less unit tests of join_room/2:
  #   - function_exported?/3 — an injected FakeDB lacking the function is skipped.
  #   - Process.whereis(Nebu.Repo) — the default real DB module is only invoked when a
  #     Repo is actually running (unit join tests inject a Room FakeDB but leave
  #     rooms_db_module() defaulting to the real DB, with no Repo started).
  defp unforget_room(user_id, room_id) do
    mod = rooms_db_module()

    if function_exported?(mod, :remove_forgotten_room, 2) and
         Process.whereis(Nebu.Repo) != nil do
      _ = mod.remove_forgotten_room(user_id, room_id)
    end

    :ok
  end

  # ─── Configurable alias DB module for testability ─────────────────────────────
  # Override via Application.put_env(:event_dispatcher, :alias_db_module, FakeAliasDB) in tests.
  # Used by create_room/2 to register a room's canonical alias in the room_aliases
  # directory (story room-canonical-alias-from-name).
  defp alias_db_module do
    Application.get_env(:event_dispatcher, :alias_db_module, Nebu.Matrix.Room.DB)
  end

  # ─── Configurable receipt DB module for testability ──────────────────────────
  # Override via Application.put_env(:event_dispatcher, :receipt_db_module, FakeReceiptDB) in tests.
  defp receipt_db_module do
    Application.get_env(:event_dispatcher, :receipt_db_module, Nebu.Matrix.Receipt.DB)
  end

  # ─── Configurable profile DB module for testability ──────────────────────────
  # Override via Application.put_env(:event_dispatcher, :profile_db_module, FakeProfileDB) in tests.
  defp profile_db_module do
    Application.get_env(:event_dispatcher, :profile_db_module, Nebu.Matrix.Profile.DB)
  end

  # ─── Configurable presence module for testability ────────────────────────────
  # Override via Application.put_env(:event_dispatcher, :presence_module, FakePresenceModule) in tests.
  defp presence_module do
    Application.get_env(:event_dispatcher, :presence_module, Nebu.Matrix.Presence.Manager)
  end

  # ─── Configurable PgStore module for testability ──────────────────────────────
  # Override via Application.put_env(:event_dispatcher, :pg_store_module, FakePgStore) in tests.
  defp pg_store_module do
    Application.get_env(:event_dispatcher, :pg_store_module, Nebu.Matrix.Session.PgStore)
  end

  # ─── Configurable AuditWriter module for testability ─────────────────────────
  # Override via Application.put_env(:compliance, :audit_writer, FakeAuditWriter) in tests.
  defp audit_writer_module do
    Application.get_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)
  end

  # ─── Configurable SessionSupervisor module for testability ─────────────────
  # Override via Application.put_env(:event_dispatcher, :session_supervisor_module, FakeModule) in tests.
  defp session_supervisor_module do
    Application.get_env(:event_dispatcher, :session_supervisor_module, Nebu.Matrix.Session.SessionSupervisor)
  end

  # ─── Configurable AdminDB module for testability ─────────────────────────────
  # Override via Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB) in tests.
  defp admin_db_module do
    Application.get_env(:event_dispatcher, :admin_db_module, Nebu.Admin.DB)
  end

  # ─── Configurable search DB module for testability ──────────────────────────
  # Override via Application.put_env(:event_dispatcher, :search_db_module, FakeSearchDB) in tests.
  defp search_db_module do
    Application.get_env(:event_dispatcher, :search_db_module, Nebu.Matrix.Search.DB)
  end

  # ─── Configurable TokenValidator module for testability ──────────────────────
  # Override via Application.put_env(:event_dispatcher, :token_validator_module, FakeModule) in tests.
  # When set, validate_token/2 calls this module's validate/4 directly instead of
  # delegating to Nebu.Matrix.Session.TokenValidator (which itself delegates internally).
  defp token_validator_module do
    Application.get_env(:event_dispatcher, :token_validator_module, nil)
  end

  # ─── Configurable BulkImporter module for testability — Story 14-3a ──────────
  # Override via Application.put_env(:event_dispatcher, :bulk_importer_module, FakeBulkImporter) in tests.
  defp bulk_importer_module do
    Application.get_env(:event_dispatcher, :bulk_importer_module, Nebu.Matrix.Session.BulkImporter)
  end

  # ─── Configurable UserStore module for testability ───────────────────────────
  # Override via Application.put_env(:event_dispatcher, :user_store_module, FakeUserStore) in tests.
  # Used by create_room/2 to provision the creator into `users` (idempotent upsert)
  # before the creator-join, so an admin id with no prior `users` row does not hit the
  # room_members → users FK violation (story admin-room-creator-provisioning).
  defp user_store_module do
    Application.get_env(:event_dispatcher, :user_store_module, Nebu.Matrix.Session.UserStore)
  end

  # ─── Configurable RoomSupervisor module for testability ──────────────────────
  # Override via Application.put_env(:event_dispatcher, :room_supervisor_module, FakeModule) in tests.
  # Used by create_room/2 to start a brand-new room via start_new_room/1, which
  # distinguishes a freshly started room from one that was already running so the
  # orphan-cleanup path can never hard-delete a pre-existing room.
  defp room_supervisor_module do
    Application.get_env(:event_dispatcher, :room_supervisor_module, Nebu.Matrix.Room.RoomSupervisor)
  end

  # story state-writer-redaction (D3): `m.room.redaction` goes through the ONE redaction writer, never stored as-is
  def send_event(%{event_type: "m.room.redaction"} = request, _stream) do
    content =
      case Jason.decode(request.content) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    target = content["redacts"]

    unless is_binary(target) and target != "" do
      reject!("M_BAD_JSON", "m.room.redaction requires content.redacts")
    end

    # security cycle 1 (review M3, Kassandra INFO 9): a client value never reaches the target read as a NUL (no 500, no ERROR log),
    # and the rest of the content is checked like the /redact body (D13)
    if contains_nul?(target), do: reject!("M_BAD_JSON", "content must not contain NUL characters")
    rest = Map.delete(content, "redacts")
    validate_redaction_body!(rest)

    key = Nebu.Matrix.Room.Server.send_txn_key(request.room_id, request.sender_id, "m.room.redaction", request.txn_id)
    %Core.SendEventResponse{event_id: redact_via_writer(request.room_id, request.sender_id, target, rest, key)}
  end

  def send_event(request, _stream) do
    room_id = request.room_id
    sender_id = request.sender_id
    event_type = request.event_type
    txn_id = request.txn_id
    # Story 9-7: extract state_key (field 7 in SendEventRequest).
    # SEC Gate 1 fix: use is_state_event (field 8) to decide the power level check.
    # Story power-levels-enforcement (D5): Room.Server requires `events[type]`, else state_default for a state event
    # (is_state_event=true) and events_default for a message event (is_state_event=false, the default).
    # state_key is passed as the Matrix state_key string (may be "" for m.room.name).
    # Pass nil when NOT a state event so Room.Server applies the correct power check.
    is_state_event = Map.get(request, :is_state_event, false)
    raw_state_key = Map.get(request, :state_key, "")
    state_key = if is_state_event, do: raw_state_key, else: nil

    # Decode content JSON string to a map (content is stored as JSONB, may arrive as binary).
    content =
      case Jason.decode(request.content) do
        {:ok, map} -> map
        {:error, _} -> %{}
      end

    # Verify the room exists (Room GenServer must be running).
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        # Membership check: sender must be a room member before sending.
        state = room_registry_module().get_state(room_id)

        unless MapSet.member?(state.members, sender_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "#{sender_id} is not a member of #{room_id}"
        end

        # Delegate to Room.Server — handles idempotency, signing, persistence, broadcast.
        # Story 9-7: pass state_key so state events are persisted with their key.
        # SEC Gate 1 / power-levels-enforcement D5: state_key=nil is a message event (events[type] else events_default),
        # a string is a state event (events[type] else state_default); the room process re-checks the membership first.
        case Nebu.Matrix.Room.Server.send_event(room_id, sender_id, event_type, content, txn_id, state_key) do
          {:ok, event_id} ->
            %Core.SendEventResponse{event_id: event_id}

          # story power-levels-enforcement (D5 (a)): below the level of THIS event type (`events[type]`, else events_default /
          # state_default): an explicit M_FORBIDDEN with a fixed text
          {:error, :forbidden} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.permission_denied(),
              errcode: "M_FORBIDDEN",
              message: "You do not have a high enough power level to send this event"

          # D5 (d): the room process re-checked the membership (a kick / ban committed after the snapshot above)
          {:error, :sender_not_joined} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.permission_denied(),
              errcode: "M_FORBIDDEN",
              message: "You are not a member of this room"

          {:error, :room_archived} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.failed_precondition(),
              message: "M_ROOM_ARCHIVED: room is archived"

          # story event-size-limit (D5): the backstop of Room.Server.do_send_event/7 (the router pre-check agrees): a fixed text
          {:error, :event_too_large} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.too_large(),
              message: Nebu.Matrix.EventSize.message(:event_too_large)

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "send_event failed: #{inspect(reason)}"
        end
    end
  end

  # the /redact body rules of D13 that the /send router does not apply: no NUL anywhere, `reason` a string of at most 1024 bytes
  defp validate_redaction_body!(content) do
    reason = content["reason"]

    cond do
      contains_nul?(content) -> reject!("M_BAD_JSON", "content must not contain NUL characters")
      not (is_nil(reason) or is_binary(reason)) -> reject!("M_BAD_JSON", "reason must be a string")
      is_binary(reason) and byte_size(reason) > 1024 -> reject!("M_INVALID_PARAM", "reason exceeds 1024 bytes")
      true -> :ok
    end
  end

  # PUT /rooms/{roomId}/redact/{eventId}/{txnId} (story state-writer-redaction, D1 - D3, D7): the router validated the body; the
  # redaction is decided and written by Room.Server.redact/5. The idempotency key adds the event id (a txn id is scoped to its path).
  def redact_event(request, _stream) do
    content =
      case Jason.decode(request.content_json) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    key = {request.room_id, request.sender_id, {:redact, request.event_id, request.txn_id}}
    %Core.RedactEventResponse{event_id: redact_via_writer(request.room_id, request.sender_id, request.event_id, content, key)}
  end

  defp redact_via_writer(room_id, sender_id, target, content, txn_key) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "room not found: #{room_id}"

      {:ok, _pid} ->
        result =
          try do
            room_registry_module().redact(room_id, sender_id, target, content, txn_key)
          catch
            :exit, _reason -> {:error, :room_unavailable}
          end

        case result do
          {:ok, event_id, %{replayed: replayed?, target_sender: target_sender}} ->
            if not replayed? and target_sender != sender_id, do: audit_redaction(sender_id, room_id, target, target_sender)
            event_id

          {:error, reason} ->
            redaction_refusal!(room_id, reason)
        end
    end
  end

  defp redaction_refusal!(room_id, reason) do
    forbidden = fn message ->
      raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: message
    end

    case reason do
      :sender_not_joined -> forbidden.("You are not a member of this room")
      :forbidden -> forbidden.("You do not have a high enough power level to send this event")
      :insufficient_redact_level -> forbidden.("You do not have a high enough power level to redact other users' events")
      :not_redactable -> forbidden.("This event cannot be redacted on this server")

      :target_not_found ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), errcode: "M_NOT_FOUND", message: "Event not found"

      :room_archived ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.failed_precondition(), message: "M_ROOM_ARCHIVED: room is archived"

      :event_too_large ->
        too_large!(Nebu.Matrix.EventSize.message(:event_too_large))

      :room_unavailable ->
        Logger.error("redact: the room process of #{room_id} did not answer the redaction")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.unavailable(),
          errcode: "M_UNAVAILABLE",
          message: "The room did not answer, the redaction may or may not have been applied"

      _failure ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "redact failed"
    end
  end

  # D12: ONE `room_event_redacted` row after a COMMITTED redaction of ANOTHER user's event, best effort (never the reason, never content)
  defp audit_redaction(sender_id, room_id, target, target_sender) do
    metadata = %{"event_id" => target, "target_sender" => target_sender}

    case audit_writer_module().log(sender_id, "room_event_redacted", "room", room_id, metadata, "success") do
      :ok -> :ok
      _other -> Logger.error("redact: the audit row of the redaction in #{room_id} could not be written")
    end
  rescue
    _e -> Logger.error("redact: the audit row of the redaction in #{room_id} could not be written")
  catch
    _kind, _reason -> Logger.error("redact: the audit row of the redaction in #{room_id} could not be written")
  end

  def create_room(request, _stream) do
    # Story create-room-input-validation (D7): everything the client sent is validated FIRST, before a room exists, so a
    # rejected request creates nothing (no room, not even a created-then-cleaned-up one). Raises Nebu.Matrix.Error.
    :ok = validate_create_room_request(request)

    room_id = generate_room_id()
    creator_id = request.creator_id

    # Kassandra SEC LOW-1: use start_new_room/1 (NOT start_room/1) so we can
    # distinguish a brand-new room from one that was already running. For a freshly
    # generate_room_id/0-d id an already-running room is practically impossible (an
    # 8-byte random opaque collision), but if it ever happened, proceeding would run
    # do_create_room/cleanup_orphan_room against a PRE-EXISTING room — and a later
    # failure's cleanup_orphan_room/1 would hard-delete that room's events+members+row.
    # We refuse the conflict instead, so cleanup can only ever target a room THIS call
    # created. start_room/1 (which collapses :already_started into {:ok, pid}) is left
    # untouched for all other callers.
    case room_supervisor_module().start_new_room(room_id) do
      {:ok, _pid} ->
        # Everything below writes rows that reference rooms.room_id (the rooms row was
        # inserted by Room.Server.init/1). A failure in any of these writes — notably
        # the creator-join FK violation when the creator has no `users` row (story
        # admin-room-creator-provisioning) — must NOT leave an orphan room (blank name,
        # 0 members → "stale" in the Admin UI). Run the create steps and, on ANY error
        # (including a raised Postgrex.Error / MatchError, which the previous
        # `rescue e in Nebu.Matrix.Error` did NOT catch), delete the just-created room
        # and surface a clean error instead of crashing the caller.
        try do
          do_create_room(room_id, request, creator_id)
        rescue
          e in Nebu.Matrix.Error ->
            cleanup_orphan_room(room_id)
            reraise e, __STACKTRACE__

          e ->
            # D5e: value-free. The exception MODULE (+ the pg code of a Postgrex.Error) and the stacktrace with every
            # argument list replaced by its arity; never Exception.message/1 (a database error carries a snippet of the
            # JSON content) and never the arguments of the top frame (they hold the creator id / client values).
            Logger.error(
              "create_room: cleaning up orphan room #{room_id} after #{db_error_class(e)}: " <>
                Exception.format_stacktrace(strip_stacktrace_args(__STACKTRACE__))
            )

            cleanup_orphan_room(room_id)

            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "create_room failed: #{Exception.message(e)}"
        end

      {:error, :already_started, _pid} ->
        # Room id already in use (random-id collision — see comment above). Raise a
        # clean conflict and do NOT touch the pre-existing room: no do_create_room,
        # no cleanup_orphan_room, so the existing room's events/members/row are never
        # deleted. This is the LOW-1 safety guarantee.
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.already_exists(),
          message: "room already exists: #{room_id}"

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "Failed to start room: #{inspect(reason)}"
    end
  end

  # Best-effort cleanup of a half-created room so a failed create never leaves an
  # orphan (story admin-room-creator-provisioning AC3). Stops the Room GenServer and
  # hard-deletes the rooms/events/room_members rows via the injectable rooms_db_module()
  # seam. Cleanup failures are logged, never raised — the original error is what the
  # caller must see.
  #
  # Accepted limitation (correlated failure): this cleanup is best-effort. If
  # delete_room/1 below itself fails — e.g. the same DB outage that caused the create to
  # fail in the first place — the half-created rooms row may persist, and the *original*
  # error is still what we surface to the caller. A fully transactional create
  # (m.room.create + creator membership + m.room.name in one DB transaction) is out of
  # scope for this story: the rooms row is inserted in the Room GenServer init/1 (Horde),
  # not in the event-write transaction, so it cannot be rolled back as part of those
  # writes. This residual is accepted.
  defp cleanup_orphan_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      # Stop with :normal on purpose: Horde supervises the Room GenServer with
      # restart: :transient, which does NOT restart a child that exits :normal. This is
      # what makes cleanup correct — a restart would re-run init/1 and re-insert the
      # rooms row right after we DELETE it (a re-insert race). Cleanup correctness
      # therefore depends on the child remaining :transient; changing it to :permanent
      # would silently reintroduce that race.
      {:ok, pid} -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
      _ -> :ok
    end

    case rooms_db_module().delete_room(room_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("create_room: orphan-room cleanup failed for #{room_id} (#{db_error_class(reason)})")
    end
  rescue
    e ->
      Logger.warning("create_room: orphan-room cleanup raised for #{room_id} (#{db_error_class(e)})")
  end

  # The create_room/2 body once the Room GenServer (and its rooms row) exists.
  # Returns %Core.CreateRoomResponse{}. Raises on failure; the caller's try/rescue
  # turns any raise into orphan cleanup + a clean Nebu.Matrix.Error.
  defp do_create_room(room_id, request, creator_id) do
        # Matrix Spaces (spaces-elixir s1): merge the client's creation_content into the
        # m.room.create content. Matrix CS §createRoom merges creation_content into the
        # create event content, but the server controls `creator` and `room_version` — the
        # client MUST NOT override them. We decode the client object first, then overwrite
        # creator/room_version with the server-authoritative values via Map.merge last so
        # those two keys always win. A Space carries content.type == "m.space" (MSC1772).
        client_creation_content =
          case Jason.decode(Map.get(request, :creation_content_json, "") || "") do
            {:ok, m} when is_map(m) -> m
            _ -> %{}
          end

        create_content =
          Map.merge(client_creation_content, %{"creator" => creator_id, "room_version" => Nebu.Matrix.RoomVersions.default()})

        # Persist m.room.create FIRST — Matrix spec §8.5.1 requires it to be the
        # first event in the room timeline (before m.room.member and m.room.power_levels).
        # Emitting after Server.join would put m.room.member before m.room.create in
        # the events table, causing Element to log "No membership changes detected".
        create_event_map = %{
          "room_id"          => room_id,
          "type"             => "m.room.create",
          "state_key"        => "",
          "sender"           => creator_id,
          "content"          => create_content,
          "origin_server_ts" => Nebu.DB.Helpers.now_ms()
        }
        create_event_id = Nebu.Matrix.EventId.generate(create_event_map)
        create_event_with_id = Map.put(create_event_map, "event_id", create_event_id)
        {_pub, priv_create} = :persistent_term.get(:nebu_signing_key)
        create_event_json = Nebu.Matrix.CanonicalJson.encode!(create_event_map)
        create_sig = :crypto.sign(:eddsa, :none, create_event_json, [priv_create, :ed25519])
        create_signed = Map.put(create_event_with_id, "signatures", %{"nebu" => Base.encode64(create_sig)})

        # story event-size-limit (D6 (b)): backstop of step 5g (unreachable through createRoom: 5g refused the request before the
        # room existed). FATAL for this reason only (the raise reaches create_room/2's cleanup, which deletes the half-created room);
        # any other failure of this write stays non-fatal as before.
        case Nebu.Matrix.EventSize.check_stored(create_event_json) do
          :ok ->
            :ok

          {:error, :event_too_large} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.too_large(),
              message: Nebu.Matrix.EventSize.message(:creation_content_too_large)
        end

        case messages_db_module().insert_event(create_signed) do
          :ok ->
            Enum.each(:pg.get_members("room:#{room_id}"), &send(&1, {:new_event, create_signed}))
          {:error, reason} ->
            Logger.warning("create_room: failed to write m.room.create for #{room_id} (#{db_error_class(reason)})")
        end

        # Provision the creator into `users` BEFORE the creator-join (story
        # admin-room-creator-provisioning). The room_members.user_id → users.user_id FK
        # otherwise rejects the join for any creator with no prior `users` row — e.g. an
        # instance admin who only ever logged into the Admin UI (whose OIDC path does not
        # provision a `users` row). Done here in the shared command path so BOTH the Admin
        # UI (Nebu.Matrix.create_room/2) and Matrix POST /createRoom benefit.
        #
        # SECURITY: always the normal "user" role — NEVER instance_admin, regardless of
        # caller. The upsert is INSERT … ON CONFLICT DO UPDATE (last_seen_at only), so an
        # existing row's role is preserved (no privilege downgrade, no duplication) and the
        # write is safe under a concurrent first-create race (ADR-020). creator_id is bound
        # as a query parameter (no SQL injection). This provisions only the create caller's
        # own id — no path here can provision an arbitrary other user id.
        case user_store_module().upsert_user(creator_id, "user") do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "create_room: failed to provision creator #{creator_id}: #{inspect(reason)}"
        end

        # Join creator AFTER m.room.create — emit_membership_event writes m.room.member
        # as the second event in the timeline (spec §8.5.1 order: create → member → pl).
        # A non-:ok return (e.g. an unexpected DB failure) raises so the caller's
        # try/rescue cleans up the orphan room rather than leaving a nameless/stale room.
        case Nebu.Matrix.Room.Server.join(room_id, creator_id) do
          :ok ->
            :ok

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "create_room: creator-join failed for #{room_id}: #{inspect(reason)}"
        end

        # Wake the creator's long-polling sync task immediately (mirrors join_room/2 pattern).
        # Without this broadcast, a sync task that started BEFORE createRoom returns will not
        # be subscribed to room:#{room_id}. Any leave/send event before the sync timeout
        # (30 s) would be missed, causing GAP-FORGET and similar issues.
        :pg.get_members("user:#{creator_id}")
        |> Enum.each(&send(&1, {:new_join, room_id}))

        # Spec step 3 (story create-room-presets-power-levels-topic, D7): the default levels with the creator at 100,
        # `power_level_content_override` applied on top (shallow merge, validated before the room existed; absent = the
        # default content exactly), written ONCE through the GenServer-authoritative path.
        #
        # Story create-room-invites-direct (D5, D9): `invite` was validated and de-duplicated before the room existed; with the
        # effective preset `trusted_private_chat` every invitee gets the creator's level here, BEFORE the override is merged on
        # top (a shallow override `users` map replaces the generated map, invitees included).
        invitees = invitee_list(request)
        preset = effective_preset(Map.get(request, :preset), Map.get(request, :visibility))
        level_invitees = if preset == "trusted_private_chat", do: invitees, else: []
        creator_pl = merged_power_levels(creator_id, request_power_level_override(request), level_invitees)
        case Nebu.Matrix.Room.Server.set_power_levels(room_id, creator_id, creator_pl) do
          :ok ->
            :ok

          # story event-size-limit (D6 (b)): backstop of step 5g (nothing was written: Room.Server checks before the column write)
          {:error, :event_too_large} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.too_large(),
              message: Nebu.Matrix.EventSize.message(:power_levels_too_large)

          # story power-levels-enforcement (D10): the column and the event are ONE transaction; a failure writes neither (fatal:
          # orphan cleanup, 500)
          {:error, reason} ->
            Logger.error("create_room: failed to write the power levels for #{room_id} (#{db_error_class(reason)})")

            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "create_room: failed to write the power levels"
        end

        # Matrix CS §createRoom `room_alias_name` (spec order step 4: after the default power levels, BEFORE the preset
        # events and `initial_state`; story create-room-input-validation, D2/D3). The alias was validated and pre-checked
        # in validate_create_room_request/1; the PK of room_aliases is the authoritative race-safe check here. A failure
        # raises (explicit alias = part of the request) -> orphan cleanup (deletes the alias row too) -> 400 / 500.
        explicit_alias = explicit_alias_for(request)

        # the timestamp of the last event written so far that initial_state entries must exceed (0 = no constraint)
        last_ts = if explicit_alias, do: register_explicit_alias(room_id, creator_id, explicit_alias), else: 0

        # Matrix CS §createRoom `initial_state`: creator-authored room setup applied
        # AFTER create → creator-join → power_levels and BEFORE name/topic (spec
        # ordering). Element relies on this for child-room-in-Space linkage
        # (m.space.parent), restricted join_rules etc.
        #
        # The creator holds power_level 100 in the brand-new room, so each entry is
        # applied as the creator through the SAME signed/persisted/fanned-out path
        # set_room_state uses (emit_state_event/5). Guards (apply_initial_state/3):
        #   - the types in @initial_state_forbidden_types (m.room.create, m.room.member,
        #     m.room.encryption, m.room.tombstone, m.room.third_party_invite) are skipped:
        #     the authoritative create/join setup stays canonical, no foreign membership
        #     can be forged, no E2EE room.
        #   - an m.room.power_levels entry (story power-levels-enforcement, D7) is a full
        #     replacement of the levels, written through the room-process power-level
        #     writer as a v10 change by the creator (validated before the room existed).
        #   - every other type is honoured (deliberately NOT an allowlist).
        #   - entries apply in array order → later duplicate state_keys win.
        #   - a failing persist raises (orphan cleanup → 500); the structure was
        #     validated before the room existed (validate_initial_state/1).
        # Spec step 5 (story create-room-presets-power-levels-topic, D2): the preset events, AFTER the alias and BEFORE
        # initial_state (which takes precedence: a preset event that an applied initial_state entry for the same
        # (type, "") replaces is not written). Each event is FATAL on failure (it defines who can join). The timestamp
        # chain of steps 4-7 stays strictly increasing (D3).
        request_entries = initial_state_entries(Map.get(request, :initial_state_json))
        last_ts = emit_preset_events(room_id, creator_id, preset, request_entries, last_ts)

        last_ts = apply_initial_state(room_id, creator_id, Map.get(request, :initial_state_json, ""), last_ts)

        # Spec step 7: `name`, then `topic` (they override initial_state: each is stamped strictly later than the
        # previous event of the chain, D3), then the derived alias. Name, topic and the derived alias are NON-FATAL.
        name = request.name
        topic = Map.get(request, :topic)

        last_ts =
          if name != nil and name != "" do
            last_ts = emit_name_event(room_id, creator_id, name, last_ts)

            # Keep the denormalised rooms.name column in sync so the Admin UI (and any
            # name-based lookup) shows the room name, not a blank. Routed through the
            # injectable rooms_db_module() (default Nebu.Matrix.Room.DB) so unit tests can
            # capture it without a live Repo — same pattern as the room_type write below.
            case rooms_db_module().update_room_name(room_id, name) do
              :ok -> :ok
              {:error, reason} ->
                Logger.warning("create_room: failed to persist rooms.name for #{room_id} (#{db_error_class(reason)})")
            end

            last_ts
          else
            last_ts
          end

        # D5: a top-level topic (also "") is written as m.room.topic; rooms.topic is NOT written (D9, dead column).
        last_ts = if is_binary(topic), do: emit_topic_event(room_id, creator_id, topic, last_ts), else: last_ts

        # Derive + register a canonical alias `#localpart:server` from the name and emit
        # m.room.canonical_alias (story room-canonical-alias-from-name). Ordered AFTER
        # m.room.name (the alias is derived from the same name). The WHOLE step is
        # NON-FATAL — mirrors the name/type handling above: any derivation/registration
        # failure logs a warning and leaves the room created. A room with no name skips
        # this entirely (backwards compat).
        #
        # Story create-room-input-validation (D3): with an explicit `room_alias_name` ONLY that alias is registered; the
        # derived alias is a Nebu feature for creates that name no alias (Admin UI, Spaces, private rooms, API clients).
        last_ts =
          if name != nil and name != "" and is_nil(explicit_alias),
            do: register_canonical_alias(room_id, creator_id, name, last_ts),
            else: last_ts

        # Spec step 8 (story create-room-invites-direct, D8): the invite events, AFTER everything of steps 4-7, in list order,
        # each stamped strictly after the previous event of the chain, through the SAME path as POST /rooms/{roomId}/invite
        # (D1). EVERY invite is FATAL on failure (raise -> orphan cleanup incl. the invitation rows -> 500): the request was
        # fully validated, a failure is a store error, and a DM without its partner is useless.
        emit_invites(room_id, creator_id, invitees, request.is_direct == true, last_ts)

        # Matrix Spaces (spaces-elixir s1): persist the denormalised rooms.room_type
        # column when a type was supplied (e.g. "m.space"). For an ordinary room
        # room_type is "" (empty default) → leave the column NULL (backward compat, AC4).
        # The value is bound as a query parameter in update_room_type/2 (no SQL injection).
        room_type = Map.get(request, :room_type, "")
        if is_binary(room_type) and room_type != "" do
          case rooms_db_module().update_room_type(room_id, room_type) do
            :ok -> :ok
            {:error, reason} ->
              Logger.warning("create_room: failed to persist rooms.room_type for #{room_id} (#{db_error_class(reason)})")
          end
        end

        # D6: `visibility: "public"` stores the directory flag through the audited set_room_visibility/3 with the creator as
        # actor (one room_visibility_changed row). There is no room directory yet (follow-up ad); the flag has no
        # behavioural effect, so a failed write is non-fatal (the column default `private` stays; set_room_visibility/3
        # logs a value-free warning).
        if Map.get(request, :visibility) == "public", do: set_room_visibility(creator_id, room_id, "public")

        audit_writer_module().log(
          creator_id,
          "room_created",
          "room",
          room_id,
          create_audit_metadata(request.is_direct, explicit_alias),
          "success"
        )

        %Core.CreateRoomResponse{room_id: room_id}
  end

  # D2 / D3: the preset events (state_key ""), sender = creator, each stamped strictly after the previous event of the chain.
  # Returns the timestamp of the last event written (or the one given). A failing write raises (orphan cleanup, 500).
  defp emit_preset_events(room_id, creator_id, preset, request_entries, last_ts) do
    replaced = initial_state_preset_types(request_entries)

    preset
    |> preset_events()
    |> Enum.reject(fn {type, _content} -> type in replaced end)
    |> Enum.reduce(last_ts, fn {type, content}, ts ->
      case emit_state_event_at(room_id, creator_id, type, "", content, ts + 1) do
        {:ok, _event_id, new_ts} ->
          new_ts

        {:error, reason} ->
          Logger.error("create_room: failed to write the preset event #{type} for #{room_id} (#{db_error_class(reason)})")

          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.internal(),
            message: "create_room: failed to write the preset event #{type} for #{room_id}"
      end
    end)
  end

  # Step 7 `name`: through emit_state_event_at/6 with the chain timestamp (it used to be stamped with now_ms(), which
  # could tie with, or be earlier than, an initial_state m.room.name entry). Non-fatal as before.
  defp emit_name_event(room_id, creator_id, name, last_ts) do
    case emit_state_event_at(room_id, creator_id, "m.room.name", "", %{"name" => name}, last_ts + 1) do
      {:ok, _event_id, ts} ->
        ts

      {:error, reason} ->
        Logger.warning("create_room: failed to write m.room.name for #{room_id} (#{db_error_class(reason)})")
        last_ts
    end
  end

  # Step 7 `topic` (D5): after the name, non-fatal like the name.
  defp emit_topic_event(room_id, creator_id, topic, last_ts) do
    case emit_state_event_at(room_id, creator_id, "m.room.topic", "", topic_event_content(topic), last_ts + 1) do
      {:ok, _event_id, ts} ->
        ts

      {:error, reason} ->
        Logger.warning("create_room: failed to write m.room.topic for #{room_id} (#{db_error_class(reason)})")
        last_ts
    end
  end

  # ─── Canonical alias derivation + registration (story room-canonical-alias-from-name) ──

  # Bounded retry budget for the deterministic collision suffix (#localpart, -2, …, -N).
  # Beyond this we give up (non-fatal) rather than loop forever.
  @alias_collision_retries 20

  # Max total alias bytes incl. the leading `#` and the `:server` suffix (Matrix spec).
  @alias_max_bytes 255

  # room_created audit metadata (Kassandra L-4): the explicit alias is the one identifier the client chose. It was
  # validated to at most 255 bytes already; the cap here keeps the row bounded whatever a future caller passes. The
  # derived alias is not recorded (its registration is non-fatal and unknown at this point).
  defp create_audit_metadata(is_direct, nil), do: %{"is_direct" => is_direct}

  defp create_audit_metadata(is_direct, alias_str) do
    capped = if byte_size(alias_str) > @alias_max_bytes, do: binary_part(alias_str, 0, @alias_max_bytes), else: alias_str
    %{"is_direct" => is_direct, "alias" => capped}
  end

  @doc false
  # Derive a spec-valid Matrix alias localpart from a room name. PURE.
  #
  # Rules (kept deliberately conservative for interop, per Oracle context):
  #   1. lowercase the whole name,
  #   2. replace every run of characters OUTSIDE the allowlist `[a-z0-9._=\-+]` with a
  #      single `-`. `/` is deliberately EXCLUDED from the allowlist: Matrix grammar
  #      permits it in a localpart, but `/` mis-routes in the `/directory/room/{alias}`
  #      path, so we fold it to a dash (interop hardening, code-review MINOR),
  #   3. collapse runs of `-` and trim leading/trailing `-`,
  #   4. trim leading/trailing `.` — dot-only / edge-dot localparts are interop hazards
  #      that Synapse/Element avoid,
  #   5. if nothing usable remains (empty or punctuation-only) → :none (caller emits no
  #      alias; room still created).
  #
  # Length bounding so the full `#localpart:server` fits in @alias_max_bytes is applied by
  # the caller (it knows the server name); this function only normalises the localpart.
  @spec derive_alias_localpart(String.t()) :: {:ok, String.t()} | :none
  def derive_alias_localpart(name) when is_binary(name) do
    localpart =
      name
      |> String.downcase()
      # Replace any run of disallowed chars with a single dash. `/` is NOT in the
      # allowlist (mis-routes in /directory/room/{alias}) so it folds to a dash.
      |> String.replace(~r/[^a-z0-9._=\-+]+/u, "-")
      # Collapse repeated dashes that may have been introduced.
      |> String.replace(~r/-+/, "-")
      # Trim leading/trailing dashes, then leading/trailing dots (interop hardening).
      |> String.trim("-")
      |> String.trim(".")
      # A `.-.` style edge can leave a dangling dash after dot-trim; trim once more.
      |> String.trim("-")

    # Require at least one alphanumeric char: a localpart that is empty or only
    # punctuation (e.g. "...", "_=_") is an interop hazard → emit no alias.
    if localpart == "" or not String.match?(localpart, ~r/[a-z0-9]/) do
      :none
    else
      {:ok, localpart}
    end
  end

  def derive_alias_localpart(_), do: :none

  # Derive, register (with deterministic collision handling) and emit the canonical alias.
  # Fully non-fatal: every failure path logs a warning so the room stays created. Returns the timestamp of the last event of
  # the chain (the alias event's, else `last_ts` unchanged): step 8 (the invite events) continues from it.
  defp register_canonical_alias(room_id, creator_id, name, last_ts) do
    server_name = Application.get_env(:event_dispatcher, :server_name, "nebu.local")

    case derive_alias_localpart(name) do
      :none ->
        # No usable localpart (e.g. an all-invalid / emoji-only name) — room keeps its
        # m.room.name but gets no alias. Backwards compat / AC3.
        last_ts

      {:ok, base_localpart} ->
        base_localpart = bound_localpart(base_localpart, server_name)

        case base_localpart do
          "" ->
            last_ts

          _ ->
            try_register_alias(room_id, creator_id, server_name, base_localpart, 1, last_ts)
        end
    end
  rescue
    e ->
      Logger.warning("create_room: canonical-alias step raised for #{room_id} (non-fatal, #{db_error_class(e)})")

      last_ts
  end

  # Bound the localpart so the full `#localpart:server` alias is <= @alias_max_bytes.
  # The collision suffix (`-N`) is short relative to this budget; we reserve a few bytes
  # for it so a suffixed candidate also stays within the limit.
  defp bound_localpart(localpart, server_name) do
    # bytes available for the localpart = 255 - len("#") - len(":server") - reserve for "-NN"
    overhead = 1 + 1 + byte_size(server_name) + 4
    max_localpart = max(@alias_max_bytes - overhead, 0)

    localpart
    |> binary_part_safe(max_localpart)
    |> String.trim("-")
  end

  # Truncate to at most `max_bytes` bytes without splitting a UTF-8 codepoint. The
  # localpart is already restricted to ASCII allowlist chars, but stay codepoint-safe.
  defp binary_part_safe(str, max_bytes) when byte_size(str) <= max_bytes, do: str

  defp binary_part_safe(str, max_bytes) do
    str
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, size} ->
      gsize = byte_size(g)

      if size + gsize <= max_bytes do
        {:cont, {acc <> g, size + gsize}}
      else
        {:halt, {acc, size}}
      end
    end)
    |> elem(0)
  end

  # Deterministic collision loop: attempt #localpart:server, then #localpart-2:server,
  # … up to @alias_collision_retries. The DB unique constraint decides the winner
  # (race-safe — ADR-020); a {:error, :conflict} means another room already owns that
  # alias, so we try the next suffix. On the first successful insert we emit
  # m.room.canonical_alias and stop. Any non-conflict DB error / exhausted retries is
  # non-fatal (log + leave the room created).
  defp try_register_alias(room_id, _creator_id, _server_name, _base, attempt, last_ts)
       when attempt > @alias_collision_retries do
    Logger.warning(
      "create_room: exhausted alias-collision retries for #{room_id} (non-fatal); room created without alias"
    )

    last_ts
  end

  defp try_register_alias(room_id, creator_id, server_name, base_localpart, attempt, last_ts) do
    localpart = if attempt == 1, do: base_localpart, else: "#{base_localpart}-#{attempt}"
    alias_str = "##{localpart}:#{server_name}"

    case alias_db_module().insert_room_alias(alias_str, room_id, Nebu.DB.Helpers.now_ms()) do
      :ok ->
        # Alias registered → emit the canonical_alias state event via the same
        # signed/persisted/fanned-out path used for m.room.name. Already in
        # @writable_state_types and read by build_room_summary/3 → surfaces in sync +
        # space hierarchy with no proto change.
        case emit_state_event_at(room_id, creator_id, "m.room.canonical_alias", "", %{"alias" => alias_str}, last_ts + 1) do
          {:ok, _event_id, ts} ->
            ts

          {:error, reason} ->
            Logger.warning(
              "create_room: registered the derived alias but failed to emit m.room.canonical_alias for #{room_id} (non-fatal, #{db_error_class(reason)})"
            )

            last_ts
        end

      {:error, :conflict} ->
        # Alias taken — try the next deterministic suffix.
        try_register_alias(room_id, creator_id, server_name, base_localpart, attempt + 1, last_ts)

      {:error, reason} ->
        # D5e: no alias string (it is a slug of the room name = user content) and no inspect(reason)
        Logger.warning(
          "create_room: failed to register the derived canonical alias for #{room_id} (non-fatal, #{db_error_class(reason)})"
        )

        last_ts
    end
  end

  # ─── createRoom input validation (story create-room-input-validation, follow-ups ed / ee / eg / ei) ───────────────

  # Nebu policy (not in the Matrix spec): the room name is capped at 255 Unicode code points (D5c); a state `content`
  # nests at most 32 levels of maps / lists, the content object itself being level 1 (D5a). Story
  # create-room-presets-power-levels-topic (D5): the topic is capped at 1024 code points and an `m.topic` text body at
  # 4096 (Nebu policy, the spec has no limit).
  @name_max_codepoints 255
  @topic_max_codepoints 1024
  @topic_text_max_codepoints 4096
  @topic_text_max_entries 8
  @content_max_depth 32
  @canonical_alias_max 64

  # Matrix presets (CS API createRoom): `preset` enum, and the events of each (D2)
  @presets ~w(private_chat public_chat trusted_private_chat)
  @visibilities ~w(public private)
  @preset_state_types ~w(m.room.join_rules m.room.history_visibility m.room.guest_access)

  # initial_state types that are SKIPPED, not applied (see the long comment at apply_initial_state/4): m.room.create /
  # m.room.member (authoritative create / join setup), m.room.encryption (ADR-011), m.room.tombstone,
  # m.room.third_party_invite. Story power-levels-enforcement (D7, follow-up `er`): an m.room.power_levels entry is APPLIED at
  # step 6 (a full replacement through the room-process power-level writer), no longer skipped.
  @initial_state_forbidden_types ~w(m.room.create m.room.member m.room.encryption m.room.tombstone m.room.third_party_invite)

  @power_levels_type "m.room.power_levels"

  @doc false
  # Validates everything the client sent to createRoom BEFORE a room exists (D7). PURE except for the one alias-taken
  # read at the end. Returns :ok or raises Nebu.Matrix.Error (status :invalid_argument + a specific errcode, D6; the
  # message is FIXED text: no client value is ever echoed). First failure wins, in this order (deterministic for tests):
  #
  #   1. top-level `name`: non-string / NUL -> M_BAD_JSON
  #   2. name length (top-level, then each initial_state m.room.name entry) -> M_INVALID_PARAM; a non-string,
  #      non-null initial_state name -> M_BAD_JSON
  #   2a. `topic` (story create-room-presets-power-levels-topic, D5): top level, then each initial_state m.room.topic
  #      entry: non-string / NUL / malformed m.topic -> M_BAD_JSON, too long -> M_INVALID_PARAM
  #   2b. `creation_content` (JSON): nests more than 32 levels or contains a NUL -> M_BAD_JSON (no room is created; the
  #      m.room.create write is non-fatal, so an unwritable content would otherwise leave a room without create event)
  #   3. `room_version`: non-string -> M_BAD_JSON, unsupported string -> M_UNSUPPORTED_ROOM_VERSION
  #   4. `room_alias_name`: non-string -> M_BAD_JSON, invalid localpart -> M_INVALID_PARAM
  #   5. initial_state m.room.canonical_alias entries: syntax / types -> M_INVALID_PARAM, then mapping -> M_BAD_ALIAS
  #   5a. `preset` / `visibility` (D4): non-string -> M_BAD_JSON, unknown value -> M_INVALID_PARAM
  #   5b. `power_level_content_override` shape (D7): -> M_BAD_JSON
  #   5b'. each initial_state m.room.power_levels entry (story power-levels-enforcement, D7): a non-empty state key (also an `@`
  #      one) or a shape that `PowerLevels.validate_content/1` refuses -> M_BAD_JSON (a non-object content is refused by the
  #      router's structure check before)
  #   5c. `invite` (story create-room-invites-direct, D5): non-list / non-string element -> M_BAD_JSON, more than 50 raw
  #      entries / malformed id / the creator's own id -> M_INVALID_PARAM; de-duplicated (first occurrence wins)
  #   5d. `invite_3pid` (D6): non-list / malformed item -> M_BAD_JSON, a list of well-shaped items -> 403 M_THREEPID_DENIED
  #   5e. invitee domains (D3, pure): another server -> 403 M_FORBIDDEN
  #   5f. creator lock-out (D7, D10): the levels IN EFFECT at each planned event keep the creator out of a state event the
  #      server writes on his behalf, or (with invitees) out of the `invite` level -> M_INVALID_ROOM_STATE; an initial_state
  #      m.room.power_levels entry is a v10 CHANGE by the creator against the levels before it (story power-levels-enforcement,
  #      D7) -> M_INVALID_ROOM_STATE
  #   5g. event sizes (story event-size-limit, D6; pure, after every depth check because `Jason.encode!` recurses): the
  #      `m.room.create` event with the merged creation_content, the `m.room.power_levels` event with the merged levels
  #      (invitees of a trusted_private_chat included) and EVERY initial_state entry (also those that `apply_initial_state/4`
  #      will skip) must stay within `Nebu.Matrix.EventSize` -> 413 M_TOO_LARGE, fixed texts naming the source. Runs before
  #      the alias read: a refused request costs no statement and creates nothing.
  #   6. alias-taken pre-check -> M_ROOM_IN_USE (a store error is a 500)
  #   7. invitee existence (D3): one query, an unknown or deactivated local account -> 404 M_NOT_FOUND
  #      (a store error is a 500)
  #   8. pending-invitation caps (story rate-limits-join-invite-create-room, D6, D7; only with invitees, the last read): the
  #      room does not exist yet, so every invitee is a NEW pending row and the check is exact -> 403 M_FORBIDDEN, fixed texts
  #      (a failing count read is a 500). Step 8 of create_room/2 then invites with `caps: :prechecked`.
  @spec validate_create_room_request(struct() | map()) :: :ok
  def validate_create_room_request(request) do
    name = Map.get(request, :name)
    topic = Map.get(request, :topic)
    entries = initial_state_entries(Map.get(request, :initial_state_json))

    validate_create_name(name)
    Enum.each(entries, &validate_initial_state_name_entry/1)
    validate_create_topic(topic)
    Enum.each(entries, &validate_initial_state_topic_entry/1)
    Enum.each(entries, &validate_initial_state_access_entry/1)
    validate_creation_content(Map.get(request, :creation_content_json))
    validate_create_room_version(Map.get(request, :room_version))

    localpart = Map.get(request, :room_alias_name)
    explicit = validate_room_alias_name(localpart)

    validate_initial_state_aliases(entries, explicit)

    preset = Map.get(request, :preset)
    visibility = Map.get(request, :visibility)
    validate_preset(preset)
    validate_visibility(visibility)

    override = validate_power_level_override(Map.get(request, :power_level_content_override))
    Enum.each(entries, &validate_initial_state_power_levels_entry/1)

    invitees = validate_invite_list(Map.get(request, :invite), Map.get(request, :creator_id))
    validate_invite_3pid(Map.get(request, :invite_3pid))
    Enum.each(invitees, &ensure_local_invitee!/1)

    check_creator_lock_out(request, entries, explicit, effective_preset(preset, visibility), override, invitees)

    check_event_sizes!(request, entries, override, invitees, effective_preset(preset, visibility))

    # story state-writer-redaction (D10 (b)): after the size rule (an oversized entry of a type that is skipped stays a 413: one rule, no run-time dependency)
    Enum.each(entries, &validate_initial_state_foreign_key(&1, Map.get(request, :creator_id)))

    check_explicit_alias_free(explicit)
    ensure_invitees_exist!(invitees)
    check_invite_caps!(Map.get(request, :creator_id), invitees)
    :ok
  end

  # Step 5g (story event-size-limit, D6): the events whose content the client sizes. The envelope uses the creator as sender and a
  # room id PLACEHOLDER of the exact length of a generated one (`room_id_with/1`), so the prediction equals the stored size; the
  # top-level name / topic and the preset, alias, member and invite events are bounded far below the limit by existing rules.
  # First failure wins: create, power levels, then every initial_state entry in list order (type, state key, size).
  defp check_event_sizes!(request, entries, override, invitees, preset) do
    creator = Map.get(request, :creator_id)
    room_id = room_id_with(String.duplicate("0", 16))
    ts = Nebu.DB.Helpers.now_ms()

    client_creation_content =
      case Jason.decode(Map.get(request, :creation_content_json, "") || "") do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    create_content =
      Map.merge(client_creation_content, %{"creator" => creator, "room_version" => Nebu.Matrix.RoomVersions.default()})

    check_content_size!(room_id, creator, "m.room.create", "", create_content, ts, Nebu.Matrix.EventSize.message(:creation_content_too_large))

    level_invitees = if preset == "trusted_private_chat", do: invitees, else: []

    check_content_size!(
      room_id,
      creator,
      "m.room.power_levels",
      "",
      merged_power_levels(creator, override, level_invitees),
      ts,
      Nebu.Matrix.EventSize.message(:power_levels_too_large)
    )

    Enum.each(entries, fn entry ->
      type = entry["type"]
      state_key = if is_binary(entry["state_key"]), do: entry["state_key"], else: ""
      content = if is_map(entry["content"]), do: entry["content"], else: %{}

      case Nebu.Matrix.EventSize.check_keys(type, state_key, creator) do
        {:error, :type_too_long} -> too_large!(Nebu.Matrix.EventSize.message(:initial_state_type_too_long))
        {:error, :state_key_too_long} -> too_large!(Nebu.Matrix.EventSize.message(:initial_state_key_too_long))
        # `sender_too_long` is the router's 403 (the creator is the authenticated user)
        _ -> check_content_size!(room_id, creator, type, state_key, content, ts, Nebu.Matrix.EventSize.message(:initial_state_event_too_large))
      end
    end)

    :ok
  end

  defp check_content_size!(room_id, sender, type, state_key, content, ts, message) do
    envelope = Nebu.Matrix.EventSize.envelope(room_id, sender, if(is_binary(type), do: type, else: ""), state_key, ts)

    case Nebu.Matrix.EventSize.check(envelope, byte_size(Jason.encode!(content))) do
      :ok -> :ok
      {:error, :event_too_large} -> too_large!(message)
    end
  end

  defp too_large!(message), do: raise(Nebu.Matrix.Error, status: Nebu.Matrix.Status.too_large(), message: message)

  # ─── invite / invite_3pid (story create-room-invites-direct, D3, D5, D6) ──────────────────────────────────────────

  # Nebu policy (the spec has no limit): at most 50 `invite` entries, counted RAW (before the de-duplication)
  @invite_max_entries 50
  # a Matrix user id is at most 255 bytes (spec grammar); the id regex has no length bound of its own
  @user_id_max_bytes 255
  @invite_3pid_keys ~w(id_server id_access_token medium address)

  @doc "The createRoom `invite` cap (50 raw entries); public so that the rate-limit tier configuration can be checked against it."
  @spec invite_max_entries() :: pos_integer()
  def invite_max_entries, do: @invite_max_entries

  # ─── pending-invitation caps (story rate-limits-join-invite-create-room, D6, D7, D8) ───────────────────────────────

  @default_invite_max_pending %{per_inviter: 500, per_invitee: 100, per_pair: 10}
  @inviter_cap_text "You have too many pending invitations: wait until some of them are accepted or declined"
  @pair_cap_text "You have too many pending invitations to this user"
  @invitee_cap_text "The invited user has too many pending invitations"

  @doc """
  The caps on PENDING invitations, read at call time: per inviter (all rooms) 500, per invitee (all inviters) 100, per
  (inviter, invitee) pair 10. Overridden by `NEBU_INVITE_MAX_PENDING_PER_INVITER` / `_PER_INVITEE` / `_PER_PAIR` (through
  `config :nebu, :invite_max_pending_per_inviter | _per_invitee | _per_pair`); anything but a strictly positive integer keeps the
  default (never a zero cap, never a crash). The caps are state limits, NOT disabled by `NEBU_RATE_LIMIT_DISABLED`.
  """
  @spec invite_max_pending() :: %{per_inviter: pos_integer(), per_invitee: pos_integer(), per_pair: pos_integer()}
  def invite_max_pending do
    %{
      per_inviter: cap_setting(:invite_max_pending_per_inviter, :per_inviter),
      per_invitee: cap_setting(:invite_max_pending_per_invitee, :per_invitee),
      per_pair: cap_setting(:invite_max_pending_per_pair, :per_pair)
    }
  end

  defp cap_setting(key, name) do
    case Application.get_env(:nebu, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> Map.fetch!(@default_invite_max_pending, name)
    end
  end

  # D6 / D7: `invitees` are the NEW pending rows of ONE request (createRoom: the de-duplicated list; POST /invite: `[invitee]`).
  # The PRE-CHECK: counted BEFORE the write by ONE bounded read, so that a refused request writes nothing (and a refused createRoom
  # creates no room). First failure wins: the inviter cap, then the invitees in list order, the pair cap before the invitee total
  # (`InviteDB.first_cap_violation/3`). Fixed texts, no id and no number echoed (permission_denied + errcode: Http.map_error/1 -> 403).
  # The pre-check alone is count-then-write; the rows themselves are written by `InviteDB.insert_invitation_capped/4`, which counts
  # again under the advisory locks of the inviter and the invitee, so concurrent requests can never exceed a cap (review cycle 1,
  # Kassandra M-1c).
  defp check_invite_caps!(_inviter, []), do: :ok

  defp check_invite_caps!(inviter, invitees) do
    caps = invite_max_pending()
    counts = pending_counts!(inviter, invitees, Nebu.Matrix.Room.InviteDB.count_bound(caps))

    case Nebu.Matrix.Room.InviteDB.first_cap_violation(counts, invitees, caps) do
      nil -> :ok
      violated -> cap_refused!(violated)
    end
  end

  defp cap_refused!(violated) do
    raise Nebu.Matrix.Error,
      status: Nebu.Matrix.Status.permission_denied(),
      errcode: "M_FORBIDDEN",
      message: cap_text(violated)
  end

  defp cap_text(:inviter), do: @inviter_cap_text
  defp cap_text(:pair), do: @pair_cap_text
  defp cap_text(:invitee), do: @invitee_cap_text

  # A failing (or raising) count read is FAIL CLOSED: 500 before anything is written, value-free ERROR log (error class only).
  defp pending_counts!(inviter, invitees, bound) do
    result =
      try do
        db_module_invite().pending_invite_counts(inviter, invitees, bound)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, %{inviter: n, invitees: per_invitee} = counts} when is_integer(n) and is_map(per_invitee) ->
        counts

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("invite: failed to read the pending invitation counts (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "invite: the invitation counts are unavailable"
    end
  end

  @invite_forbidden_text "Users of other servers cannot be invited: this server does not federate"
  @invite_not_found_text "The user to invite does not exist on this server"
  @threepid_denied_text "Third-party invites are not supported on this server"

  # The validated, de-duplicated `invite` list of a request that passed validate_create_room_request/1 (first occurrence
  # wins, list order kept). nil / absent = no invitations.
  defp invitee_list(request) do
    case Map.get(request, :invite) do
      list when is_list(list) -> Enum.uniq(list)
      _ -> []
    end
  end

  # D5: returns the de-duplicated list. Fixed messages, never a client value.
  defp validate_invite_list(nil, _creator_id), do: []

  defp validate_invite_list(invite, creator_id) when is_list(invite) do
    if length(invite) > @invite_max_entries,
      do: reject!("M_INVALID_PARAM", "invite must not contain more than #{@invite_max_entries} user ids")

    unless Enum.all?(invite, &is_binary/1), do: reject!("M_BAD_JSON", "invite must be a list of user id strings")
    unless Enum.all?(invite, &(byte_size(&1) <= @user_id_max_bytes and Nebu.Matrix.UserId.valid?(&1))),
      do: reject!("M_INVALID_PARAM", "invite contains a malformed user id")

    if creator_id in invite, do: reject!("M_INVALID_PARAM", "invite must not contain the room creator")

    Enum.uniq(invite)
  end

  defp validate_invite_list(_other, _creator_id), do: reject!("M_BAD_JSON", "invite must be a list of user ids")

  # D6: [] / nil ok; a non-list or a malformed item (checked over the WHOLE list first) is M_BAD_JSON; a list of only
  # well-shaped items is refused (Nebu has no identity server): 403 M_THREEPID_DENIED.
  defp validate_invite_3pid(nil), do: :ok
  defp validate_invite_3pid([]), do: :ok

  defp validate_invite_3pid(items) when is_list(items) do
    unless Enum.all?(items, &well_shaped_3pid?/1),
      do: reject!("M_BAD_JSON", "invite_3pid items must be objects with the string fields id_server, id_access_token, medium and address")

    threepid_denied!()
  end

  defp validate_invite_3pid(_other), do: reject!("M_BAD_JSON", "invite_3pid must be a list")

  # An item of `invite_3pid` (and the 3pid form of POST /invite): an object holding all four required keys as strings.
  defp well_shaped_3pid?(item) when is_map(item),
    do: Enum.all?(@invite_3pid_keys, fn key -> is_binary(Map.get(item, key)) end)

  defp well_shaped_3pid?(_item), do: false

  defp threepid_denied! do
    raise Nebu.Matrix.Error,
      status: Nebu.Matrix.Status.permission_denied(),
      errcode: "M_THREEPID_DENIED",
      message: @threepid_denied_text
  end

  # D3 (pure): only users of THIS server can be invited, Nebu does not federate. 403 M_FORBIDDEN, fixed text (no id echoed).
  defp ensure_local_invitee!(invitee) do
    unless local_domain?(invitee) do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        errcode: "M_FORBIDDEN",
        message: @invite_forbidden_text
    end
  end

  # D3: ONE read for the whole list (createRoom: the de-duplicated list; POST /invite: [invitee]). Every id must be an
  # existing ACTIVE account; an unknown and a deactivated one are indistinguishable (same 404, same fixed text, no id
  # echoed). A failing read is a 500 (fail closed). Never provisions a `users` row.
  defp ensure_invitees_exist!([]), do: :ok

  defp ensure_invitees_exist!(invitees) do
    result =
      try do
        rooms_db_module().invitable_local_users(invitees)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, found} when is_list(found) ->
        found = MapSet.new(found)

        unless Enum.all?(invitees, &MapSet.member?(found, &1)) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.not_found(),
            errcode: "M_NOT_FOUND",
            message: @invite_not_found_text
        end

        :ok

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("invite: failed to read the invitee accounts (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "invite: the invitee accounts are unavailable"
    end
  end

  # The decoded initial_state entries that are objects (apply_initial_state/3 skips every other shape, the router has
  # already rejected them with 400 M_BAD_JSON).
  defp initial_state_entries(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  defp initial_state_entries(_json), do: []

  defp reject!(errcode, message) do
    raise Nebu.Matrix.Error,
      status: Nebu.Matrix.Status.invalid_argument(),
      errcode: errcode,
      message: message
  end

  # nil / "" = no name. Anything else must be a NUL-free string of at most 255 code points.
  defp validate_create_name(nil), do: :ok
  defp validate_create_name(name) when is_binary(name), do: validate_name_string(name, "name")
  defp validate_create_name(_other), do: reject!("M_BAD_JSON", "name must be a string")

  defp validate_name_string(name, what) do
    cond do
      String.contains?(name, <<0>>) -> reject!("M_BAD_JSON", "#{what} must not contain NUL characters")
      name_too_long?(name) -> reject!("M_INVALID_PARAM", "#{what} must not exceed #{@name_max_codepoints} characters")
      true -> :ok
    end
  end

  defp name_too_long?(name), do: too_long?(name, @name_max_codepoints)

  # a code point is at most 4 bytes: more than 4 x cap bytes is too long without materialising the code points
  defp too_long?(string, cap),
    do: byte_size(string) > 4 * cap or length(String.codepoints(string)) > cap

  # An initial_state m.room.name entry: the `name` of its content follows the same rule as the top-level name, but
  # absent / null / "" are valid (= no name, StateEvent semantics).
  defp validate_initial_state_name_entry(%{"type" => "m.room.name", "content" => content}) when is_map(content) do
    validate_name_content(content)
  end

  defp validate_initial_state_name_entry(_entry), do: :ok

  # the `content` of an m.room.name event (initial_state and PUT alike): "name" absent / null / "" = no name; a string is
  # NUL-free and capped; any other type is M_BAD_JSON.
  defp validate_name_content(content) do
    case Map.get(content, "name") do
      nil -> :ok
      "" -> :ok
      name when is_binary(name) -> validate_name_string(name, "name")
      _other -> reject!("M_BAD_JSON", "name must be a string")
    end
  end

  # ─── topic (story create-room-presets-power-levels-topic, D5) ─────────────────────────────────────────────────────

  # Top-level topic: nil (absent; the router refuses a present JSON null) = no topic event. A string (incl. "", which is
  # written and clears an initial_state topic) is NUL-free and at most 1024 code points; any other type is M_BAD_JSON.
  defp validate_create_topic(nil), do: :ok
  defp validate_create_topic(topic) when is_binary(topic), do: validate_topic_string(topic)
  defp validate_create_topic(_other), do: reject!("M_BAD_JSON", "topic must be a string")

  defp validate_topic_string(topic) do
    cond do
      String.contains?(topic, <<0>>) -> reject!("M_BAD_JSON", "topic must not contain NUL characters")
      too_long?(topic, @topic_max_codepoints) -> reject!("M_INVALID_PARAM", "topic must not exceed #{@topic_max_codepoints} characters")
      true -> :ok
    end
  end

  # An initial_state m.room.topic entry of the room's own slot (state_key ""): the content follows the same rule as the
  # PUT path. An entry with another state_key is not the room topic: no rule.
  defp validate_initial_state_topic_entry(%{"type" => "m.room.topic", "content" => content} = entry) when is_map(content) do
    if (entry["state_key"] || "") == "", do: validate_topic_content(content), else: :ok
  end

  defp validate_initial_state_topic_entry(_entry), do: :ok

  # Story history-visibility-enforcement (security cycle 1, follow-up `gj`): the content of `m.room.history_visibility` /
  # `m.room.guest_access` with the empty state key (PUT state and createRoom `initial_state`; the upgrade copy stays tolerant) must
  # carry one of the spec's values: an unknown value would silently read as `shared` / be ignored. 400 M_BAD_JSON, fixed texts.
  @history_visibility_type "m.room.history_visibility"
  @guest_access_type "m.room.guest_access"
  @history_visibility_values ~w(invited joined shared world_readable)
  @guest_access_values ~w(can_join forbidden)

  defp validate_initial_state_access_entry(%{"type" => type, "content" => content} = entry)
       when type in [@history_visibility_type, @guest_access_type] and is_map(content) do
    if (entry["state_key"] || "") == "", do: validate_access_content(type, content), else: :ok
  end

  defp validate_initial_state_access_entry(_entry), do: :ok

  @doc false
  def validate_access_content(@history_visibility_type, content) when is_map(content) do
    unless content["history_visibility"] in @history_visibility_values,
      do: reject!("M_BAD_JSON", "history_visibility must be one of invited, joined, shared, world_readable")

    :ok
  end

  def validate_access_content(@guest_access_type, content) when is_map(content) do
    unless content["guest_access"] in @guest_access_values, do: reject!("M_BAD_JSON", "guest_access must be can_join or forbidden")
    :ok
  end

  def validate_access_content(@history_visibility_type, _content), do: reject!("M_BAD_JSON", "history_visibility must be one of invited, joined, shared, world_readable")
  def validate_access_content(@guest_access_type, _content), do: reject!("M_BAD_JSON", "guest_access must be can_join or forbidden")

  # The `content` of an m.room.topic event (initial_state and PUT alike, hence the Admin Space form too): `topic`
  # absent / null / "" is valid, any other non-string is M_BAD_JSON, a string is capped (M_INVALID_PARAM); `m.topic`
  # (v1.15) absent / null or {"m.text": absent | [ {"body": string (<= 4096 code points), "mimetype": optional string} ]}.
  # `m.topic` may differ from `topic` (not cross-checked). The cap is otherwise bypassable: RoomSummary shows the
  # m.topic text/plain body first.
  @doc false
  def validate_topic_content(content) when is_map(content) do
    case Map.get(content, "topic") do
      nil -> :ok
      topic when is_binary(topic) -> validate_topic_string(topic)
      _other -> reject!("M_BAD_JSON", "topic must be a string")
    end

    case Map.get(content, "m.topic") do
      nil -> :ok
      m_topic when is_map(m_topic) -> validate_m_topic(m_topic)
      _other -> reject!("M_BAD_JSON", "m.topic must be an object")
    end
  end

  defp validate_m_topic(m_topic) do
    case Map.get(m_topic, "m.text") do
      nil -> :ok
      texts when is_list(texts) ->
        # Nebu policy (review cycle 1, F-10): at most 8 representations (text/plain, text/html, ...), each body capped
        if length(texts) > @topic_text_max_entries,
          do: reject!("M_INVALID_PARAM", "m.topic m.text must not have more than #{@topic_text_max_entries} entries")

        Enum.each(texts, &validate_m_topic_text/1)

      _other -> reject!("M_BAD_JSON", "m.topic m.text must be a list")
    end
  end

  defp validate_m_topic_text(%{"body" => body} = text) when is_binary(body) do
    case Map.get(text, "mimetype") do
      nil -> :ok
      mimetype when is_binary(mimetype) -> :ok
      _other -> reject!("M_BAD_JSON", "m.topic mimetype must be a string")
    end

    cond do
      String.contains?(body, <<0>>) -> reject!("M_BAD_JSON", "m.topic must not contain NUL characters")
      too_long?(body, @topic_text_max_codepoints) -> reject!("M_INVALID_PARAM", "m.topic text must not exceed #{@topic_text_max_codepoints} characters")
      true -> :ok
    end
  end

  defp validate_m_topic_text(_other), do: reject!("M_BAD_JSON", "m.topic m.text must be a list of objects with a string body")

  # The content of the top-level topic event (D5): `""` is written as {"topic": ""} without an m.topic block.
  defp topic_event_content(""), do: %{"topic" => ""}

  defp topic_event_content(topic),
    do: %{"topic" => topic, "m.topic" => %{"m.text" => [%{"body" => topic, "mimetype" => "text/plain"}]}}

  # ─── preset / visibility (D2, D4) ─────────────────────────────────────────────────────────────────────────────────

  defp validate_preset(nil), do: :ok
  defp validate_preset(preset) when preset in @presets, do: :ok
  defp validate_preset(preset) when is_binary(preset), do: reject!("M_INVALID_PARAM", "preset must be private_chat, public_chat or trusted_private_chat")
  defp validate_preset(_other), do: reject!("M_BAD_JSON", "preset must be a string")

  defp validate_visibility(nil), do: :ok
  defp validate_visibility(visibility) when visibility in @visibilities, do: :ok
  defp validate_visibility(visibility) when is_binary(visibility), do: reject!("M_INVALID_PARAM", "visibility must be public or private")
  defp validate_visibility(_other), do: reject!("M_BAD_JSON", "visibility must be a string")

  # Spec: "If unspecified, the server should use the visibility to determine which preset to use": public ->
  # public_chat, private (the default) -> private_chat.
  defp effective_preset(preset, _visibility) when is_binary(preset), do: preset
  defp effective_preset(_preset, "public"), do: "public_chat"
  defp effective_preset(_preset, _visibility), do: "private_chat"

  # The three preset events of a preset (D2): trusted_private_chat writes the same events as private_chat (its invitee
  # power level rule is applied at spec step 3, story create-room-invites-direct D9).
  defp preset_events("public_chat"),
    do: [
      {"m.room.join_rules", %{"join_rule" => "public"}},
      {"m.room.history_visibility", %{"history_visibility" => "shared"}},
      {"m.room.guest_access", %{"guest_access" => "forbidden"}}
    ]

  defp preset_events(_private_or_trusted),
    do: [
      {"m.room.join_rules", %{"join_rule" => "invite"}},
      {"m.room.history_visibility", %{"history_visibility" => "shared"}},
      {"m.room.guest_access", %{"guest_access" => "can_join"}}
    ]

  # The preset types an applied initial_state entry for (type, "") replaces (Synapse parity, not spec text: the preset
  # event is not written; state_key "" only; skipped types do not count, and none of the three is skipped).
  defp initial_state_preset_types(entries) do
    for %{"type" => type} = entry <- entries,
        type in @preset_state_types,
        (entry["state_key"] || "") == "",
        is_map(entry["content"]),
        uniq: true,
        do: type
  end

  # ─── power_level_content_override (D7) ────────────────────────────────────────────────────────────────────────────

  # Returns the validated override map (%{} when absent / nil). Shape errors are M_BAD_JSON with FIXED messages. Story
  # power-levels-enforcement (D3): the shape is the ONE validator of every levels write, `PowerLevels.validate_content/1`; this
  # wrapper keeps the override's own texts for the depth, NUL and null rules.
  defp validate_power_level_override(nil), do: %{}

  defp validate_power_level_override(override) when is_map(override) do
    cond do
      content_too_deep?(override) -> reject!("M_BAD_JSON", "power_level_content_override is nested too deeply")
      contains_nul?(override) -> reject!("M_BAD_JSON", "power_level_content_override must not contain NUL characters")
      true -> :ok
    end

    case Nebu.Matrix.Room.PowerLevels.validate_content(override) do
      :ok ->
        override

      {:error, text} ->
        if text == Nebu.Matrix.Room.PowerLevels.null_text(),
          do: reject!("M_BAD_JSON", "power_level_content_override must not contain null values"),
          else: reject!("M_BAD_JSON", text)
    end
  end

  defp validate_power_level_override(_other), do: reject!("M_BAD_JSON", "power_level_content_override must be an object")

  # step 5b' (story power-levels-enforcement, D7): an initial_state m.room.power_levels entry needs the empty state key (the D3
  # rule wins over every other key rule, an `@` key included) and a content of the strict v10 shape
  defp validate_initial_state_power_levels_entry(%{"type" => @power_levels_type} = entry) do
    if (entry["state_key"] || "") != "", do: reject!("M_BAD_JSON", "m.room.power_levels requires an empty state key")

    case Nebu.Matrix.Room.PowerLevels.validate_content(entry["content"]) do
      :ok -> :ok
      {:error, text} -> reject!("M_BAD_JSON", text)
    end
  end

  defp validate_initial_state_power_levels_entry(_entry), do: :ok

  # story state-writer-redaction (D10 (b)): the v10 `@` rule on EVERY initial_state entry, `m.room.member` included (a stricter Nebu
  # rule): a state key starting with `@` that is not the creator's id is refused before the room exists
  defp validate_initial_state_foreign_key(%{"state_key" => key}, creator_id) when is_binary(key) do
    if String.starts_with?(key, "@") and key != creator_id,
      do: reject!("M_INVALID_ROOM_STATE", "The initial state contains a state key of another user")

    :ok
  end

  defp validate_initial_state_foreign_key(_entry, _creator_id), do: :ok

  # The power levels written at spec step 3: the default levels with the creator at 100, the override applied on top as a
  # SHALLOW merge (top-level keys replace; Synapse parity).
  #
  # Story create-room-invites-direct (D9): `invitees` (the validated invite list of a `trusted_private_chat`; [] otherwise)
  # get the creator's level (100) BEFORE the override is merged on top, so a shallow override `users` map replaces them.
  defp merged_power_levels(creator_id, override, invitees) do
    base = put_in(Nebu.Matrix.Room.Server.default_power_levels(), ["users", creator_id], 100)

    invitees
    |> Enum.reduce(base, fn invitee, acc -> put_in(acc, ["users", invitee], 100) end)
    |> Map.merge(override)
  end

  defp request_power_level_override(request) do
    case Map.get(request, :power_level_content_override) do
      override when is_map(override) -> override
      _ -> %{}
    end
  end

  # D7 creator lock-out (the spec's own M_INVALID_ROOM_STATE example). Story power-levels-enforcement (D7, D12): simulated with
  # the levels IN EFFECT at each planned event, in the write order of do_create_room/3 (the explicit alias and the preset
  # events under the step-3 levels, each initial_state entry under the levels before it, name / topic / the derived alias
  # under the last levels): the creator must reach `events[type]` (else `state_default`) of every state event the server
  # writes on his behalf. An initial_state m.room.power_levels entry must ALSO be a valid v10 change by the creator against the
  # levels before it (spec: "checking power levels for each event"), and then replaces them (no merge).
  #
  # Story create-room-invites-direct (D10): with a non-empty invite list the creator must also reach the `invite` level of the
  # final levels, or the invite events of step 8 would be refused by the room's own rules.
  defp check_creator_lock_out(request, entries, explicit, preset, override, invitees) do
    creator_id = Map.get(request, :creator_id)
    level_invitees = if preset == "trusted_private_chat", do: invitees, else: []

    final_levels =
      Enum.reduce(planned_steps(request, entries, explicit, preset), merged_power_levels(creator_id, override, level_invitees), fn
        {:state, type}, levels ->
          require_creator_level!(levels, creator_id, type)
          levels

        {:power_levels, content}, levels ->
          require_creator_level!(levels, creator_id, @power_levels_type)

          case Nebu.Matrix.Room.PowerLevels.check_change(levels, content, creator_id) do
            :ok -> content
            {:error, _rule} -> reject!("M_INVALID_ROOM_STATE", "The initial power levels cannot grant more than the room creator has")
          end
      end)

    if invitees != [] and not Nebu.Matrix.Room.PowerLevels.can?(final_levels, creator_id, :invite) do
      reject!("M_INVALID_ROOM_STATE", "The power levels do not allow the room creator to invite users")
    end
  end

  defp require_creator_level!(levels, creator_id, type) do
    unless Nebu.Matrix.Room.PowerLevels.can?(levels, creator_id, {:state, type}) do
      reject!("M_INVALID_ROOM_STATE", "The power levels do not allow the room creator to set the initial room state")
    end
  end

  # Every state event do_create_room/3 writes after step 3, IN WRITE ORDER (pure mirror of the write plan): `{:state, type}`, or
  # `{:power_levels, content}` for an applied initial_state m.room.power_levels entry.
  defp planned_steps(request, entries, explicit, preset) do
    replaced = initial_state_preset_types(entries)
    name = Map.get(request, :name)
    topic = Map.get(request, :topic)
    named? = is_binary(name) and name != ""

    explicit_alias = if explicit, do: [{:state, "m.room.canonical_alias"}], else: []
    preset_steps = for {type, _content} <- preset_events(preset), type not in replaced, do: {:state, type}

    # apply_initial_state/4 drops exact duplicates and skips the forbidden types and non-object contents
    applied_entries =
      for %{"type" => type} = entry <- Enum.uniq(entries),
          is_binary(type) and type != "",
          type not in @initial_state_forbidden_types,
          is_map(entry["content"]),
          do: if(type == @power_levels_type, do: {:power_levels, entry["content"]}, else: {:state, type})

    name_steps = if named?, do: [{:state, "m.room.name"}], else: []
    topic_steps = if is_binary(topic), do: [{:state, "m.room.topic"}], else: []
    derived_alias = if named? and is_nil(explicit), do: [{:state, "m.room.canonical_alias"}], else: []

    explicit_alias ++ preset_steps ++ applied_entries ++ name_steps ++ topic_steps ++ derived_alias
  end

  # creation_content is merged into the m.room.create content: the same depth / NUL bounds as initial_state content,
  # checked before anything recursive (CanonicalJson, the NUL scan) walks it (Kassandra L-2).
  defp validate_creation_content(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, content} when is_map(content) ->
        cond do
          content_too_deep?(content) -> reject!("M_BAD_JSON", "creation_content is nested too deeply")
          contains_nul?(content) -> reject!("M_BAD_JSON", "creation_content must not contain NUL characters")
          true -> :ok
        end

      _ ->
        :ok
    end
  end

  defp validate_creation_content(_json), do: :ok

  defp validate_create_room_version(nil), do: :ok

  defp validate_create_room_version(version) when is_binary(version) do
    if Nebu.Matrix.RoomVersions.supported?(version),
      do: :ok,
      else: reject!("M_UNSUPPORTED_ROOM_VERSION", "This server does not support the requested room version")
  end

  defp validate_create_room_version(_other), do: reject!("M_BAD_JSON", "room_version must be a string")

  # Returns nil (no explicit alias) or the full alias "#<localpart>:<server_name>" after the syntax checks.
  #   SPEC grammar (appendices, Room Aliases): the localpart has no ":" and no NUL; the whole alias incl. "#" and domain is
  #   at most 255 BYTES; non-surrogate code points only (a lone surrogate never survives JSON decoding; a binary that is
  #   not valid UTF-8 is refused for internal callers).
  #   NEBU POLICY (stricter than the grammar): an empty localpart, any whitespace (Synapse parity) and every Unicode
  #   control (Cc: C0, DEL, C1) or format (Cf: zero-width, bidi override / isolate, BOM) character (Kassandra L-1:
  #   invisible characters make look-alike aliases). Case / homoglyph / reserved-name policy is follow-up `eo`.
  defp validate_room_alias_name(nil), do: nil

  defp validate_room_alias_name(localpart) when is_binary(localpart) do
    invalid = fn -> reject!("M_INVALID_PARAM", "room_alias_name is not a valid alias localpart") end

    cond do
      not String.valid?(localpart) -> invalid.()
      localpart == "" -> invalid.()
      String.contains?(localpart, [":", <<0>>]) -> invalid.()
      Regex.match?(~r/[\s\p{Cc}\p{Cf}]/u, localpart) -> invalid.()
      byte_size(full_alias(localpart)) > @alias_max_bytes -> invalid.()
      true -> full_alias(localpart)
    end
  end

  defp validate_room_alias_name(_other), do: reject!("M_BAD_JSON", "room_alias_name must be a string")

  defp full_alias(localpart), do: "#" <> localpart <> ":" <> server_name()

  # exactly as register_canonical_alias/3 reads it (it may contain a port)
  defp server_name, do: Application.get_env(:event_dispatcher, :server_name, "nebu.local")

  # nil | "#<localpart>:<server_name>" of a request that passed validate_create_room_request/1.
  defp explicit_alias_for(request) do
    case Map.get(request, :room_alias_name) do
      localpart when is_binary(localpart) -> full_alias(localpart)
      _ -> nil
    end
  end

  # D4 (initial_state path): there is no current state and the only alias that can map to a not-yet-existing room is
  # the one of `room_alias_name`. Every alias of every m.room.canonical_alias entry (any state_key) must be grammar-valid
  # (M_INVALID_PARAM, all entries first) and equal that alias (M_BAD_ALIAS). Without room_alias_name only entries
  # without aliases pass.
  defp validate_initial_state_aliases(entries, explicit) do
    aliases =
      entries
      |> Enum.filter(&(&1["type"] == "m.room.canonical_alias" and is_map(&1["content"])))
      |> Enum.flat_map(&canonical_alias_set!(&1["content"]))

    Enum.each(aliases, &validate_alias_syntax!/1)

    Enum.each(aliases, fn alias_str ->
      unless alias_str == explicit, do: reject!("M_BAD_ALIAS", "The alias does not point to this room")
    end)
  end

  # The pre-check of an explicit alias (fast path only: the PK of room_aliases decides a race, see
  # register_explicit_alias/3). The only DB read of the validation.
  defp check_explicit_alias_free(nil), do: :ok

  defp check_explicit_alias_free(alias_str) do
    case alias_db_module().lookup_alias(alias_str) do
      {:error, :not_found} ->
        :ok

      {:ok, _room_id} ->
        reject!("M_ROOM_IN_USE", "Room alias already in use")

      {:error, reason} ->
        Logger.error("create_room: alias pre-check failed (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "create_room: alias lookup failed"
    end
  end

  # Spec step 4: register the explicit alias (PK = authoritative) and emit m.room.canonical_alias. NO -2 suffix fallback.
  defp register_explicit_alias(room_id, creator_id, alias_str) do
    case alias_db_module().insert_room_alias(alias_str, room_id, Nebu.DB.Helpers.now_ms()) do
      :ok ->
        :ok

      {:error, :conflict} ->
        # lost the race between the pre-check and the insert
        reject!("M_ROOM_IN_USE", "Room alias already in use")

      {:error, reason} ->
        Logger.error("create_room: failed to register the explicit alias for #{room_id} (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "create_room: failed to register the room alias for #{room_id}"
    end

    case emit_state_event_at(room_id, creator_id, "m.room.canonical_alias", "", %{"alias" => alias_str}, 0) do
      {:ok, _event_id, ts} ->
        # The timestamp the following initial_state entries must exceed: origin_server_ts is millisecond-granular and
        # Room.DB.get_generic_state_events/1 picks the latest event per (type, state_key) by it alone, so an
        # initial_state m.room.canonical_alias entry (applied next, it must win by spec order) emitted in the SAME
        # millisecond would tie. The tie would also be an events.event_id PK collision (the id hashes the event incl.
        # its timestamp). apply_initial_state/4 therefore stamps every entry with max(now, previous ts + 1): no sleep,
        # no waiting, strictly increasing and deterministic.
        ts

      {:error, reason} ->
        Logger.error("create_room: failed to write the explicit m.room.canonical_alias for #{room_id} (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "create_room: failed to write the room alias event for #{room_id}"
    end
  end


  # ─── m.room.canonical_alias content (D4): one pure validator for the PUT and the initial_state path ─────────────

  # The SET of aliases a canonical_alias content names: {alias (when non-empty)} + alt_aliases, duplicates counted once.
  # `alias` absent / null / "" = no canonical alias; `alt_aliases` absent / null or a list of strings (it may be set
  # while `alias` is empty). Any other type raises M_INVALID_PARAM. The content itself is stored as sent.
  defp canonical_alias_set!(content) when is_map(content) do
    primary =
      case Map.get(content, "alias") do
        nil -> []
        "" -> []
        alias_str when is_binary(alias_str) -> [alias_str]
        _other -> reject!("M_INVALID_PARAM", "alias must be a string")
      end

    alts =
      case Map.get(content, "alt_aliases") do
        nil -> []
        list when is_list(list) ->
          if Enum.all?(list, &is_binary/1),
            do: list,
            else: reject!("M_INVALID_PARAM", "alt_aliases must be a list of strings")

        _other ->
          reject!("M_INVALID_PARAM", "alt_aliases must be a list of strings")
      end

    set = Enum.uniq(primary ++ alts)

    # Nebu policy (Kassandra / review M3): at most 64 distinct aliases per event. The body cap (1 MB) would allow tens of
    # thousands, each a sequential lookup_alias/1 against the database.
    if length(set) > @canonical_alias_max, do: reject!("M_INVALID_PARAM", "A canonical alias event names at most #{@canonical_alias_max} aliases")

    set
  end

  # Matrix alias grammar (appendices, Room Aliases): `#localpart:domain`, localpart (up to the FIRST ":") and domain
  # non-empty, no NUL, the whole alias at most 255 bytes.
  defp validate_alias_syntax!(alias_str) do
    valid? =
      String.valid?(alias_str) and byte_size(alias_str) <= @alias_max_bytes and
        not String.contains?(alias_str, <<0>>) and
        (case alias_str do
           "#" <> rest ->
             case String.split(rest, ":", parts: 2) do
               [localpart, domain] -> localpart != "" and domain != ""
               _ -> false
             end

           _ ->
             false
         end)

    if valid?, do: :ok, else: reject!("M_INVALID_PARAM", "Not a valid room alias")
  end

  # PUT .../state/m.room.canonical_alias (AFTER the allowlist / membership / power-level checks, so a refused sender
  # never learns whether an alias maps to the room): NEW aliases (the given set minus the aliases of the CURRENT state
  # event of this state_key) must be grammar-valid (M_INVALID_PARAM) and map to this room (M_BAD_ALIAS). Removed and
  # already-present aliases are not validated (spec), so an upgraded room whose copied alias still maps to the OLD room can
  # re-save its content. A failing state read / alias lookup is a 500, nothing is emitted.
  defp validate_put_canonical_alias(room_id, state_key, content) do
    given = canonical_alias_set!(content)

    new_aliases =
      if given == [] do
        []
      else
        given -- current_canonical_aliases(room_id, state_key)
      end

    Enum.each(new_aliases, &validate_alias_syntax!/1)

    Enum.each(new_aliases, fn alias_str ->
      case alias_db_module().lookup_alias(alias_str) do
        {:ok, ^room_id} ->
          :ok

        {:ok, _other_room} ->
          reject!("M_BAD_ALIAS", "The alias does not point to this room")

        {:error, :not_found} ->
          reject!("M_BAD_ALIAS", "The alias does not point to this room")

        {:error, reason} ->
          Logger.error("set_room_state: alias lookup failed for #{room_id} (#{db_error_class(reason)})")

          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.internal(),
            message: "set_room_state: alias lookup failed"
      end
    end)

    :ok
  end

  # The aliases of the latest m.room.canonical_alias event of `state_key` (what clients see as the current state).
  defp current_canonical_aliases(room_id, state_key) do
    case messages_db_module().get_generic_state_events(room_id) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1.type == "m.room.canonical_alias" and (&1.state_key || "") == state_key))
        |> case do
          [] -> []
          matching -> current_alias_list(Enum.max_by(matching, &(&1.origin_server_ts || 0)).content_json)
        end

      {:error, reason} ->
        Logger.error("set_room_state: failed to read the current state of #{room_id} (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "set_room_state: failed to read the current room state"
    end
  end

  # content_json is the jsonb as text, possibly double-encoded (a JSON string holding the JSON): decode twice then.
  defp current_alias_list(content_json) do
    decoded =
      case Jason.decode(content_json || "") do
        {:ok, text} when is_binary(text) ->
          case Jason.decode(text) do
            {:ok, map} -> map
            _ -> %{}
          end

        {:ok, other} ->
          other

        _ ->
          %{}
      end

    primary = if is_map(decoded) and is_binary(decoded["alias"]) and decoded["alias"] != "", do: [decoded["alias"]], else: []
    alts = if is_map(decoded) and is_list(decoded["alt_aliases"]), do: Enum.filter(decoded["alt_aliases"], &is_binary/1), else: []
    Enum.uniq(primary ++ alts)
  end

  # ─── content hardening (D5a / D5d) ──────────────────────────────────────────────────────────────────────────────

  @doc false
  # True when a map / list nests deeper than @content_max_depth levels (the given value itself is level 1). A bounded
  # descent that stops at the limit: the walk never goes deeper than 32 levels, however deep the input is. An EMPTY
  # container at level 33 is too deep as well (the container itself is the level), so this is NOT a copy of
  # Nebu.OAuth.Http.too_deep?/2.
  @spec content_too_deep?(term()) :: boolean()
  def content_too_deep?(value), do: nesting_exceeds?(value, @content_max_depth)

  defp nesting_exceeds?(value, remaining) when is_map(value) or is_list(value) do
    cond do
      remaining <= 0 -> true
      is_map(value) -> Enum.any?(value, fn {_k, v} -> nesting_exceeds?(v, remaining - 1) end)
      true -> Enum.any?(value, &nesting_exceeds?(&1, remaining - 1))
    end
  end

  defp nesting_exceeds?(_scalar, _remaining), do: false

  # ─── value-free failure logs (D5e) ──────────────────────────────────────────────────────────────────────────────

  # The class of a failure for a log line: never the reason itself (a database error carries a snippet of the JSON
  # content, and room names / aliases / state content are user content that never belongs in a log).
  defp db_error_class(%Postgrex.Error{postgres: %{pg_code: code}}), do: "postgres #{code}"
  defp db_error_class(%{__struct__: module}), do: inspect(module)
  defp db_error_class(reason) when is_atom(reason), do: inspect(reason)
  defp db_error_class(_reason), do: "unknown"

  # The stacktrace with every argument list replaced by its arity: the top frame of a FunctionClauseError carries the
  # ARGUMENTS of the failed call (creator id, client values).
  @doc false
  def strip_stacktrace_args(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, args, location} when is_list(args) -> {module, function, length(args), location}
      {fun, args, location} when is_function(fun) and is_list(args) -> {fun, length(args), location}
      frame -> frame
    end)
  end

  # A client-supplied event type in a log line: quoted (a line break cannot forge a log line) and cut to 80 characters.
  defp log_type(type), do: inspect(type, printable_limit: 80)

  # ─── WriteAuditLog ─────────────────────────────────────────────────────────────
  # Delegates to the configurable audit_writer_module (Nebu.Compliance.AuditWriter in prod).
  # Returns ok: false when AuditWriter returns {:error, _}.
  def write_audit_log(request, _stream) do
    metadata =
      case Jason.decode(request.metadata_json) do
        {:ok, m} when is_map(m) -> m
        _ -> %{}
      end

    error_detail =
      if request.error_detail == "", do: nil, else: request.error_detail

    case audit_writer_module().log(
           request.actor_user_id,
           request.action,
           request.target_type,
           request.target_id,
           metadata,
           request.outcome,
           error_detail
         ) do
      :ok ->
        %Core.WriteAuditLogResponse{ok: true}

      {:error, _} ->
        %Core.WriteAuditLogResponse{ok: false}
    end
  end

  defp generate_room_id do
    room_id_with(:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  # `!<16 hex>:<server name>`: the one place a room id is shaped, shared with the createRoom size check (5g), which needs a
  # placeholder of EXACTLY the generated length
  defp room_id_with(opaque) do
    server_name = Application.get_env(:event_dispatcher, :server_name, "nebu.local")
    "!#{opaque}:#{server_name}"
  end

  def join_room(request, _stream) do
    # story moderation-routes-atomic-ban (D9): ONE re-decision when the membership changed between the decision and the room call
    do_join_room(request.room_id_or_alias, request.user_id, 1)
  end

  defp do_join_room(room_id, user_id, retries_left) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        # story create-room-presets-power-levels-topic (D1, follow-up `ec`, the security fix): decide BEFORE
        # Room.Server.join/2: member -> ban -> join rule (pure Nebu.Matrix.Room.JoinRules). A refusal is a 403
        # M_FORBIDDEN with a fixed text; a failing read is a 500 (fail closed). Internal direct joins (creator join,
        # upgrade, auto-join) call Room.Server.join/2 themselves and do not pass here.
        #
        # Story moderation-routes-atomic-ban (D9): the decision names its BASIS (`:any`, or the latest member event an invitation
        # was read with) and the room process refuses the join when that event is no longer the latest one (a revocation, a ban,
        # a re-invite or an unban committed in between): decided again ONCE on fresh reads, a second change is a 503.
        basis = authorize_join!(room_id, user_id)

        case Nebu.Matrix.Room.Server.join(room_id, user_id, basis) do
          {:error, :membership_changed} when retries_left > 0 ->
            do_join_room(room_id, user_id, retries_left - 1)

          {:error, :membership_changed} ->
            # not a spec errcode (kept for consistency with the other 503s); only a sustained loop of moderation gets here
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.unavailable(),
              errcode: "M_UNAVAILABLE",
              message: "The membership changed during the join, try again"

          :ok ->
            # forget-room-membership-purge (AC6): re-joining a forgotten room clears
            # the forget so it reappears in sync. Idempotent — a no-op if not forgotten.
            unforget_room(user_id, room_id)
            # Mark any pending invitation as accepted so it disappears from
            # rooms.invite in subsequent sync responses (no-op for public joins).
            accept_invitation_logged(room_id, user_id)
            # Wake user's long-polling sync task immediately (mirrors invite_user/2 pattern).
            # Without this, the sync task sleeps 30 s after a public-room join (GAP-JOIN-PUBLIC).
            :pg.get_members("user:#{user_id}")
            |> Enum.each(&send(&1, {:new_join, room_id}))
            audit_writer_module().log(user_id, "room_joined", "room", room_id, %{}, "success")
            %Core.JoinRoomResponse{room_id: room_id}

          {:error, :already_member} ->
            # Matrix spec: idempotent — joining an already-joined room is success.
            # No audit log for idempotent joins (AC9 scope decision).
            # forget-room-membership-purge: also clear any stale forgotten-room row
            # here — normally unreachable (you cannot hold a forget while joined, per
            # the forget join-guard), but a raced/stale row must not permanently hide a
            # room the user is actually in. Idempotent no-op when nothing is forgotten.
            unforget_room(user_id, room_id)
            # a member holds no pending invitation: close one that is still open (review cycle 1, M-2: a member who
            # pre-armed an invite for himself must not keep a way back in after a leave / kick)
            accept_invitation_logged(room_id, user_id)
            %Core.JoinRoomResponse{room_id: room_id}

          {:error, :banned} ->
            # Review cycle 2 (Kassandra N-1): the ATOMIC ban check inside Room.Server.join/2 (a ban written after
            # authorize_join!/2 and before the member insert) refuses the join.
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.permission_denied(),
              errcode: "M_FORBIDDEN",
              message: @join_banned_text

          {:error, :membership_unavailable} ->
            raise_join_unavailable()

          {:error, :room_full} ->
            # Story 6.8: room has reached max_members capacity.
            # HTTP handler maps :resource_exhausted → 403 M_ROOM_FULL.
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.resource_exhausted(),
              message: "room is full"

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "join failed: #{inspect(reason)}"
        end
    end
  end

  # ─── The join decision (Spaces S4 restricted rule; story create-room-presets-power-levels-topic D1) ──────────
  #
  # Resolves the impure inputs (is the user a member, the latest membership, room state, pending invite,
  # allow-room membership) and delegates the decision to the pure Nebu.Matrix.Room.JoinRules module.
  #
  #   1. already a member -> allowed, NOTHING is read (an invite-only room must not 403 its own members' re-join);
  #   2. the latest m.room.member of the user is `ban` -> 403 "You are banned from this room", whatever the rule;
  #   3. the effective join rule (JoinRules): public ok; invite / knock need a pending invite that was not taken back
  #      (D13, `invitation_valid!/2`); no join_rules event = invite (Nebu / Synapse policy); restricted / knock_restricted:
  #      invite OR member of a valid allow[] room; private / unknown / malformed: always refused -> 403 "You are not
  #      invited to this room" (one fixed text).
  #
  # FAIL CLOSED: a failing / raising read of the membership, of the join rule state or of the invitation (the pending row
  # and the latest member event, D13) is a 500 (never "no state = open", never "no invite"). Logs: room id and error class
  # only.
  #
  # Returns the BASIS of the decision (story moderation-routes-atomic-ban, D9) for Room.Server.join/3: `:any` when no invitation
  # was needed (a member, a public rule, an allow-room member: a kick does not block a public join and a ban is checked in the
  # room process anyway), `{:invited, event_id | nil}` when the invitation granted it.
  #
  # SECURITY: allow[] is client-writable (S2 PUT) so it is attacker-influenceable. The space_member? resolver returns
  # a plain boolean against each allow-room's actual member set - a non-existent allow-room (room GenServer not
  # running / not found) and an existing-but-not-member allow-room both resolve to false, so they deny identically
  # with no info leak (AC6). JoinRules validates each allow[] entry (type + binary room_id) first (AC4).

  defp authorize_join!(room_id, user_id) do
    if room_member?(room_id, user_id) do
      :any
    else
      banned? = join_banned?(room_id, user_id)
      room_state = join_rule_state!(room_id)
      base = [banned?: banned?, space_member?: &allow_room_member?/2]

      # The invitation only ever GRANTS (JoinRules): decide without it first, so a public room (or an allow-room
      # member) costs no invitation read; read it only for a refusal that an invitation could still turn into a grant.
      case Nebu.Matrix.Room.JoinRules.check_join_allowed(room_state, user_id, base ++ [has_invite?: false]) do
        :ok ->
          :any

        {:error, :forbidden} ->
          with false <- banned?,
               {:invited, _event_id} = basis <- invitation_basis!(room_id, user_id),
               :ok <- Nebu.Matrix.Room.JoinRules.check_join_allowed(room_state, user_id, base ++ [has_invite?: true]) do
            basis
          else
            _ ->
              raise Nebu.Matrix.Error,
                status: Nebu.Matrix.Status.permission_denied(),
                errcode: "M_FORBIDDEN",
                message: if(banned?, do: @join_banned_text, else: @join_not_invited_text)
          end
      end
    end
  end

  # Story sync-membership-partition (D13): an invitation grants the join only when it was not TAKEN BACK. The pending row
  # alone is not enough: every writer that ends an invitation (decline, kick, Admin removal) rejects the row, but some do
  # it best effort, so a failed reject leaves a row that is still pending behind a `leave` member event that is at least
  # as new as the invitation (`>=`: a same-millisecond tie counts as taken back, most restrictive; the same predicate as
  # rule 4 of the /sync partition). A row-only invitation (upgrade, legacy) has no newer leave and stays valid; a former
  # member's re-invite is newer than his old leave and stays valid. Both reads fail closed (500), like every read of
  # this decision. A valid invitation answers the basis of the join (D9 of story moderation-routes-atomic-ban): the id of the
  # latest member event this read saw (`nil`: a row-only invitation without any member event), `false` when there is none.
  defp invitation_basis!(room_id, user_id) do
    case join_read!(db_module_invite(), :pending_invitation, room_id, user_id) do
      nil ->
        false

      invited_at ->
        case join_read!(rooms_db_module(), :latest_member_event, room_id, user_id) do
          %{membership: "leave", origin_server_ts: ts} when is_integer(ts) and ts >= invited_at -> false
          %{event_id: event_id} -> {:invited, event_id}
          _ -> {:invited, nil}
        end
    end
  end

  defp join_read!(mod, fun, room_id, user_id) do
    result =
      if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) do
        try do
          apply(mod, fun, [room_id, user_id])
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      else
        {:error, :unavailable}
      end

    case result do
      {:ok, value} ->
        value

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("join_room: failed to read #{fun} of #{room_id} (#{db_error_class(reason)})")
        raise_join_unavailable()
    end
  end

  # Is the user in the room's in-memory member set? A room process that cannot answer is NOT "not a member" (that
  # would turn a real member's re-join into a misleading 403 "not invited"): it is a 503 (review cycle 1, m-2).
  defp room_member?(room_id, user_id) do
    state = room_registry_module().get_state(room_id)
    MapSet.member?(state.members, user_id)
  rescue
    _ -> raise_room_unavailable(room_id)
  catch
    _, _ -> raise_room_unavailable(room_id)
  end

  defp raise_room_unavailable(room_id) do
    Logger.error("join_room: the room process of #{room_id} did not answer")

    raise Nebu.Matrix.Error,
      status: Nebu.Matrix.Status.unavailable(),
      message: "join_room: the room is temporarily unavailable"
  end

  # accept_invitation/2 closes a pending invitation; the result used to be ignored (review cycle 1, m-5). A failure
  # leaves the invitation pending (the user would keep seeing it): value-free warning, the join itself stands.
  defp accept_invitation_logged(room_id, user_id) do
    case db_module_invite().accept_invitation(room_id, user_id) do
      :ok -> :ok
      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.warning("join_room: failed to close the invitation of #{room_id} (#{db_error_class(reason)})")
        :ok
    end
  end

  # True when the user's LATEST m.room.member is `ban`. A failing read is a 500 (fail closed).
  defp join_banned?(room_id, user_id) do
    result =
      try do
        rooms_db_module().get_member_membership(room_id, user_id)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, membership} ->
        membership == "ban"

      {:error, reason} ->
        Logger.error("join_room: failed to read the membership state of #{room_id} (#{db_error_class(reason)})")
        raise_join_unavailable()

      _other ->
        Logger.error("join_room: failed to read the membership state of #{room_id} (unexpected result)")
        raise_join_unavailable()
    end
  end

  # The m.room.join_rules state event (incl. allow[]) is persisted as a generic state event (story 9-7 / S2 PUT).
  # Read only that slice so the decision does not depend on the full build_state_events/2 assembly. A failing read
  # is a 500: NOT "no state" (which JoinRules reads as the invite policy), and certainly not open.
  defp join_rule_state!(room_id) do
    case safe_generic_state_events(room_id) do
      {:ok, evs} ->
        Enum.map(evs, fn ev ->
          %{type: ev.type, state_key: ev.state_key, content: ev.content_json}
        end)

      {:error, reason} ->
        Logger.error("join_room: failed to read the join rule state of #{room_id} (#{db_error_class(reason)})")
        raise_join_unavailable()

      _other ->
        Logger.error("join_room: failed to read the join rule state of #{room_id} (unexpected result)")
        raise_join_unavailable()
    end
  end

  defp raise_join_unavailable do
    raise Nebu.Matrix.Error,
      status: Nebu.Matrix.Status.internal(),
      message: "join_room: the room state is unavailable"
  end

  defp safe_generic_state_events(room_id) do
    mod = messages_db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :get_generic_state_events, 1) do
      try do
        mod.get_generic_state_events(room_id)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    else
      {:error, :unavailable}
    end
  end

  # Does the user have a pending (not-yet-accepted, not-rejected) invite to room_id?
  # Guarded with function_exported? so injected fakes that do not implement the
  # full InviteDB interface degrade to "no invite" rather than crashing the join.
  defp pending_invite?(room_id, user_id) do
    mod = db_module_invite()

    # Code.ensure_loaded?/1: function_exported?/3 is false for a module that is not loaded yet, and an invite now
    # GRANTS invite / knock rooms (a false "no invite" would lock invited users out)
    if Code.ensure_loaded?(mod) and function_exported?(mod, :get_pending_invite_rooms_for_user, 1) do
      case mod.get_pending_invite_rooms_for_user(user_id) do
        {:ok, rooms} -> room_id in rooms
        _ -> false
      end
    else
      false
    end
  end

  # Is user_id a member of allow-room `room_id`? Uses the in-memory member set
  # (no DB roundtrip — AC1). A non-existent / not-running allow-room resolves to
  # false without crashing the join (AC4/AC6).
  defp allow_room_member?(room_id, user_id) do
    try do
      state = room_registry_module().get_state(room_id)
      MapSet.member?(state.members, user_id)
    rescue
      _ -> false
    catch
      :exit, _ -> false
      _, _ -> false
    end
  end

  # ─── UpdateRoomSettings — Story 6.8: Admin PATCH /admin/rooms/{roomId} ─────────
  #
  # Called by the Admin HTTP handler after a successful DB update of room settings.
  # Delegates to Nebu.Matrix.Room.Server.update_settings/2 (best-effort fire-and-forget cast).
  # Returns UpdateRoomSettingsResponse{ok: true} always — failure to find the running
  # GenServer is non-fatal (room may not be started, or settings will be loaded on next init).

  def update_room_settings(%Core.UpdateRoomSettingsRequest{} = req, stream) do
    # F-1 (SEC): extract and validate caller identity — is_auto_join is a security-relevant
    # policy field that triggers membership changes for every future first-login.
    {actor_id, system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    if is_nil(actor_id) or actor_id == "" do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.unauthenticated(),
        message: "missing trusted identity"
    end

    unless system_role in ["instance_admin"] do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        message: "instance_admin role required"
    end

    room_id = req.room_id
    max_members = req.max_members

    # Best-effort: call update_settings only if the room GenServer is running.
    # If the room is not started, the new max_members will be loaded from DB on next init.
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, _pid} ->
        Nebu.Matrix.Room.Server.update_settings(room_id, %{max_members: max_members})

      {:error, :not_found} ->
        # Room GenServer not running — settings will be applied on next init/1.
        :ok
    end

    # Story admin-auto-join-rooms: persist is_auto_join flag when present in request.
    # optional bool — nil means absent (not sent), so only update when explicitly set.
    if not is_nil(req.is_auto_join) do
      case admin_db_module().update_room_auto_join(room_id, req.is_auto_join) do
        :ok ->
          # F-2 (SEC): emit audit_log so operators can reconstruct who toggled is_auto_join
          # and when. Effect is bulk (every future new user joins flagged rooms at first login).
          audit_writer_module().log(
            actor_id,
            "room_auto_join_changed",
            "room",
            room_id,
            %{"is_auto_join" => req.is_auto_join},
            "success"
          )

        {:error, reason} ->
          Logger.warning(
            "update_room_settings: update_room_auto_join failed for #{room_id}: #{inspect(reason)}"
          )
      end
    end

    # Story rm1-room-visibility: persist visibility when a VALID value is present.
    # SEC (default-deny): only "public"/"private" are ever written. "" (legacy callers,
    # = no change) and any other value (invalid/forged) are silently ignored — the column
    # is NEVER updated. The value reaches the DB only as a bound parameter (no interpolation).
    if req.visibility in ["public", "private"] do
      case admin_db_module().update_room_visibility(room_id, req.visibility) do
        :ok ->
          # Audit the visibility change (mirrors the is_auto_join audit write): who flipped
          # a room between public/private discoverability, and when.
          audit_writer_module().log(
            actor_id,
            "room_visibility_changed",
            "room",
            room_id,
            %{"visibility" => req.visibility},
            "success"
          )

        {:error, reason} ->
          Logger.warning(
            "update_room_settings: update_room_visibility failed for #{room_id}: #{inspect(reason)}"
          )
      end
    end

    %Core.UpdateRoomSettingsResponse{ok: true}
  end

  # ─── Spaces S5 (AC5): set_room_auto_join/3 — audited is_auto_join write ──────
  #
  # In-process entry point for the Admin UI (via Nebu.Matrix.set_room_auto_join/3) to
  # toggle is_auto_join on a Space (a Space is a room). Performs the SAME DB write +
  # audit_log the update_room_settings/2 command path performs for its is_auto_join
  # branch — so admin Space toggles are audited identically to room toggles. `actor_id`
  # is the acting admin's Matrix user id (recorded as the audit actor). Returns :ok or
  # {:error, reason}.
  @spec set_room_auto_join(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_room_auto_join(actor_id, room_id, value) when is_boolean(value) do
    case admin_db_module().update_room_auto_join(room_id, value) do
      :ok ->
        audit_writer_module().log(
          actor_id,
          "room_auto_join_changed",
          "room",
          room_id,
          %{"is_auto_join" => value},
          "success"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "set_room_auto_join: update_room_auto_join failed for #{room_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # ─── Story rm1-room-visibility: set_room_visibility/3 — audited visibility write ──
  #
  # In-process entry point for the Admin UI (via Nebu.Matrix.set_room_visibility/3) to
  # flip a room's visibility between "public" and "private". Performs the SAME validated,
  # parameterised DB write + audit_log the update_room_settings/2 command path performs
  # for its visibility branch. `actor_id` is the acting admin's Matrix user id (recorded
  # as the audit actor).
  #
  # SEC (default-deny): the guard clause only accepts "public"/"private"; any other value
  # never reaches the DB (the function clause does not match and the catch-all returns
  # {:error, :invalid_visibility}). Returns :ok or {:error, reason}.
  @spec set_room_visibility(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_room_visibility(actor_id, room_id, visibility)
      when visibility in ["public", "private"] do
    case admin_db_module().update_room_visibility(room_id, visibility) do
      :ok ->
        audit_writer_module().log(
          actor_id,
          "room_visibility_changed",
          "room",
          room_id,
          %{"visibility" => visibility},
          "success"
        )

        :ok

      {:error, reason} ->
        # value-free (room id, error class): a database error can carry a snippet of the statement / values
        Logger.warning("set_room_visibility: update_room_visibility failed for #{room_id} (#{db_error_class(reason)})")

        {:error, reason}
    end
  end

  def set_room_visibility(_actor_id, _room_id, _visibility), do: {:error, :invalid_visibility}

  # ─── Story rm4-admin-member-management: admin add/remove member (audited) ─────
  #
  # In-process entry points for the Admin UI (via Nebu.Matrix.admin_add_room_member/3
  # / admin_remove_room_member/3). They wrap the SAME authorized join/leave write
  # path the Matrix client flow uses — so a proper `m.room.member` join/leave event
  # is emitted and `room_members` is updated — then write a `member_added` /
  # `member_removed` audit row with the acting admin as the actor (NOT the target
  # user). The target's membership change is attributed to a real Matrix user in the
  # audit log (the admin), which is the whole point of admin-initiated membership.
  #
  # SECURITY:
  #   * `user_id` is shape-validated (Nebu.Matrix.UserId.valid?/1) BEFORE any write
  #     (default-deny on attacker-influenced input — story rm4 AC5).
  #   * `actor_id` is the server-derived admin Matrix user id, never client-settable.
  #   * Self-removal is rejected server-side (defence-in-depth; the UI also hides the
  #     control) so an admin can never accidentally remove their own membership.
  #
  # The room is started on demand first (mirrors join_room/2 — the room GenServer may
  # not be running). A not-found room surfaces as {:error, :not_found}.
  @spec admin_add_room_member(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def admin_add_room_member(room_id, user_id, actor_id) do
    cond do
      not Nebu.Matrix.UserId.valid?(user_id) ->
        {:error, :invalid_user_id}

      # ─── No-federation guard (Bug C) ─────────────────────────────────────────
      # Nebu is a single-homeserver, NO-FEDERATION system. A user whose domain is
      # not the configured server_name (e.g. "@charlie:nebu.local" when the server
      # is "localhost") is not a real local account — force-adding them would write
      # a ghost room_members row that never resolves to a session/profile and never
      # surfaces in the Admin member list ("the member never appears"). Default-deny
      # on the attacker-/operator-influenced domain part, comparing against the
      # configured server name (NOT a hardcoded value). UserId.valid?/1 is only a
      # shape check, so this domain check is the real authorisation boundary here.
      not local_domain?(user_id) ->
        {:error, :foreign_domain}

      true ->
        _ = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)

        # Admin force-add semantics (story rm4): the admin (room creator, PL100) adds
        # another LOCAL user with full operator authority. We model this as a proper
        # Matrix invite → join membership transition so it succeeds regardless of the
        # room's join_rule (invite and even restricted): establish a pending
        # invite from the admin first, then run the normal authorized join path, which
        # honours the invite (authorize_join!/2) and accepts it. insert_invitation
        # re-arms a former (accepted / rejected) invitation, a duplicate pending invite is
        # harmless and is immediately accepted by join_room on success.
        #
        # Story create-room-presets-power-levels-topic (D1): the force-add is NOT a way around a ban, and review cycle 1
        # decides both refusals BEFORE anything is written (F-8: the invite of this call must not re-arm / replace a
        # legitimate invitation of a user that is then refused anyway): an existing member is a no-op (M-2, room v10:
        # a joined target is not invited), a banned target is refused. A private / unknown / malformed join rule refuses
        # even this invite (strict v10: fix the rule first).
        try do
          cond do
            match?({:error, :not_found}, Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id)) ->
              {:error, :not_found}

            admin_target_member?(room_id, user_id) ->
              {:ok, room_id}

            true ->
              if invite_target_banned?(room_id, user_id) do
                raise Nebu.Matrix.Error,
                  status: Nebu.Matrix.Status.permission_denied(),
                  errcode: "M_FORBIDDEN",
                  message: @join_banned_text
              end

              # Review cycle 2 (Kassandra N-4): a pending invitation of the target is USED, not re-armed (re-arming would
              # overwrite its inviter), and a failed add drops only an invitation THIS call created (a legitimate
              # invitation must survive a force-add that fails for another reason: rule, room full, room unavailable).
              if pending_invite?(room_id, user_id) do
                admin_join_after_invite(room_id, user_id, actor_id, false)
              else
                case db_module_invite().insert_invitation(room_id, actor_id, user_id) do
                  :ok ->
                    admin_join_after_invite(room_id, user_id, actor_id, true)

                  {:error, reason} ->
                    Logger.error("admin_add_room_member: failed to record the invitation for #{room_id} (#{db_error_class(reason)})")
                    {:error, "failed to record the invitation"}
                end
              end
          end
        rescue
          e in Nebu.Matrix.Error -> map_member_error(e)
        end
    end
  end

  # Is the force-add target already in the room's member set? An unreachable room process is not "no member": the add
  # is refused (503-like error through map_member_error).
  defp admin_target_member?(room_id, user_id) do
    state = room_registry_module().get_state(room_id)
    MapSet.member?(state.members, user_id)
  rescue
    _ -> raise_room_unavailable(room_id)
  catch
    _, _ -> raise_room_unavailable(room_id)
  end

  defp admin_join_after_invite(room_id, user_id, actor_id, created_invite?) do
    req = %Core.JoinRoomRequest{user_id: user_id, room_id_or_alias: room_id}

    try do
      %Core.JoinRoomResponse{room_id: ^room_id} = join_room(req, %{http_request_headers: %{}})

      audit_writer_module().log(
        actor_id,
        "member_added",
        "room",
        room_id,
        %{"user_id" => user_id},
        "success"
      )

      {:ok, room_id}
    rescue
      e in Nebu.Matrix.Error ->
        # Kassandra SEC Gate 1 (LOW): the pending invite was inserted before the
        # join attempt. If the join fails (e.g. room not found, banned target), drop the invite
        # so it does not dangle in the target's rooms.invite sync for an add that
        # never completed. reject_invitation is a no-op if nothing is pending.
        if created_invite?, do: db_module_invite().reject_invitation(room_id, user_id)
        map_member_error(e)
    end
  end

  # True when `user_id`'s domain part equals the configured homeserver name.
  # The configured value is the same source generate_room_id/0 uses; the runtime
  # default is "localhost" (see config/runtime.exs NEBU_SERVER_NAME). We split on
  # the FIRST ":" only — a Matrix user_id is "@localpart:domain" and the localpart
  # grammar (UserId) forbids ":", so the remainder after the first ":" is the domain.
  defp local_domain?(user_id) do
    server_name = Application.get_env(:event_dispatcher, :server_name, "localhost")

    case String.split(user_id, ":", parts: 2) do
      [_localpart, domain] -> domain == server_name
      _ -> false
    end
  end

  @spec admin_remove_room_member(String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def admin_remove_room_member(_room_id, user_id, actor_id) when user_id == actor_id,
    do: {:error, :self_removal}

  def admin_remove_room_member(room_id, user_id, actor_id) do
    # `valid_shape?/1`, not `valid?/1`: a REMOVAL must also reach a legacy id above 255 bytes (story event-size-limit, D12)
    if Nebu.Matrix.UserId.valid_shape?(user_id) do
      _ = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
      req = %Core.LeaveRoomRequest{user_id: user_id, room_id: room_id}

      try do
        %Core.LeaveRoomResponse{room_id: ^room_id} = leave_room(req, %{http_request_headers: %{}})

        audit_writer_module().log(
          actor_id,
          "member_removed",
          "room",
          room_id,
          %{"user_id" => user_id},
          "success"
        )

        :ok
      rescue
        e in Nebu.Matrix.Error -> map_member_error(e)
      end
    else
      {:error, :invalid_user_id}
    end
  end

  defp map_member_error(%Nebu.Matrix.Error{status: status, message: message}) do
    cond do
      status == Nebu.Matrix.Status.not_found() -> {:error, :not_found}
      true -> {:error, message}
    end
  end

  def leave_room(request, _stream) do
    room_id = request.room_id
    user_id = request.user_id

    # ─── Story rm5 (AC1): personal-room LEAVE guard — server-side, default-deny ──
    #
    # A user must never be able to leave their own personal self-room (it is their
    # permanent anchor). The guard runs BEFORE any DB mutation, so a rejected leave
    # leaves the membership unchanged. We reuse the exact Nebu.Matrix.Error
    # permission_denied shape used by the restricted-join path (Spaces S4) so the
    # HTTP layer maps it to 403 M_FORBIDDEN identically.
    #
    # The personal_room_id lookup is an exact-match parameterised query (ADR-018).
    # A DB error checking it is non-fatal here: we log and fall through to the normal
    # leave path rather than fail-open on the guard — but note the guard only ever
    # BLOCKS, so a lookup error cannot let a user leave a room they otherwise could
    # not; the only room the guard protects is the caller's own personal room, and a
    # transient lookup error simply means we cannot prove it is the personal room.
    #
    # In production messages_db_module() is the real Nebu.Matrix.Room.DB, which always
    # exports get_personal_room_id/1, so the guard is always active. function_exported?/3
    # degrades gracefully only for older injected fakes in unrelated leave/router tests.
    msg_mod = messages_db_module()

    if function_exported?(msg_mod, :get_personal_room_id, 1) do
      case msg_mod.get_personal_room_id(user_id) do
        {:ok, ^room_id} when is_binary(room_id) ->
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "cannot leave your personal room"

        _ ->
          :ok
      end
    end

    # Review cycle 1 (Kassandra F-1) and cycle 2 (N-2): a user whose latest membership is `ban` can leave through NO branch
    # (a self-authored leave event is newer than the ban and would lift it, also for a user that the room process still
    # lists as a member after a failed removal). Decided once, before anything is written: `ban` -> 403, an unreadable
    # membership -> 500 (fail closed); an injected fake without the reader has no ban state.
    latest = leave_guard_membership!(room_id, user_id)

    # If the room GenServer is not running (e.g. after stack restart or the user
    # was only invited and the room was never started for them), we still honour
    # the leave / decline-invite semantics by operating on the DB directly.
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        # Room GenServer not running: the leave / decline-invite semantics operate on the DB directly.
        leave_without_room_process(room_id, user_id, latest)

      {:ok, _pid} ->
        case Nebu.Matrix.Room.Server.leave(room_id, user_id) do
          :ok ->
            # Wake the user's long-polling sync task immediately so rooms.leave
            # arrives within the long-poll window instead of waiting up to 30 s.
            # The sync task may not be subscribed to room:#{room_id} if it started
            # before the user was in this room (e.g. a room the user created and
            # immediately left). Broadcasting to user:#{user_id} guarantees wakeup
            # regardless of room subscriptions. The woken task rebuilds the whole membership
            # partition (sync_partition/1), so the leave arrives in rooms.leave (once).
            members = :pg.get_members("user:#{user_id}")
            require Logger
            Logger.debug("[leave_room] broadcasting {:new_leave, #{room_id}} to #{length(members)} sync tasks for #{user_id}")
            Enum.each(members, &send(&1, {:new_leave, room_id}))
            # review cycle 1 (M-2): a member who left holds no way back in through an invitation row that is still pending
            reject_invitation_guarded(room_id, user_id)
            maybe_record_auto_join_opt_out(room_id, user_id)
            %Core.LeaveRoomResponse{room_id: room_id}

          {:error, :not_member} ->
            # GenServer running but user absent from in-memory state: the leave of a non-member (a declined invitation).
            leave_without_room_process(room_id, user_id, latest)

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "leave failed: #{inspect(reason)}"
        end
    end
  end

  # The leave of a user the room process does not know as a member (declined invitation, or a member whose room process
  # was not running). Review cycle 1 (Kassandra F-1, HIGH): this path used to write a self-authored `m.room.member
  # leave` ALWAYS, which was newer than a ban and lifted it (the join decision reads the latest event).
  #   * the latest membership is `ban` -> 403, NOTHING is written (room v10: leaving is only valid from invite / join /
  #     knock); an unreadable membership is a 500 (fail closed), an injected fake without the reader has no ban state;
  #   * the leave event is written ONLY when there was something to leave: a pending invitation (the decline) or a
  #     membership `join` (a member whose room process was not running);
  #   * the pending invitation is rejected as before (a no-op when there is none).
  # Story moderation-routes-atomic-ban (D8): the decline itself (the self-leave and the reject) is decided again and written by the
  # room process (`Room.Server.write_decline/2`, ONE transaction), so a ban committed after the guard above is never hidden by a
  # newer self-leave: see decline_in_room!/2.
  defp leave_guard_membership!(room_id, user_id) do
    case latest_membership_read(room_id, user_id) do
      {:ok, "ban"} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.permission_denied(),
          errcode: "M_FORBIDDEN",
          message: @join_banned_text

      {:ok, membership} ->
        membership

      :unavailable ->
        nil

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("leave_room: failed to read the membership state of #{room_id} (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "leave_room: the room state is unavailable"
    end
  end

  defp leave_without_room_process(room_id, user_id, latest) do
    pending? = pending_invite?(room_id, user_id)

    # delete_member is idempotent (only updates rows where left_at IS NULL).
    # :ok and {:error, :not_member} are both expected (invite-only user, no room_members row).
    # Any other error is logged as a warning but does not fail the leave (best-effort).
    case rooms_db_module().delete_member(room_id, user_id) do
      :ok -> :ok
      {:error, :not_member} -> :ok
      {:error, reason} ->
        Logger.warning("[leave_room] delete_member failed for #{room_id} (#{db_error_class(reason)})")
    end

    # A proper m.room.member leave event (fetch_delta_rooms finds it even if the :pg broadcast arrives between two sync cycles),
    # only for a real decline / leave; nothing to decline: the (no-op) reject of the pending invitation only, no room process.
    if pending? or latest == "join" do
      decline_in_room!(room_id, user_id)
    else
      db_module_invite().reject_invitation(room_id, user_id)
    end

    maybe_record_auto_join_opt_out(room_id, user_id)
    %Core.LeaveRoomResponse{room_id: room_id}
  end

  # Story moderation-routes-atomic-ban (D8): the decline is written by the room process, which reads the latest membership again:
  # a ban committed since the guard is `403` and nothing is written; otherwise the self-leave and the reject of the pending
  # invitation are ONE transaction (a failure is a 500 and changes nothing). A room process that is not running is started (the
  # room exists: there is something to decline); only a room that cannot be started (an archived room: `init/1` stops) keeps the
  # out-of-process write, where no moderation can run concurrently (moderation needs a running room process).
  defp decline_in_room!(room_id, user_id) do
    started =
      case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
        {:ok, _pid} -> :running
        {:error, :not_found} -> decline_start_room(room_id)
      end

    if started == :running do
      result =
        try do
          Nebu.Matrix.Room.Server.write_decline(room_id, user_id)
        catch
          :exit, _reason -> {:error, :room_unavailable}
        end

      case result do
        :ok ->
          :ok

        {:error, :member} ->
          # joined in the meantime (unreachable in practice): his leave is a member leave
          _ = Nebu.Matrix.Room.Server.leave(room_id, user_id)
          :ok

        {:error, :banned} ->
          raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: @join_banned_text

        # review cycle 2 (Kassandra L-5): the room was archived while its process still ran (the transaction refused it): the
        # archived-room decline applies, written out of process (no moderation can change an archived room)
        {:error, :room_archived} ->
          db_module_invite().reject_invitation(room_id, user_id)
          emit_decline_event(room_id, user_id)

        {:error, :room_unavailable} ->
          Logger.error("leave_room: the room process of #{room_id} did not answer the decline")
          raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.unavailable(), message: "leave_room: the room is temporarily unavailable"

        {:error, _reason} ->
          # Room.Server logged the class of the failure; nothing was written
          raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "leave failed"
      end
    else
      db_module_invite().reject_invitation(room_id, user_id)
      emit_decline_event(room_id, user_id)
    end
  end

  # review cycle 1 (M1): only an ARCHIVED room (its process stops in init/1) keeps the out-of-process decline; any other start failure
  # (registry timeout, supervisor error, a failing read in init) is a 503: a room that may be running elsewhere must not get a
  # self-leave written past its process (a concurrent ban would be hidden)
  defp decline_start_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.start_room(room_id) do
      {:ok, _pid} ->
        :running

      {:error, _reason} ->
        if room_archived?(room_id) do
          :archived
        else
          Logger.error("leave_room: the room process of #{room_id} could not be started for the decline")
          raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.unavailable(), message: "leave_room: the room is temporarily unavailable"
        end
    end
  end

  defp room_archived?(room_id) do
    mod = rooms_db_module()

    Code.ensure_loaded?(mod) and function_exported?(mod, :get_room_status, 1) and
      match?({:ok, "archived"}, guarded_status_read(fn -> mod.get_room_status(room_id) end))
  end

  defp guarded_status_read(fun) do
    fun.()
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The latest membership of the user through rooms_db_module(): {:ok, membership | nil} | {:error, _} | :unavailable
  # (an injected fake that has no reader).
  defp latest_membership_read(room_id, user_id) do
    mod = rooms_db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :get_member_membership, 2) do
      try do
        mod.get_member_membership(room_id, user_id)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    else
      :unavailable
    end
  end

  # One attempt to reject a pending invitation of the user: :ok | {:error, reason}. Skipped (:ok) for the real InviteDB when
  # no Repo runs (Repo-less unit tests), always run for an injected fake.
  defp try_reject_invitation(room_id, user_id) do
    mod = db_module_invite()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :reject_invitation, 2) and
         (mod != Nebu.Matrix.Room.InviteDB or Process.whereis(Nebu.Repo) != nil) do
      try do
        case mod.reject_invitation(room_id, user_id) do
          {:error, reason} -> {:error, reason}
          _ -> :ok
        end
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    else
      :ok
    end
  end

  # Best-effort (the leave of a member): a failure is a value-free warning.
  defp reject_invitation_guarded(room_id, user_id) do
    case try_reject_invitation(room_id, user_id) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("reject_invitation failed for #{room_id} (#{db_error_class(reason)})")
    end

    :ok
  end

  # ─── Story rm5 (AC4): record an auto-join opt-out on a successful leave ──────
  #
  # When a user successfully leaves a room (or Space) that is flagged
  # is_auto_join=true, persist a (room_id, user_id) opt-out so that the next login /
  # initial sync does NOT re-add the room via ensure_auto_join_*_memberships/1.
  #
  # Best-effort and fully non-fatal: a left room must never fail because the opt-out
  # could not be written, and a non-auto-join room writes nothing. We degrade
  # gracefully for injected fakes that predate rm5 (function_exported?/3) so older
  # leave tests keep passing without implementing the new seam.
  defp maybe_record_auto_join_opt_out(room_id, user_id) do
    mod = rooms_db_module()

    if function_exported?(mod, :auto_join_room?, 1) and
         function_exported?(mod, :insert_auto_join_opt_out, 3) do
      case mod.auto_join_room?(room_id) do
        {:ok, true} ->
          case mod.insert_auto_join_opt_out(room_id, user_id, Nebu.DB.Helpers.now_ms()) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[leave_room] insert_auto_join_opt_out failed for #{user_id}/#{room_id}: #{inspect(reason)}"
              )
          end

        {:ok, false} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[leave_room] auto_join_room? check failed for #{room_id}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  @doc false
  # Story create-room-invites-direct (D4): the body of POST /rooms/{roomId}/invite (a JSON OBJECT: the router has already told
  # M_NOT_JSON and a non-object M_BAD_JSON apart) -> `{:ok, user_id}` or a raised Nebu.Matrix.Error. These checks reveal
  # nothing about the room and run BEFORE the room checks. A present `user_id` (not null) ALWAYS selects the user-id form, whatever
  # 3pid keys are also present (they are ignored). `reason` is not read (known deviation, D2). Fixed messages, no client value.
  @spec invite_body_user_id(map()) :: {:ok, String.t()}
  def invite_body_user_id(params) when is_map(params) do
    case Map.get(params, "user_id") do
      nil ->
        cond do
          not Enum.any?(@invite_3pid_keys, &Map.has_key?(params, &1)) -> reject!("M_MISSING_PARAM", "user_id is required")
          well_shaped_3pid?(params) -> threepid_denied!()
          true -> reject!("M_BAD_JSON", "a third-party invite needs the string fields id_server, id_access_token, medium and address")
        end

      user_id ->
        {:ok, validate_invitee_shape!(user_id)}
    end
  end

  # D3 shape of the single invitee of POST /invite: a string (M_BAD_JSON) that is a valid user id (M_INVALID_PARAM)
  defp validate_invitee_shape!(invitee) when is_binary(invitee) do
    if byte_size(invitee) <= @user_id_max_bytes and Nebu.Matrix.UserId.valid?(invitee),
      do: invitee,
      else: reject!("M_INVALID_PARAM", "user_id is not a valid user id")
  end

  defp validate_invitee_shape!(nil), do: reject!("M_MISSING_PARAM", "user_id is required")
  defp validate_invitee_shape!(_other), do: reject!("M_BAD_JSON", "user_id must be a string")

  def invite_user(request, _stream) do
    room_id = request.room_id
    inviter = request.inviter_id
    invitee = request.invitee_id

    # D4 / D3: the shape of the invitee is checked before anything about the room is read
    validate_invitee_shape!(invitee)

    # Verify the room exists and inviter is a member.
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        state = Nebu.Matrix.Room.Server.get_state(room_id)

        unless MapSet.member?(state.members, inviter) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "you are not a member of this room"
        end

        unless Nebu.Matrix.Room.PowerLevels.can?(state.power_levels, inviter, :invite) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "insufficient power level for invite"
        end

        # Story create-room-invites-direct (D3): only an existing ACTIVE account of THIS server can be invited. Read AFTER the
        # inviter's own checks above, so a non-member learns nothing about who exists.
        ensure_local_invitee!(invitee)
        ensure_invitees_exist!([invitee])

        # D1: the shared invite path (member / ban / already-invited checks, the row, the signed invite event, the wake-up)
        _ts = do_invite!(room_id, inviter, invitee, state.members, is_direct: false, not_before: 0, retry_reject: true)

        %Core.InviteUserResponse{}
    end
  end

  # ─── the shared invite path (story create-room-invites-direct, D1, D2) ──────────────────────────────────────────────

  # createRoom step 8 AND POST /rooms/{roomId}/invite. The caller has validated the request and checked the inviter (room
  # running, inviter a member, inviter level) and the invitee's eligibility (D3). Decides, in this order:
  #   1. the target is a member                            -> 403 M_FORBIDDEN (a member holds no invitation, self-invite included)
  #   2. the target's latest membership is `ban`           -> 403 M_FORBIDDEN (fail closed on a failing read: 500)
  #   3. ALREADY INVITED (a pending row AND the latest membership is `invite`) -> no-op (spec: 200 "or was already invited")
  #   3a. the pending-invitation caps (D6, D7) when the write would ADD a pending row (not for `pending_before`, not createRoom's
  #      step 8: `caps: :prechecked`)                       -> 403 M_FORBIDDEN (fail closed on a failing count read: 500)
  #   4. the invitation row (InviteDB re-arm), THEN the signed `m.room.member` invite event, THEN the invitee's forget of the
  #      room is cleared (D7, best effort) and the {:new_invite} wake-up is sent (POST /invite at once, createRoom deferred, D9).
  # A failing event write after the row rejects the row again (best effort) and is a 500: no half invitation that is joinable
  # but invisible.
  # Story moderation-routes-atomic-ban (D7, Kassandra M-1): the checks 1-3 above are fast-path refusals on a snapshot; the
  # authoritative ones run in the room process with the event (`Room.Server.write_invite/5`): the inviter is still joined with
  # the `invite` level, the invitee is no member, and a ban committed after the outside read rejects the row and is the same
  # `403` (the event is stamped after the invitee's latest member event, so a later ban is always newer than the invite).
  # Returns the timestamp of the invite event, or `not_before - 1` (the caller's chain value) when nothing was written (already
  # invited).
  #
  # opts: `:is_direct` (true only for a createRoom invite with is_direct, D2), `:not_before` (the chain timestamp the event must
  # reach, createRoom step 8; 0 for POST /invite), `:wake` (default true; createRoom passes false and wakes after step 8, D9),
  # `:caps` (`:check` by default; createRoom passes `:prechecked`, its list was counted before the room existed).
  defp do_invite!(room_id, inviter, invitee, members, opts) do
    not_before = Keyword.fetch!(opts, :not_before)

    if MapSet.member?(members, invitee) do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        errcode: "M_FORBIDDEN",
        message: "The invited user is already in this room"
    end

    membership = invite_target_membership!(room_id, invitee)

    if membership == "ban" do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        errcode: "M_FORBIDDEN",
        message: "The invited user is banned from this room"
    end

    # read BEFORE the insert (review cycle 1, code review M1 / M2 = Kassandra L-2): whether the invitee already holds a PENDING row
    # decides both the already-invited no-op and whether a failed event write may undo the row (only a row THIS call created / re-armed)
    pending_before = invite_pending!(room_id, invitee)

    if membership == "invite" and pending_before do
      # already invited: nothing is written, nothing is broadcast
      max(not_before - 1, 0)
    else
      # story rate-limits-join-invite-create-room (D7): the pending caps are the LAST check, and only a write that ADDS a pending row
      # is counted: `pending_before` means the row exists already (a row-only / legacy invitation that this write turns into an
      # event-backed one). A re-arm of an accepted / rejected row adds a pending row and is checked. createRoom checked its whole
      # list up front (`caps: :prechecked`): a failure here would create and then delete a room.
      if not pending_before and Keyword.get(opts, :caps, :check) == :check, do: check_invite_caps!(inviter, [invitee])

      write_invitation!(room_id, inviter, invitee, opts |> Keyword.put(:created_row?, not pending_before) |> Keyword.put(:capped?, not pending_before))
    end
  end

  # the latest membership of the target (ONE read, shared by the ban and the already-invited check); fail closed
  defp invite_target_membership!(room_id, invitee) do
    result =
      try do
        rooms_db_module().get_member_membership(room_id, invitee)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, membership} ->
        membership

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("invite_user: failed to read the membership state of #{room_id} (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "invite_user: the room state is unavailable"
    end
  end

  # Kept for the Admin force-add path (admin_add_room_member/3, unchanged by the invite story): is the target banned?
  defp invite_target_banned?(room_id, invitee), do: invite_target_membership!(room_id, invitee) == "ban"

  # true when the invitee holds a PENDING row; a failing read is a 500 (fail closed)
  defp invite_pending!(room_id, invitee) do
    result =
      try do
        db_module_invite().pending_invite?(room_id, invitee)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, pending?} when is_boolean(pending?) ->
        pending?

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("invite_user: failed to read the invitation state of #{room_id} (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "invite_user: the invitation state is unavailable"
    end
  end

  # The row of an invitation that ADDS a pending row (`:capped?`) goes through the locked, re-counting insert (createRoom step 8
  # included: the room is new, so every row is new; a cap broken only by a CONCURRENT request raises 403 and createRoom deletes the
  # room again). A row that already is pending (`pending_before`: the invite event is the only thing missing) adds nothing and is
  # a plain re-arm. An `invite_db_module` without the capped insert (the unit fakes) is served by `insert_invitation/3`: the
  # pre-check above has decided.
  # The real `Nebu.Matrix.Room.InviteDB` is NEVER served by the fallback (delta gate I-1): a capped write must not silently become an
  # uncapped one, so for the real module the capped insert is called unconditionally (a missing function would be a loud crash).
  defp insert_invitation_row(room_id, inviter, invitee, opts) do
    mod = db_module_invite()

    cond do
      not Keyword.get(opts, :capped?, false) ->
        mod.insert_invitation(room_id, inviter, invitee)

      mod == Nebu.Matrix.Room.InviteDB or (Code.ensure_loaded?(mod) and function_exported?(mod, :insert_invitation_capped, 4)) ->
        mod.insert_invitation_capped(room_id, inviter, invitee, invite_max_pending())

      true ->
        mod.insert_invitation(room_id, inviter, invitee)
    end
  end

  defp write_invitation!(room_id, inviter, invitee, opts) do
    case insert_invitation_row(room_id, inviter, invitee, opts) do
      {:error, {:cap, violated}} when violated in [:inviter, :pair, :invitee] ->
        cap_refused!(violated)

      {:error, :lock_timeout} ->
        # the locks of the inviter / invitee stayed busy for 2 s: nothing was written; time-based, so the client may retry
        Logger.warning("invite: the invitation locks stayed busy (lock_timeout), the invitation was not written")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.unavailable(),
          errcode: "M_LIMIT_EXCEEDED",
          message: "Too many invitations to this user or from you are being processed, try again in a moment"

      :ok ->
        content =
          if Keyword.get(opts, :is_direct) == true,
            do: %{"membership" => "invite", "is_direct" => true},
            else: %{"membership" => "invite"}

        case write_invite_event(room_id, inviter, invitee, content, Keyword.fetch!(opts, :not_before)) do
          {:ok, _event_id, ts} ->
            # Story sync-membership-partition (D7): an invitation clears the invitee's forget of the room (spec: forgotten
            # rooms stay hidden "until the user re-joins, is re-invited, or knocks"). AFTER the invite event was written,
            # best effort like the clear on join: a failing clear never fails the invite.
            unforget_room(invitee, room_id)

            # Wake the invitee's long-polling sync task immediately (Bug 4-29f fix): it subscribed to "user:#{invitee}" before
            # entering the receive loop. createRoom (`wake: false`) defers the wake-ups until step 8 has succeeded (D9).
            if Keyword.get(opts, :wake, true), do: wake_invitee(invitee, room_id)

            ts

          {:error, refusal} when refusal in [:banned, :already_member, :inviter_not_joined, :insufficient_level, :invitation_gone, :room_archived] ->
            refused_invite_event!(room_id, invitee, refusal, opts)

          {:error, reason} ->
            handle_failed_invite_event!(room_id, invitee, reason, opts)
        end

      {:error, reason} ->
        Logger.error("invite: failed to write the invitation row for #{room_id} (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "invite failed: the invitation could not be written"
    end
  end

  # The invite event through the room process (D7); a room that does not answer is a failed write (500, the row compensated)
  defp write_invite_event(room_id, inviter, invitee, content, not_before) do
    Nebu.Matrix.Room.Server.write_invite(room_id, inviter, invitee, content, not_before)
  catch
    :exit, _reason -> {:error, :room_unavailable}
  end

  # A refusal of the room process (D7): the same answers as the outside checks. A row THIS call created / re-armed is rejected
  # again (a pre-existing pending invitation is not this call's to undo). For a ban the room process has rejected every pending row
  # already; the compensation here is a second, best-effort attempt.
  defp refused_invite_event!(room_id, invitee, refusal, opts) do
    if Keyword.get(opts, :created_row?, true) do
      reject_invitation_after_failed_event(room_id, invitee, Keyword.get(opts, :retry_reject, false))
    end

    {message, errcode} =
      case refusal do
        :banned -> {"The invited user is banned from this room", "M_FORBIDDEN"}
        :already_member -> {"The invited user is already in this room", "M_FORBIDDEN"}
        # the inviter lost his membership or level between the snapshot and the room call: the texts of invite_user/2
        :inviter_not_joined -> {"You are not a member of this room", "M_FORBIDDEN"}
        :insufficient_level -> {"insufficient power level for invite", nil}
        # review cycle 1 (M5): the row this call wrote was taken back (a revocation, a decline) before the event: the invitee is
        # neither a member nor invited, the text of the D4 kick refusal
        :invitation_gone -> {"The user is not in this room", "M_FORBIDDEN"}
        # review cycle 2 (Kassandra L-5): an archived room is answered like a room whose process is not running
        :room_archived -> raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "Room not found"
      end

    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: errcode, message: message
  end

  # A failed invite event write (review cycle 1, code review M1 / M2 / M3 = Kassandra L-2). The compensation is CONDITIONAL:
  #   * a unique violation (the event id is a content hash, an identical concurrent invite wrote the very same event) with the
  #     latest membership now `invite` = ALREADY INVITED: no reject, the winner's invitation stays valid, answer like the no-op;
  #   * otherwise 500; the row is rejected again ONLY when this call created / re-armed it (`:created_row?`): a pending row that
  #     existed before (an older invitation without an invite event, upgrade_room) is a valid invitation this call must not undo.
  defp handle_failed_invite_event!(room_id, invitee, reason, opts) do
    if unique_violation?(reason) and invite_target_membership!(room_id, invitee) == "invite" do
      max(Keyword.fetch!(opts, :not_before) - 1, 0)
    else
      Logger.error("invite: failed to write the m.room.member invite event for #{room_id} (#{db_error_class(reason)})")

      if Keyword.get(opts, :created_row?, true) do
        reject_invitation_after_failed_event(room_id, invitee, Keyword.get(opts, :retry_reject, false))
      end

      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.internal(),
        message: "invite failed: the invite event could not be written"
    end
  end

  # `:duplicate_event`: the room process classified the failed insert of the invite event as a unique violation
  defp unique_violation?(:duplicate_event), do: true
  defp unique_violation?(%Postgrex.Error{postgres: %{pg_code: "23505"}}), do: true
  defp unique_violation?(_reason), do: false

  # Best effort (no transaction spans the row and the event). A failed reject leaves a joinable invitation without an invite event
  # ("half invitation"): logged at ERROR (value-free: room id and error class), retried once where the room outlives the request
  # (POST /invite); createRoom deletes the whole room instead.
  defp reject_invitation_after_failed_event(room_id, invitee, retry?) do
    case try_reject_invitation(room_id, invitee) do
      :ok ->
        :ok

      {:error, reason} ->
        if retry? do
          case try_reject_invitation(room_id, invitee) do
            :ok -> :ok
            {:error, reason} -> log_half_invitation(room_id, reason)
          end
        else
          log_half_invitation(room_id, reason)
        end
    end
  end

  defp log_half_invitation(room_id, reason) do
    Logger.error("invite: failed to reject the invitation of #{room_id} after a failed invite event, half invitation remains (#{db_error_class(reason)})")
  end

  # `:pg.get_members/1` (cluster-safety): the long-poll task of the invitee may run on another node.
  defp wake_invitee(invitee, room_id) do
    Enum.each(:pg.get_members("user:#{invitee}"), &send(&1, {:new_invite, room_id}))
  end

  # createRoom step 8 (D8): the invite events in list order, each stamped strictly after the previous event of the chain.
  # Every failure raises (fatal: orphan cleanup, 500). The creator is the inviter; the room was just created, so the
  # member set is read once (the invitees are validated: not the creator, de-duplicated, local, existing).
  #
  # D9 (Kassandra L-4): the `{:new_invite}` wake-ups are sent only AFTER every invite of the list was written: a failing
  # later invite makes createRoom delete the room, and an earlier invitee must not have been woken for a room that vanishes.
  defp emit_invites(_room_id, _creator_id, [], _is_direct, last_ts), do: last_ts

  defp emit_invites(room_id, creator_id, invitees, is_direct, last_ts) do
    members = Nebu.Matrix.Room.Server.get_state(room_id).members

    last_ts =
      Enum.reduce(invitees, last_ts, fn invitee, ts ->
        do_invite!(room_id, creator_id, invitee, members, is_direct: is_direct, not_before: ts + 1, wake: false, caps: :prechecked)
      end)

    Enum.each(invitees, &wake_invitee(&1, room_id))
    last_ts
  end

  def get_messages(request, stream) do
    room_id = request.room_id
    from_token = request.from_token
    limit = max(1, min(request.limit, 100))
    direction = if request.direction in ["f", "b"], do: request.direction, else: "b"

    # Extract caller identity from request metadata (set by OIDC plug).
    {user_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    # Room existence check — Room GenServer must be running.
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        # Membership check — caller must be a room member.
        state = room_registry_module().get_state(room_id)

        unless MapSet.member?(state.members, user_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "#{user_id} is not a member of #{room_id}"
        end

        # Story history-visibility-enforcement (D6): the page of the events the caller may see (fail closed: a read failure is a
        # handled 500, never an unfiltered page).
        # security cycle 1: a request read runs under the 2 s statement timeout (never the /sync reads)
        {events, next_batch, prev_batch} = visible_page!(room_id, user_id, direction, limit, from_token, timeout: true)

        core_events = event_maps_to_core_events(events, user_id)

        %Core.GetMessagesResponse{
          events: core_events,
          next_batch: next_batch,
          prev_batch: prev_batch
        }
    end
  end

  # ─── Story history-visibility-enforcement: the viewer-aware reads (D6-D8, D14) ──────────────────────────────────────────────
  # Every client-serving event read goes through `viewer_read/3`: the viewer-aware read of messages_db_module() with the viewer
  # (the TRUSTED session user). The rule itself lives in ONE SQL fragment of Room.DB; nothing is filtered here. Seam (D14 (b)):
  # a TEST db module that does not export the viewer-aware read falls back to its unfiltered function (the old fakes); the real
  # Nebu.Matrix.Room.DB never falls back: without its viewer-aware read the answer is an error (fail closed).
  defp viewer_read(fun, args, fallback) do
    mod = messages_db_module()

    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) -> apply(mod, fun, args)
      mod != Nebu.Matrix.Room.DB -> fallback.(mod)
      true -> {:error, :viewer_read_unavailable}
    end
  end

  # D14 (a): a failed visibility-filtered read is ONE value-free ERROR line (the room id and the error class) and a handled error:
  # `:internal` (the generic 500) for the request reads, `:unavailable` (503 M_UNAVAILABLE, no since token persisted) for the
  # incremental /sync. Never an unfiltered or a silently shortened answer.
  defp history_read_failed!(room_id, reason, kind) do
    Logger.error("history visibility: the events of #{room_id} could not be read (#{db_error_class(reason)})")

    case kind do
      :unavailable -> raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.unavailable(), message: "the room history is unavailable"
      :internal -> raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "the room history could not be read"
    end
  end

  # Security cycle 1 (HIGH #1 (d)): the reads of ONE client request (`/messages`, `/event`, `/relations`, `/search`) run in a
  # transaction under a 2 s statement timeout (`with_read_timeout/1` of the db module; a module without it, e.g. a Repo-less unit
  # double, runs `fun` as is). A timeout is a read failure: the handled 500 of the caller. Not for the /sync reads.
  # `mod` is the db module that does the read (`search_db_module()` for /search); a module without `with_read_timeout/1` runs `fun`
  # as is
  defp with_read_timeout(mod \\ messages_db_module(), fun) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :with_read_timeout, 1) and Process.whereis(Nebu.Repo) != nil,
      do: mod.with_read_timeout(fun),
      else: fun.()
  end

  # /messages and the initial /sync timeline: `{events, next_batch, prev_batch}` of fetch_visible_events/5 (`timeout: true` for
  # the request read); a `from` token that names no storable event (a NUL) is the unknown-event 404. `head: pos` (the initial
  # /sync, story sync-stream-position D12; and the incremental read of a joined room without a cursor) bounds the page by the room
  # position read before the fetch, through fetch_visible_events/6; a TEST db module without the bounded read answers the unbounded
  # one. `failure: :unavailable` makes a failed read the 503 of an incremental /sync instead of the 500.
  defp visible_page!(room_id, viewer, direction, limit, from_token, opts) do
    args = [room_id, viewer, direction, limit, from_token]
    head = Keyword.get(opts, :head)
    mod = messages_db_module()

    args =
      if is_integer(head) and Code.ensure_loaded?(mod) and function_exported?(mod, :fetch_visible_events, 6),
        do: args ++ [head],
        else: args

    read = fn ->
      viewer_read(:fetch_visible_events, args, fn mod ->
        mod.fetch_events(room_id, direction, limit, from_token)
      end)
    end

    result = if Keyword.get(opts, :timeout, false), do: with_read_timeout(read), else: read.()

    case result do
      {:ok, events, next_batch, prev_batch} -> {events, next_batch, prev_batch}
      {:error, :not_found} -> event_not_found!()
      {:error, reason} -> history_read_failed!(room_id, reason, Keyword.get(opts, :failure, :internal))
    end
  end

  # The incremental /sync timeline of ONE room by position (story sync-stream-position, D4 / D5): `{events, limited}` of the range
  # `(after_pos, head]`, the NEWEST `limit` visible events oldest first, `limited` when a further visible event exists. A db module
  # without the range read is unavailable (no unfiltered fallback); a failure is the 503 (no token persisted).
  # `segmented?` (story sync-rejoin-range-scan-bound, D3 / D5): the room can hold a hidden stretch between the base and the head, so
  # the read is the segment-driven, position-bounded one (`Room.DB.fetch_visible_events_in_range_segmented/5`, same answer as the
  # plain range read). A TEST db module without it answers through its plain range read; the real Room.DB never falls back.
  defp visible_range!(room_id, viewer, after_pos, head, limit, segmented?) do
    args = [room_id, viewer, after_pos, head, limit]
    plain = fn -> viewer_read(:fetch_visible_events_in_range, args, fn _test_module -> {:error, :viewer_read_unavailable} end) end

    result =
      if segmented?,
        do: viewer_read(:fetch_visible_events_in_range_segmented, args, fn _test_module -> plain.() end),
        else: plain.()

    case result do
      {:ok, newest_first} -> {newest_first |> Enum.take(limit) |> Enum.reverse(), length(newest_first) > limit}
      {:error, reason} -> history_read_failed!(room_id, reason, :unavailable)
    end
  end

  # /event and the thread roots: `{:ok, event_map} | {:error, :not_found} | {:error, reason}` (an invisible event is :not_found)
  defp visible_event(event_id, room_id, viewer) do
    viewer_read(:fetch_visible_event, [event_id, room_id, viewer], fn mod -> mod.fetch_event(event_id, room_id) end)
  end

  # the parent of /relations: a TEST db module without fetch_visible_event/3 answers through its old event_in_room?/2
  defp visible_parent(event_id, room_id, viewer) do
    viewer_read(:fetch_visible_event, [event_id, room_id, viewer], fn mod ->
      if mod.event_in_room?(event_id, room_id), do: {:ok, %{}}, else: {:error, :not_found}
    end)
  end

  defp visible_relations(room_id, viewer, event_id, rel_type, limit, opts) do
    viewer_read(:fetch_visible_events_by_relation, [room_id, viewer, event_id, rel_type, limit, opts], fn mod ->
      mod.fetch_events_by_relation(room_id, event_id, rel_type, limit, opts)
    end)
  end

  @doc """
  Story history-visibility-enforcement (security cycle 1, LOW #4): is `event_id` an event of `room_id` that `user_id` may see?
  The `m.fully_read` check of POST /read_markers: a hidden event is refused exactly like an unknown one (no existence oracle).
  A NUL id or a failing read is `false` (fail closed; the read failure is logged value-free).
  """
  @spec visible_event?(String.t(), String.t(), String.t()) :: boolean()
  def visible_event?(room_id, user_id, event_id) do
    if contains_nul?([room_id, user_id, event_id]) do
      false
    else
      case visible_event(event_id, room_id, user_id) do
        {:ok, _event} ->
          true

        {:error, :not_found} ->
          false

        {:error, reason} ->
          Logger.error("history visibility: the events of #{room_id} could not be read (#{db_error_class(reason)})")
          false
      end
    end
  end

  # D7 / D8: an unknown and an invisible event answer the same fixed body (no existence oracle)
  defp event_not_found! do
    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), errcode: "M_NOT_FOUND", message: "Event not found"
  end

  # Convert a DB event map (string keys) to a %Core.Event{} struct.
  # The `content` column is JSONB — Postgrex returns it as either an Elixir map,
  # a %Postgrex.JSONB{decoded: map} struct, or a binary string.
  # All three forms are normalised to a map before re-encoding.
  defp event_map_to_core_event(event) do
    # content from the DB may arrive as:
    #   - %Postgrex.JSONB{decoded: map} struct (Story 9-30 fix — must be before is_map)
    #   - Elixir map (Postgrex decoded JSONB object directly)
    #   - Elixir binary/string (Postgrex decoded JSONB string)
    raw = Map.get(event, "content", %{})
    content_map =
      cond do
        # Postgrex returns JSONB columns as %Postgrex.JSONB{decoded: map}.
        # Postgrex is not a direct dep of event_dispatcher so we match by shape
        # rather than module name. Only DB-sourced structs appear in `content`.
        is_struct(raw) and Map.has_key?(raw, :decoded) and is_map(raw.decoded) -> raw.decoded
        is_map(raw) -> raw
        is_binary(raw) ->
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end
        true -> %{}
      end
    content_json = Jason.encode!(content_map)

    %Core.Event{
      event_id: Map.get(event, "event_id", ""),
      room_id: Map.get(event, "room_id", ""),
      sender_id: Map.get(event, "sender", ""),
      event_type: Map.get(event, "event_type", ""),
      content: content_json,
      origin_ts: Map.get(event, "origin_server_ts", 0),
      server_ts: System.system_time(:millisecond),
      state_key: Map.get(event, "state_key") || "",
      # Code-review cycle 1 (MAJOR-2): the raw DB map's "state_key" key is
      # Elixir nil ONLY when the events.state_key column itself was SQL NULL
      # (a genuine non-state event) — a real state event's column is never
      # NULL, even when its value is "" (m.room.name/topic/power_levels/
      # create). This is the SAME signal `event_maps_to_core_events/1` below
      # already uses to build the predecessor batch; threading it onto the
      # struct itself lets `Nebu.Matrix.Http.put_state_key/2` tell "genuine
      # state event with empty state_key" apart from "not a state event at
      # all" without re-deriving it from the now-collapsed `state_key` field.
      is_state_event: Map.get(event, "state_key") != nil
    }
  end

  # Bugfix unsigned-replaces-state (AC5): guards the batched DB lookup behind
  # function_exported?/3, exactly like forgotten_room_ids/1 above — an
  # injected FakeDB (fast unit tests that stub messages_db_module/
  # rooms_db_module without a real Postgres, excluded from :integration) safely
  # degrades to "no predecessor keys anywhere" instead of crashing with
  # UndefinedFunctionError. The real Nebu.Matrix.Room.DB always implements
  # fetch_state_predecessors/1 (room/db.ex), so production and the
  # :integration-tagged tests that run against the real Repo get real values.
  #
  # Code-review cycle 1 (MINOR): two additions beyond the bare
  # function_exported?/3 check, mirroring unforget_room/2's double-guard
  # above (server.ex:57-66):
  #   - Code.ensure_loaded?/1 FIRST — function_exported?/3 can give a false
  #     negative for a module that technically defines the function but has
  #     not been loaded into the code server yet; ensure_loaded?/1 forces that
  #     before asking.
  #   - Process.whereis(Nebu.Repo) != nil — messages_db_module/0 defaults to
  #     the REAL Nebu.Matrix.Room.DB (not a FakeDB) when a test never
  #     overrides it. That module DOES export fetch_state_predecessors/1, so
  #     function_exported?/3 alone would return true even in a Repo-less unit
  #     test and crash inside Ecto.Adapters.SQL.query/3 the moment the batch is
  #     non-empty — exactly the gap this check closes.
  #
  # Story history-visibility-enforcement (D10): every caller passes the viewer; the real Room.DB serves a predecessor only when it
  # is visible to the viewer (a nil viewer serves none). A test double with only fetch_state_predecessors/1 keeps its old answer.
  defp fetch_state_predecessors_strict!(_mod, [], _room_id, _viewer), do: %{}

  defp fetch_state_predecessors_strict!(mod, slots, room_id, viewer) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :fetch_state_predecessors, 2) and Process.whereis(Nebu.Repo) != nil do
      result =
        try do
          mod.fetch_state_predecessors(slots, strict: true, viewer: viewer)
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case result do
        {:ok, predecessors} when is_map(predecessors) ->
          predecessors

        other ->
          reason = with({:error, reason} <- other, do: reason)

          if member_read_unavailable?(reason), do: raise(Nebu.Matrix.Error, member_list_unavailable(room_id, reason))

          Logger.error("member state: the predecessors of the member events of #{room_id} could not be read (#{db_error_class(reason)})")
          room_state_unavailable!()
      end
    else
      fetch_state_predecessors_batch(mod, slots, viewer)
    end
  end

  defp fetch_state_predecessors_batch(_mod, [], _viewer), do: %{}

  defp fetch_state_predecessors_batch(mod, slots, viewer) do
    loaded? = Code.ensure_loaded?(mod) and Process.whereis(Nebu.Repo) != nil

    cond do
      loaded? and function_exported?(mod, :fetch_state_predecessors, 2) ->
        mod.fetch_state_predecessors(slots, viewer: viewer)

      loaded? and function_exported?(mod, :fetch_state_predecessors, 1) ->
        mod.fetch_state_predecessors(slots)

      true ->
        # Debug (not warning): this is the EXPECTED path for every fast,
        # Repo-less unit test that exercises get_initial_sync/fetch_delta_rooms
        # with a FakeDB (or the real DB module but no Repo started) — logging at
        # warning level here would spam test/dev output on every such /sync
        # call. Mirrors the same hot-path/log-level rationale already
        # established in Nebu.Matrix.Http.build_joined_rooms/1's own
        # Logger.debug for a sibling "identity unavailable" condition. The
        # genuinely actionable failure (a real DB error once Repo IS running)
        # is logged at warning level inside Room.DB.fetch_state_predecessors/1
        # itself, not here.
        Logger.debug(
          "fetch_state_predecessors_batch: #{inspect(mod)} unavailable (not loaded/exported, or no " <>
            "Repo running) — predecessor keys omitted for #{length(slots)} slot(s)"
        )

        %{}
    end
  end

  # Bugfix unsigned-replaces-state (AC1/AC2/AC5): batched drop-in replacement
  # for `Enum.map(raw_events, &event_map_to_core_event/1)` at every call site
  # that serialises DB event maps into client-facing Core.Event structs (GET
  # /messages, GET /event/{eventId}, GET .../relations/*, and /sync's
  # timeline.events via get_initial_sync/fetch_delta_rooms). ONE additional
  # query for the WHOLE `raw_events` list THIS FUNCTION WAS CALLED WITH (never
  # call event_map_to_core_event/1 plus a per-event lookup in a loop — that is
  # the exact N+1 AC5 forbids). The GRANULARITY of that list varies by caller,
  # consistent with attach_predecessors_to_state_events/2's own per-room
  # batching below (Dev Notes' explicitly-sanctioned "per room, not per
  # event" design — NOT one query for the whole /sync response): for
  # get_initial_sync/2 and fetch_delta_rooms/3, `raw_events` is ONE room's
  # timeline window, so this is one additional query per room, same as the
  # state-side batch; for GET /messages / GET /event/{eventId} / relations,
  # `raw_events` is that single response's own event list, so it is one query
  # per response there (there is only one "room" in play for those endpoints).
  #
  # `Map.get(ev, "state_key") != nil` is the ONLY reliable "is this raw DB
  # event a state event" signal here — the state_key VALUE alone is ambiguous
  # once collapsed onto a Core.Event (both "not a state event" and "a state
  # event whose real state_key is the empty string" — e.g. m.room.name/topic/
  # power_levels/create — serialise to the same "" via event_map_to_core_event/1's
  # `|| ""`). The raw DB map's "state_key" key is Elixir `nil` ONLY when the
  # `events.state_key` column itself was SQL NULL (a genuine non-state event);
  # a real state event's column is never NULL, even when its value is "" (see
  # Room.DB.insert_event/1's own comment on this exact point). This is
  # DIFFERENT from the pre-existing `Map.has_key?(ev, "state_key")` check a
  # few dozen lines below in fetch_delta_rooms/3: that check is actually
  # always-true in practice (every @sql_fetch_events_since-family query
  # unconditionally SELECTs the state_key column, so the map always has the
  # key, nil value or not) — harmless there only because "m.room.message"
  # never collides with a real state event_type. Checking the VALUE against
  # `nil` (this function) is the correct, non-coincidental test.
  defp event_maps_to_core_events(raw_events, viewer) do
    core_events = raw_events |> Enum.map(&event_map_to_core_event/1) |> apply_redactions()

    slots =
      raw_events
      |> Enum.filter(fn ev -> Map.get(ev, "state_key") != nil end)
      |> Enum.map(fn ev ->
        {
          Map.get(ev, "event_id", ""),
          Map.get(ev, "room_id", ""),
          Map.get(ev, "event_type", ""),
          Map.get(ev, "state_key"),
          Map.get(ev, "origin_server_ts", 0)
        }
      end)
      |> Enum.reject(fn {event_id, _, _, _, _} -> event_id == "" end)

    predecessors_by_id = fetch_state_predecessors_batch(messages_db_module(), slots, viewer)

    Enum.map(core_events, &put_predecessor(&1, predecessors_by_id))
  end

  # story state-writer-redaction (D6): prune on read. ONE batched `redactions_for/1` per call (the granularity of the predecessor
  # batch: one per joined room of a /sync, one per /messages, /event, /relations response, one for all leave entries). FAIL CLOSED
  # (security cycle 1, review M1): a failing lookup, and for the real Nebu.Matrix.Room.DB also a missing Repo or function, is a
  # handled 500 (value-free ERROR log), never an unpruned page. `nil` (nothing pruned) only for an injected TEST db module without
  # the function or without a Repo (the Repo-less unit suites).
  defp redaction_index([]), do: nil

  defp redaction_index(event_ids) do
    mod = messages_db_module()
    available? = Code.ensure_loaded?(mod) and function_exported?(mod, :redactions_for, 1) and Process.whereis(Nebu.Repo) != nil

    cond do
      available? ->
        mod.redactions_for(event_ids) |> redaction_index_of()

      mod == Nebu.Matrix.Room.DB ->
        Logger.error("redactions_for unavailable (no Repo or no function): the response is refused")
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "redactions_for failed"

      true ->
        nil
    end
  end

  defp redaction_index_of({:ok, rows}), do: Nebu.Matrix.Redaction.index(rows)
  defp redaction_index_of({:error, reason}), do: redaction_lookup_failed!(reason)

  defp redaction_lookup_failed!(reason) do
    Logger.error("redactions_for failed (#{db_error_class(reason)}): the response is refused")
    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "redactions_for failed"
  end

  defp apply_redactions(core_events), do: apply_redactions(core_events, redaction_index(for(%{event_id: id} <- core_events, id != "", do: id)))

  defp apply_redactions(core_events, nil), do: core_events
  defp apply_redactions(core_events, index), do: Enum.map(core_events, &prune_event(&1, index))

  # a redacted event through the ONE prune rule (Nebu.Matrix.Redaction.prune/2, review M5): content {} and the served redaction as
  # `redacted_because`, rendered into the Core.Event fields
  defp prune_event(%{event_id: id} = event, index) do
    case index.targets[id] do
      nil ->
        render_redaction_event(event, index)

      row ->
        pruned = Nebu.Matrix.Redaction.prune(%{"content" => event.content}, row)
        %{event | content: Jason.encode!(pruned["content"]), redacted_because: Jason.encode!(pruned["redacted_because"])}
    end
  end

  # a redaction event: `content.redacts` and the top-level `redacts` only when the writer made it; a legacy row never (its stored
  # key is dropped, Oracle Q9, follow-up `gd`)
  defp render_redaction_event(%{event_type: "m.room.redaction"} = event, index) do
    target = with %{"redacts" => target} <- index.by_id[event.event_id], do: target
    {content, redacts} = Nebu.Matrix.Redaction.served_content(event.content, target)
    %{event | content: Jason.encode!(content), redacts: redacts || ""}
  end

  defp render_redaction_event(event, _index), do: event

  # Story member-event-prev-content (D10): fills the three predecessor fields of a Core.Event / Core.SyncRoomStateEvent
  # from the answer of the batched lookup (a struct UPDATE, so every other field survives). An event without an entry in
  # the answer (no predecessor, or the lookup unavailable) is returned unchanged: its three fields stay "".
  defp put_predecessor(%{event_id: event_id} = event, predecessors_by_id) do
    case Map.get(predecessors_by_id, event_id) do
      %{event_id: predecessor_id, content: content, sender: sender} ->
        %{event | replaces_state: predecessor_id, prev_content: Jason.encode!(content), prev_sender: sender}

      _ ->
        event
    end
  end

  def set_power_levels(request, stream) do
    room_id = request.room_id
    power_levels_json = request.power_levels_json

    # Extract caller identity from request metadata (set by OIDC plug).
    {user_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    # Validate caller identity.
    if is_nil(user_id) or user_id == "" do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.unauthenticated(),
        message: "missing x-user-id metadata"
    end

    # Room existence check — Room GenServer must be running.
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        new_levels =
          case Jason.decode(power_levels_json) do
            {:ok, map} -> map
            {:error, _} ->
              raise Nebu.Matrix.Error,
                status: Nebu.Matrix.Status.invalid_argument(),
                message: "invalid power_levels_json"
          end

        # story power-levels-enforcement (D1): the client mode of the ONE power-level writer (the v10 rules), not the internal one
        case change_power_levels_as_client(room_id, user_id, new_levels) do
          {:ok, _event_id, _outcome} -> %Core.SetPowerLevelsResponse{}
          {:error, reason} -> power_levels_refusal!(room_id, reason)
        end
    end
  end

  def set_presence(_request, _stream) do
    %Core.SetPresenceResponse{}
  end

  def get_presence(request, _stream) do
    user_id = request.user_id

    {:ok, %{status: status, last_active_at: last_active_at}} =
      presence_module().get_presence(user_id)

    now_ms = System.system_time(:millisecond)

    last_active_ago =
      if is_nil(last_active_at) do
        0
      else
        max(0, now_ms - last_active_at)
      end

    %Core.GetPresenceResponse{
      presence: Atom.to_string(status),
      last_active_ago: last_active_ago
    }
  end

  def update_profile(request, stream) do
    {user_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    if is_nil(user_id) or user_id == "" do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.unauthenticated(),
        message: "missing x-user-id metadata"
    end

    # Guard: caller can only update their own profile (Go already enforces this,
    # but defense-in-depth at Core level).
    if request.user_id != user_id do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        message: "cannot update another user's profile"
    end

    displayname = if request.displayname == "", do: nil, else: request.displayname
    avatar_url = if request.avatar_url == "", do: nil, else: request.avatar_url

    case profile_db_module().upsert_profile(user_id, displayname, avatar_url) do
      :ok ->
        %Core.UpdateProfileResponse{}

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "upsert_profile failed: #{inspect(reason)}"
    end
  end

  def set_typing(request, _stream) do
    room_id = request.room_id
    user_id = request.user_id
    typing = request.typing
    # 30_000ms is the Matrix-spec default for how long a typing indicator
    # persists before auto-clearing. This is a FEATURE duration, not a
    # connection hold time — the endpoint returns 200 immediately after
    # setting the typing state. Do NOT conflate with the sync long-poll cap.
    timeout_ms = request.timeout_ms |> max(0) |> min(30_000)

    # Room existence check.
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        state = room_registry_module().get_state(room_id)

        unless MapSet.member?(state.members, user_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "#{user_id} is not a member of #{room_id}"
        end

        # Delegate typing state management to Room GenServer.
        :ok = room_registry_module().set_typing(room_id, user_id, typing, timeout_ms)

        %Core.SetTypingResponse{}
    end
  end

  def send_receipt(request, _stream) do
    room_id = request.room_id
    receipt_type = request.receipt_type
    event_id = request.event_id

    # user_id is sent in the request body (same as join_room pattern).
    user_id = request.user_id

    if is_nil(user_id) or user_id == "" do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.unauthenticated(),
        message: "missing user_id in request"
    end

    ensure_room_member!(room_id, user_id)

    case receipt_db_module().upsert_receipt(room_id, user_id, receipt_type, event_id) do
      :ok ->
        %Core.SendReceiptResponse{}

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "upsert_receipt failed: #{inspect(reason)}"
    end
  end

  @doc """
  Raises `Nebu.Matrix.Error` (not_found when the room does not exist, permission_denied
  when `user_id` is not a member) unless `user_id` is a member of `room_id`.

  Shared by `send_receipt/2` and `POST /rooms/{roomId}/read_markers` so both refuse
  identically (room-account-data-and-read-markers).
  """
  def ensure_room_member!(room_id, user_id) do
    # Room existence check — start on demand (mirrors sync.ex line 1034–1035).
    # start_room/1 is idempotent: returns {:ok, pid} whether the GenServer was
    # already running or was just started from DB. {:error, _} maps to not_found
    # because the only failure path is Room.Server.init/1 returning {:stop, _},
    # which happens when load_members returns {:error, :not_found} (room absent
    # from DB). Note: Horde supervisor errors (e.g. :max_children) would also hit
    # this branch and be surfaced as not_found — acceptable trade-off consistent
    # with sync.ex and unarchive_room patterns across the codebase (AA-1).
    case Nebu.Matrix.Room.RoomSupervisor.start_room(room_id) do
      {:error, _reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        # Guard against a race where the GenServer dies between start_room and
        # get_state (e.g. Horde CRDT reconciliation). Mirrors get_room_state/2
        # helper at line ~922–938. Surfaces as not_found rather than a raw exit.
        state =
          try do
            room_registry_module().get_state(room_id)
          catch
            :exit, {:noproc, _} ->
              raise Nebu.Matrix.Error,
                status: Nebu.Matrix.Status.not_found(),
                message: "room not found: #{room_id}"
          end

        unless MapSet.member?(state.members, user_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "#{user_id} is not a member of #{room_id}"
        end
        :ok
    end
  end

  def validate_token(request, stream) do
    {user_id, system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    if is_nil(user_id) or user_id == "" do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.unauthenticated(),
        message: "missing x-user-id metadata"
    end

    # Use the configurable token_validator_module when set (e.g. in tests).
    # Fall back to the standard Nebu.Matrix.Session.TokenValidator in production.
    validate_result =
      case token_validator_module() do
        nil ->
          Nebu.Matrix.Session.TokenValidator.validate(
            user_id,
            system_role,
            request.display_name,
            request.email
          )
        mod ->
          mod.validate(user_id, system_role, request.display_name, request.email)
      end

    case validate_result do
      {:ok, user} ->
        # Upsert profile row on every successful login so GET /profile/{userId} returns
        # 200 for OIDC-provisioned users (Bug 2a fix). Non-fatal: profile write failure
        # must not block login — the provisioned user session is already valid.
        display_name_for_profile =
          if request.display_name == "", do: nil, else: request.display_name

        case profile_db_module().upsert_profile(user_id, display_name_for_profile, nil) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("validate_token: profile upsert failed for #{user_id}: #{inspect(reason)}")
        end

        # Story personal-self-room + admin-auto-join-rooms: fire-and-forget room setup.
        # Non-blocking: the login response is not delayed.
        # Non-fatal: any DB error inside these helpers logs a warning and returns :ok.
        is_new = Map.get(user, :is_new, false)
        run_post_login_provisioning(user_id, is_new)

        %Core.ValidateTokenResponse{
          user_id: user.user_id,
          system_role: user.system_role,
          display_name: user.display_name,
          is_active: user.is_active
        }

      {:error, :deactivated} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.permission_denied(),
          message: "user account is deactivated"

      {:error, reason} ->
        Logger.error("validate_token failed", user_id: user_id, error: inspect(reason))

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "internal error"
    end
  end

  # ─── DeleteUserKeys — Story 5.7: DSGVO Key-Deletion ──────────────────────────
  #
  # Delegates to Nebu.Compliance.UserDeletion.delete_user_keys/3.
  # Maps Elixir result tuples to Nebu.Matrix.Status codes:
  #   {:ok, %{keys_deleted_at: ms}} → DeleteUserKeysResponse{status: "keys_deleted", keys_deleted_at: ms}
  #   {:error, :user_not_found}     → Nebu.Matrix.Status.not_found()
  #   {:error, :conflict}           → Nebu.Matrix.Status.already_exists()
  #   {:error, reason}              → Nebu.Matrix.Status.internal()
  #
  # The failure-invariant audit ("user_keys_deletion_attempted") is handled inside
  # Nebu.Compliance.UserDeletion — this handler does NOT need to emit it.

  def delete_user_keys(%Core.DeleteUserKeysRequest{} = req, _stream) do
    case Nebu.Compliance.UserDeletion.delete_user_keys(req.admin_user_id, req.target_user_id, req.reason) do
      {:ok, %{keys_deleted_at: keys_deleted_at_ms}} ->
        # story oauth-token-revocation-logout (R19): an erased user must not keep working tokens.
        # Best effort and AFTER the commit (the `deactivate_user` sequencing idiom): never raises,
        # never changes the response, warnings carry no secrets.
        end_sessions_after_erasure(req.target_user_id)
        %Core.DeleteUserKeysResponse{status: "keys_deleted", keys_deleted_at: keys_deleted_at_ms}

      {:error, :user_not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "user not found"

      {:error, :conflict} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.already_exists(),
          message: "deletion already in progress or completed"

      {:error, reason} ->
        Logger.error("delete_user_keys failed",
          target_user_id: req.target_user_id,
          reason: inspect(reason)
        )

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "deletion failed: #{inspect(reason)}"
    end
  end

  # R19: ends every OAuth session (with its device), every legacy opaque session, the legacy `sessions` / `sync_tokens`
  # rows and the legacy devices of an erased user. Each step is independent and best effort.
  defp end_sessions_after_erasure(user_id) do
    guarded("oauth sessions", fn ->
      case Nebu.Matrix.oauth_end_user_sessions(user_id) do
        {:ok, _devices} -> :ok
        {:error, reason} -> Logger.warning("delete_user_keys: could not end the user's OAuth sessions (#{inspect(reason)})")
      end
    end)

    guarded("legacy opaque sessions", fn -> Nebu.Matrix.Session.MatrixSessionStore.delete_for_user(user_id) end)
    guarded("legacy sessions", fn -> session_supervisor_module().destroy_session(user_id) end)
    # story gdpr-erasure-global-data (D12): the `devices` rows of LEGACY devices (display name, last seen IP) are not touched by
    # the OAuth teardown above; delete them here (idempotent, the OAuth devices are already gone)
    guarded("legacy devices", fn ->
      case Nebu.Matrix.end_all_user_devices(user_id) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("delete_user_keys: could not end the user's legacy devices (#{inspect(reason)})")
      end
    end)

    :ok
  end

  defp guarded(what, fun) do
    fun.()
  rescue
    e -> Logger.warning("delete_user_keys: ending #{what} failed: #{inspect(e.__struct__)}")
  catch
    :exit, _ -> Logger.warning("delete_user_keys: ending #{what} exited")
  end

  # ─── InvalidateUserSessions — Story 6.5: Admin deactivation revokes all sessions ─
  # Story 9-22 (AC4): Per-device logout when device_id is set.
  #
  # Two callers:
  #   - Admin deactivation: device_id="" → destroy_session/1 deletes all sync_tokens +
  #     sessions rows for the user and evicts from ETS.
  #   - (historical, story 9-22) per-device form: device_id="<id>" → destroy_session/2 deletes only
  #     the (user_id, device_id) sync_tokens + sessions rows; ETS is NOT evicted. The Matrix
  #     POST /logout no longer calls this (bugfix legacy-logout-per-device: it ends the presented
  #     credential's device through Nebu.Matrix.legacy_logout_device/1 with the locked teardown);
  #     the user-wide form (device_id="") is still used by POST /logout/all and by admin deactivation.
  #
  # Returns %Core.InvalidateUserSessionsResponse{ok: true} on success.
  # Raises Nebu.Matrix.Error with status=internal on failure (logged as warning, does not block).

  def invalidate_user_sessions(%Core.InvalidateUserSessionsRequest{} = req, _stream) do
    # AC4 (Story 9-22): per-device cleanup when device_id is present.
    result =
      if req.device_id != "" do
        session_supervisor_module().destroy_session(req.user_id, req.device_id)
      else
        session_supervisor_module().destroy_session(req.user_id)
      end

    # oidc-session-refresh MINOR-2: destroy_session/1,2 only clear the legacy
    # sessions/sync_tokens tables — NOT the opaque matrix_sessions rows, which
    # would otherwise keep a deactivated/logged-out user's session alive up to 8h.
    # Best-effort (delete_for_user[_device] log+swallow on error) so a failure here
    # never blocks the wider invalidation, matching the Go "logs as warning, does
    # not block" contract.
    if req.device_id != "" do
      Nebu.Matrix.Session.MatrixSessionStore.delete_for_user_device(req.user_id, req.device_id)
    else
      Nebu.Matrix.Session.MatrixSessionStore.delete_for_user(req.user_id)
    end

    case result do
      :ok ->
        %Core.InvalidateUserSessionsResponse{ok: true}

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "session invalidation failed: #{inspect(reason)}"
    end
  end

  # ─── InvalidateAllAdminSessions — Story 6.10: Admin config OIDC change ────────
  #
  # Called when OIDC issuer/client_id/client_secret changes via PATCH /admin/config.
  # Forces all active sessions to re-authenticate.
  #
  # Flow:
  #   1. List all active user_ids from ETS via Nebu.Matrix.Session.EtsStore.list_user_ids/0.
  #   2. Call session_supervisor_module().destroy_session/1 for each user (best-effort).
  #   3. Always return %Core.InvalidateAllAdminSessionsResponse{ok: true} — no-op if ETS empty.
  #
  # Never raises — individual session failures are silently ignored (best-effort).
  # Returns ok: true even if ETS is empty (idempotent no-op).

  def invalidate_all_admin_sessions(%Core.InvalidateAllAdminSessionsRequest{} = _req, _stream) do
    user_ids = Nebu.Matrix.Session.EtsStore.list_user_ids()

    Enum.each(user_ids, fn user_id ->
      case session_supervisor_module().destroy_session(user_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("InvalidateAllAdminSessions: failed to destroy session for #{user_id}: #{inspect(reason)}")
      end
    end)

    %Core.InvalidateAllAdminSessionsResponse{ok: true}
  end

  def get_pending_events(_request, _stream) do
    %Core.GetPendingEventsResponse{}
  end

  # ─── GetMetrics — Real implementation (Story 9.1, Task 8) ───────────────────
  #
  # Replaces the empty stub with real counts from ETS and Horde.
  #   - active_sessions: counted from Nebu.Matrix.Session.EtsStore.list_user_ids/0
  #     (already used in invalidate_all_admin_sessions/2).
  #   - room_count: counted from Horde.Registry.select/2
  #     (already used in subscribe_to_all_rooms/0).
  #   - msg_per_sec: kept at 0.0 for MVP (rolling window not yet implemented).

  def get_metrics(_request, _stream) do
    active_sessions = Nebu.Matrix.Session.EtsStore.list_user_ids() |> length()

    room_count =
      try do
        Horde.Registry.select(Nebu.Matrix.Room.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
        |> length()
      rescue
        _ -> 0
      catch
        _, _ -> 0
      end

    %Core.GetMetricsResponse{
      active_sessions: active_sessions,
      room_count: room_count,
      msg_per_sec: 0.0
    }
  end

  # ─── the member reads: GET /members and the /initialSync state (story membership-state-model) ───────────────────────

  # GET /rooms/{roomId}/members (D6): the member slice ONLY (no create / name / generic state read), the route's filters applied
  # in SQL, the predecessor keys in ONE batched statement. Joined members only.
  def get_room_members(%{room_id: room_id} = request, stream) do
    {caller_id, system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)
    state = readable_room_state!(room_id, caller_id, system_role)

    filters = [membership: Map.get(request, :membership), not_membership: Map.get(request, :not_membership)]

    events =
      room_id
      |> member_slice_events(state, filters, :request)
      |> attach_predecessors_to_state_events(room_id, :request, caller_id)

    %Core.GetRoomStateResponse{members: [], power_levels_json: "", room_name: "", state_events: events}
  end

  # The room state for a member read (D5, D6 (a), D16): a room that is not running is resolved by
  # `ensure_room_without_lazy_create!/3` (unknown or NUL id: 403, no row, no process, also for the system role; an archived room
  # cannot start: 404 as before, `gi` (e)); a user caller starts it only when his latest member event is `join` (Kassandra L-1).
  # A room process that does not answer is a handled 503 (also after a lazy start, MINOR-1). Only a member (or the system role)
  # is served: M_FORBIDDEN with a FIXED text otherwise.
  defp readable_room_state!(room_id, caller_id, system_role) do
    state =
      try do
        room_registry_module().get_state(room_id)
      catch
        :exit, {:noproc, _} -> start_readable_room!(room_id, caller_id, system_role)
        :exit, {:timeout, _} -> room_unavailable!()
      end

    unless system_role == "system" or MapSet.member?(state.members, caller_id) do
      not_a_member!()
    end

    state
  end

  defp start_readable_room!(room_id, caller_id, system_role) do
    before_start = if system_role == "system", do: fn -> :ok end, else: fn -> joined_before_start!(room_id, caller_id) end

    case ensure_room_without_lazy_create!(room_id, &room_state_unavailable!/0, before_start) do
      {:started, state} -> state
      # started concurrently by another request between the call and the lookup
      :running -> fetch_room_state(room_id)
    end
  catch
    :exit, {:timeout, _} -> room_unavailable!()
  end

  # D16: the caller's latest member event (an index lookup) decides before a stopped room is started
  defp joined_before_start!(room_id, caller_id) do
    result =
      try do
        rooms_db_module().get_member_membership(room_id, caller_id)
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, "join"} ->
        :ok

      {:ok, _not_joined} ->
        not_a_member!()

      other ->
        reason = with({:error, reason} <- other, do: reason)
        Logger.error("room resolution: failed to read the membership of the caller in #{room_id} (#{db_error_class(reason)})")
        room_state_unavailable!()
    end
  end

  defp not_a_member! do
    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: "You are not a member of this room"
  end

  defp room_unavailable! do
    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.unavailable(), message: "room unavailable"
  end

  # the generic 500 of a member read whose room state or member slice could not be read (the cause is logged value-free)
  defp room_state_unavailable! do
    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "the room state is unavailable"
  end

  # ─── AC #3: GetRoomState unary handler ──────────────────────────────────────
  #
  # Looks up the Room GenServer via the configurable room_registry_module.
  # In production, room_registry_module == Nebu.Matrix.Room.Server, whose get_state/1
  # calls GenServer.call(via(room_id), :get_state).
  # In tests, room_registry_module is overridden with FakeRoomRegistry.

  def get_room_state(request, stream) do
    room_id = request.room_id
    event_type = Map.get(request, :event_type, "")
    state_key = Map.get(request, :state_key, "")

    {caller_id, system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    state = readable_room_state!(room_id, caller_id, system_role)

    # Build the full state_events list for this room (the `/initialSync` state; story membership-state-model, D7): the member
    # slots from the member EVENTS, the predecessor keys of every slot in ONE batched statement (`fl` (c)).
    all_state_events = build_state_events(state, room_id, true, member_slice: :events, read: :request, viewer: caller_id)

    # Apply optional event_type / state_key filter (Story 7-19, AC2 + AC3 + AC6).
    # When event_type is empty, return all events (the /initialSync caller).
    # When event_type is set, filter to matching events; raise not_found if none match.
    filtered_events =
      if event_type == "" do
        all_state_events
      else
        matched =
          Enum.filter(all_state_events, fn ev ->
            ev.type == event_type && ev.state_key == state_key
          end)

        if matched == [] do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.not_found(),
            message: "no state event for type=#{event_type} state_key=#{state_key} in room #{room_id}"
        end

        matched
      end

    %Core.GetRoomStateResponse{
      members: MapSet.to_list(state.members),
      power_levels_json: Jason.encode!(state.power_levels),
      room_name: "",
      state_events: filtered_events
    }
  end

  # ─── SetRoomState — Spaces S2: generic Matrix state-event write ──────────────
  #
  # Implements PUT /_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}.
  #
  # SECURITY (Kassandra S1 forward-warning — this writes arbitrary client content):
  #   1. ALLOWLIST: only the writable content state types below are accepted.
  #      m.room.member / m.room.create (and anything else) → 403 M_FORBIDDEN. Those
  #      have dedicated authorized paths and must NOT be forgeable through this
  #      generic content PUT (no membership forging, no create rewrite).
  #      m.room.power_levels is dispatched to its own clause (set_power_levels_state/1,
  #      story power-levels-enforcement: the room-process writer, v10 change rules).
  #   2. POWER LEVEL: sender must be a room member with power_level >= events[type],
  #      else state_default (story power-levels-enforcement D5 (b)); a state key that
  #      starts with `@` must be the sender's own id (D5 (c)). Non-member → 403.
  #      Checked on the SNAPSHOT (the order of the answers) and decided AUTHORITATIVELY
  #      by the room process at the write (story state-writer-redaction, D8, `fv`).
  #   3. m.space.parent: the parent space (state_key) must exist (else 404) and the
  #      sender must be a member of it (else 403) — story 15.4 security requirement.
  #   4. Server-authoritative top-level fields (sender, type, room_id, event_id,
  #      origin_server_ts) are built by the room process (Room.Server.write_state/5,
  #      stamped max(now, latest slot ts + 1), one transaction) — never from the
  #      client. content_json is the ONLY client-controlled payload (decoded to a
  #      map; malformed → %{}, which is also the m.space.child unlink semantics).

  # Allowlist of state event types writable through the generic PUT (AC2).
  @writable_state_types ~w(
    m.space.child
    m.space.parent
    m.room.name
    m.room.topic
    m.room.avatar
    m.room.join_rules
    m.room.canonical_alias
    m.room.history_visibility
    m.room.guest_access
  )

  # story power-levels-enforcement (D1 - D3, D11): m.room.power_levels is decided AND written by the room-process power-level writer
  def set_room_state(%{event_type: @power_levels_type} = request, _stream), do: set_power_levels_state(request)

  def set_room_state(request, _stream) do
    room_id    = request.room_id
    sender_id  = request.sender_id
    event_type = request.event_type
    state_key  = Map.get(request, :state_key, "") || ""

    # AC2 — allowlist is the security boundary. Reject before touching the room so
    # a forbidden type cannot lazy-start a room or leak existence. m.room.member /
    # m.room.create land here too (not on the allowlist).
    unless event_type in @writable_state_types do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        errcode: "M_FORBIDDEN",
        message: "You are not a member of this room"
    end

    # Decode client content (malformed → %{}; empty {} is a valid m.space.child unlink).
    content =
      case Jason.decode(request.content_json) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    # story state-writer-redaction (D10 (a), follow-up `fz`): an unknown room answers 403 without a `rooms` row and without a room
    # process; a known room that is not running is started from the database. Then the SNAPSHOT of this request.
    # (security cycle 1, D15 (b)): the stopped-room path hands back the state it fetched, which is the snapshot then
    state =
      case ensure_room_without_lazy_create!(room_id, &state_write_failed!/0) do
        {:started, started_state} -> started_state
        :running -> fetch_room_state(room_id)
      end

    # The SNAPSHOT pre-check keeps the order of the answers (membership, level, `@` rule, then the content rules); the room process
    # decides the same three AUTHORITATIVELY at the write (story state-writer-redaction, D8, follow-up `fv`).
    state_write_precheck!(room_id, state, sender_id, event_type, state_key)

    # Story create-room-input-validation, AFTER the authorisation above (a refused sender never learns anything about
    # the alias store): the content rules of the two types that carry user-facing identifiers.
    case event_type do
      "m.room.canonical_alias" -> validate_put_canonical_alias(room_id, state_key, content)
      "m.room.name" -> validate_name_content(content)
      "m.room.topic" -> validate_topic_content(content)
      type when type in [@history_visibility_type, @guest_access_type] and state_key == "" -> validate_access_content(type, content)
      _ -> :ok
    end

    # AC4 — m.space.parent: parent space must exist + sender must be a member of it.
    if event_type == "m.space.parent" do
      check_parent_space_membership(state_key, sender_id)
    end

    case write_state_as_client(room_id, sender_id, event_type, state_key, content) do
      {:ok, event_id} -> %Core.SetRoomStateResponse{event_id: event_id}
      {:error, reason} -> state_write_refusal!(room_id, reason)
    end
  end

  defp state_write_precheck!(room_id, state, sender_id, event_type, state_key) do
    unless MapSet.member?(state.members, sender_id), do: state_write_refusal!(room_id, :sender_not_joined)

    unless Nebu.Matrix.Room.PowerLevels.can?(state.power_levels, sender_id, {:state, event_type}),
      do: state_write_refusal!(room_id, :insufficient_level)

    if String.starts_with?(state_key, "@") and state_key != sender_id, do: state_write_refusal!(room_id, :foreign_user_key)
    :ok
  end

  defp write_state_as_client(room_id, sender_id, event_type, state_key, content) do
    room_registry_module().write_state(room_id, sender_id, {event_type, state_key}, content, mode: :client)
  catch
    :exit, _reason -> {:error, :room_unavailable}
  end

  defp state_write_refusal!(room_id, reason) do
    forbidden = fn message ->
      raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: message
    end

    case reason do
      :sender_not_joined -> forbidden.("You are not a member of this room")
      :insufficient_level -> forbidden.("You do not have a high enough power level to set this state")
      :foreign_user_key -> forbidden.("You cannot set a state event whose state key is another user's id")
      :event_too_large -> too_large!(Nebu.Matrix.EventSize.message(:event_too_large))

      # story history-visibility-enforcement (security cycle 1, HIGH #1 (a)): the per-room cap on history-visibility events
      :hv_event_cap ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.resource_exhausted(),
          errcode: "M_LIMIT_EXCEEDED",
          message: "This room has too many history visibility changes"
      :room_archived -> raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "Room not found"

      :room_unavailable ->
        Logger.error("set_room_state: the room process of #{room_id} did not answer the state change")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.unavailable(),
          errcode: "M_UNAVAILABLE",
          message: "The room did not answer, the change may or may not have been applied"

      # :write_failed, :unsupported_db_module (logged by the room process with the error class): the generic 500, no inspect
      _failure ->
        state_write_failed!()
    end
  end

  defp state_write_failed!, do: raise(Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "set_room_state failed")

  # ─── PUT .../state/m.room.power_levels (story power-levels-enforcement, D1 - D3, D10, D11) ─────────────────────────────
  #
  # The router has charged the `moderation` tier and run its body checks (JSON object, NUL, depth, key sizes, the 65 536-byte
  # event). Here: the empty state key (a path-level rule), then the room process decides in the D2 order (membership, level,
  # shape, change rules, the no-op) and writes; this caller does NOT validate the shape first (MINOR-7: a non-member or a
  # member below the level learns nothing about the shape rules). The audit row follows the committed change.

  # the ten keys of the v10 levels content (the audit row names only these, D11)
  @power_levels_known_keys ~w(ban kick invite redact state_default events_default users_default users events notifications)

  @power_levels_refusals %{
    insufficient_level: "You do not have a high enough power level to change the power levels",
    above_own_level: "You cannot change a power level above your own",
    grant_above_own_level: "You cannot grant a power level above your own",
    target_not_lower: "You cannot change the power level of a user whose level is not lower than yours"
  }

  defp set_power_levels_state(request) do
    room_id = request.room_id
    sender_id = request.sender_id

    # D3: the levels event has exactly one slot, the empty state key (a Nebu choice; the rule wins over the `@` rule)
    if (Map.get(request, :state_key, "") || "") != "" do
      reject!("M_BAD_JSON", "m.room.power_levels requires an empty state key")
    end

    content =
      case Jason.decode(request.content_json) do
        {:ok, map} when is_map(map) -> map
        _other -> reject!("M_BAD_JSON", "Request body must be a JSON object")
      end

    _ = ensure_room_without_lazy_create!(room_id, &power_levels_not_changed!/0)

    case change_power_levels_as_client(room_id, sender_id, content) do
      {:ok, event_id, %{changed: changed?, previous: previous}} ->
        if changed?, do: audit_power_levels_change(sender_id, room_id, previous, content)
        %Core.SetRoomStateResponse{event_id: event_id}

      {:error, reason} ->
        power_levels_refusal!(room_id, reason)
    end
  end

  # The client mode of Room.Server.change_power_levels/4; a call that does not return (5 s, the process died) is
  # `:room_unavailable` (the change may or may not have been applied)
  defp change_power_levels_as_client(room_id, sender_id, content) do
    Nebu.Matrix.Room.Server.change_power_levels(room_id, sender_id, content, mode: :client)
  catch
    :exit, _reason -> {:error, :room_unavailable}
  end

  # PUT state (story power-levels-enforcement AC1 (b); the generic types since story state-writer-redaction, follow-up `fz`): an
  # unknown room answers 403 "You are not a member of this room" WITHOUT starting a room process or creating a `rooms` row; a known
  # room that is not running is started from the database (start_room/1: init loads the existing row) and its fetched state is
  # handed back (`{:started, state}`; a running room is `:running`). A failing status read is value-free logged and answered by
  # `on_db_error` (the 500 of the calling path). The member reads (`/members`, `/initialSync`; story membership-state-model, D6 (a))
  # resolve a room that is not running through it as well, with a `before_start` gate that runs after the status read and before
  # the start (their membership check, D16); an id with a NUL byte names no room (PostgreSQL rejects it): the fixed 403 before
  # any read (MINOR-3; reached by the member reads, the router already refuses such an id on the PUT-state routes).
  defp ensure_room_without_lazy_create!(room_id, on_db_error, before_start \\ fn -> :ok end) do
    if String.contains?(room_id, <<0>>), do: not_a_member!()

    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, _pid} ->
        :running

      {:error, :not_found} ->
        case rooms_db_module().get_room_status(room_id) do
          {:ok, _status} ->
            :ok = before_start.()
            {:started, fetch_room_state(room_id)}

          {:error, :not_found} ->
            not_a_member!()

          {:error, reason} ->
            Logger.error("room resolution: failed to read the room status of #{room_id} (#{db_error_class(reason)})")
            on_db_error.()
        end
    end
  end

  # every refusal of the power-level writer: explicit errcodes and FIXED texts (no client value is echoed)
  defp power_levels_refusal!(room_id, reason) do
    case reason do
      :sender_not_joined ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: "You are not a member of this room"

      atom when is_map_key(@power_levels_refusals, atom) ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: Map.fetch!(@power_levels_refusals, atom)

      {:invalid, text} ->
        reject!("M_BAD_JSON", text)

      :event_too_large ->
        too_large!(Nebu.Matrix.EventSize.message(:event_too_large))

      :room_archived ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "Room not found"

      :room_unavailable ->
        Logger.error("set_room_state: the room process of #{room_id} did not answer the power-level change")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.unavailable(),
          errcode: "M_UNAVAILABLE",
          message: "The room did not answer, the change may or may not have been applied"

      # :write_failed, :unsupported_db_module (logged by the room process with the error class)
      _failure ->
        power_levels_not_changed!()
    end
  end

  # the ONE raiser of the 500 M_UNKNOWN fixed text that Http.map_error/1 passes through (review cycle 0 I2)
  defp power_levels_not_changed! do
    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), errcode: "M_UNKNOWN", message: Nebu.Matrix.Http.power_levels_not_changed_text()
  end

  # D11: ONE `room_power_levels_changed` row after a COMMITTED change of the route (not the no-op, not a refusal), best effort: a
  # failing writer never undoes or fails the change (one value-free ERROR, the room id only; the moderation precedent, `fs`)
  #
  # Bounded, no client free text (review cycle 0 M2 / Kassandra M-1): `changed_keys` lists only the ten keys of the v10 content (the
  # seven integer keys, `users`, `events`, `notifications`); altered top-level keys of the client's own choosing are only COUNTED
  # (`other_keys_changed_count`, present only when > 0); `users_changed` holds at most 50 user ids (strict `UserId.valid?/1`, at most
  # 255 bytes each for an added or changed entry, validated before the write; an UNCHANGED relaxed-grammar entry is not altered and
  # never listed, so only a REMOVED stored entry can put a relaxed-grammar id (a port or above 255 bytes) into it, fix cycle 3
  # C2-I1) — the cap of 50 bounds the row either way.
  defp audit_power_levels_change(sender_id, room_id, previous, content) do
    users = altered_keys(map_or_empty(previous["users"]), map_or_empty(content["users"]))
    {known, other} = previous |> altered_keys(content) |> Enum.split_with(&(&1 in @power_levels_known_keys))

    metadata =
      %{
        "changed_keys" => Enum.sort(known),
        "users_changed" => users |> Enum.sort() |> Enum.take(50),
        "users_changed_count" => length(users)
      }
      |> then(fn m -> if other == [], do: m, else: Map.put(m, "other_keys_changed_count", length(other)) end)

    case audit_writer_module().log(sender_id, "room_power_levels_changed", "room", room_id, metadata, "success") do
      :ok -> :ok
      _other -> Logger.error("set_room_state: the audit row of the power-level change in #{room_id} could not be written")
    end
  rescue
    _e -> Logger.error("set_room_state: the audit row of the power-level change in #{room_id} could not be written")
  catch
    _kind, _reason -> Logger.error("set_room_state: the audit row of the power-level change in #{room_id} could not be written")
  end

  # the keys whose entry was added, changed or removed (raw comparison)
  defp altered_keys(old_map, new_map) do
    # strict (fix cycle 3, Kassandra C2-L1): a stored float replaced by the integer of the same value is an alteration
    for key <- Enum.uniq(Map.keys(old_map) ++ Map.keys(new_map)), not same_entry?(Map.fetch(old_map, key), Map.fetch(new_map, key)), do: key
  end

  defp same_entry?({:ok, a}, {:ok, b}), do: Nebu.Matrix.Room.PowerLevels.same_json?(a, b)
  defp same_entry?(:error, :error), do: true
  defp same_entry?(_a, _b), do: false

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_other), do: %{}

  # Fetch a room's state, lazy-starting the Room GenServer from DB on :noproc
  # (handles a Core restart / not-yet-started room). Mirrors get_room_state/2.
  defp fetch_room_state(room_id) do
    mod = room_registry_module()

    try do
      mod.get_state(room_id)
    catch
      :exit, {:noproc, _} ->
        case Nebu.Matrix.Room.RoomSupervisor.start_room(room_id) do
          {:error, _reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.not_found(),
              message: "room not found: #{room_id}"

          {:ok, _pid} ->
            try do
              mod.get_state(room_id)
            catch
              :exit, {:noproc, _} ->
                raise Nebu.Matrix.Error,
                  status: Nebu.Matrix.Status.not_found(),
                  message: "room not found: #{room_id}"
            end
        end
    end
  end

  # AC4 — m.space.parent security check: the parent space (state_key) must exist
  # and the sender must be a member of it. A non-existent parent → 404; a parent
  # the sender is not a member of → 403.
  defp check_parent_space_membership(parent_space_id, sender_id) do
    # Existence is authoritative on the m.room.create event in the events table.
    # Bugfix sync-state-events-missing-fields: the real DB's get_room_create_event/1
    # now returns a wider {:ok, content, event_id, ts} 4-tuple (AC2) — this call site
    # only cares about existence/content, so both the 4-tuple and the original
    # 2-tuple (fakes that predate the widening) are matched identically below.
    case rooms_db_module().get_room_create_event(parent_space_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "parent space not found: #{parent_space_id}"

      {:error, _reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "parent space not found: #{parent_space_id}"

      {:ok, _create_content} ->
        check_parent_space_membership_finish(parent_space_id, sender_id)

      {:ok, _create_content, _event_id, _origin_server_ts} ->
        check_parent_space_membership_finish(parent_space_id, sender_id)
    end
  end

  defp check_parent_space_membership_finish(parent_space_id, sender_id) do
    parent_state = fetch_room_state(parent_space_id)

    unless MapSet.member?(parent_state.members, sender_id) do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        message: "Sender is not a member of the parent space"
    end
  end

  # ─── GetSpaceHierarchy — Spaces S3: MSC2946 space hierarchy read ─────────────
  #
  # Implements GET /_matrix/client/v1/rooms/{roomId}/hierarchy.
  #
  # SECURITY (the visibility boundary — AC4):
  #   1. ROOT GATE: before ANY traversal, the requesting user must be able to see
  #      the root space. A non-member of a root that is NOT public AND NOT
  #      world-readable → permission_denied (403). This fires first so a private
  #      space's existence / children / members never leak to a non-member.
  #   2. Per-room visibility: each candidate room is resolved to either a summary
  #      (the user may see it) or :hidden (private + non-member, not world-readable).
  #      A hidden room is EXCLUDED from the response but its m.space.child edges are
  #      still traversed (spec) — the BFS sees only what the resolver exposes; it
  #      never reads private state itself.
  #   3. user_id is the authenticated caller (trusted identity) — never path/body.
  #
  # The BFS, depth/suggested filtering and opaque pagination live in
  # Nebu.Matrix.SpaceHierarchy; this wrapper supplies the DB-backed child_lookup +
  # room_summary resolvers and enforces the root gate.
  def get_space_hierarchy(request, _stream) do
    root_room_id = request.root_room_id
    user_id = request.user_id

    # AC4 root gate — must succeed BEFORE traversal. Lazy-starts the room; a
    # missing room → 404 (via fetch_room_state). Builds the root summary too so a
    # member's own root is always the first entry.
    {root_state, root_summary} = visible_summary_or_forbid!(root_room_id, user_id)

    opts = [
      limit: request.limit,
      max_depth: request.max_depth,
      suggested_only: request.suggested_only,
      from_token: request.from_token || "",
      child_lookup: &space_child_lookup/1,
      # Resolver: the root we already authorised (reuse its state/summary); any
      # other room goes through the visibility check (→ summary | :hidden).
      room_summary: fn room_id, uid ->
        cond do
          room_id == root_room_id -> {:ok, root_summary}
          true -> room_visibility_summary(room_id, uid)
        end
      end
    ]

    _ = root_state

    case Nebu.Matrix.SpaceHierarchy.get_hierarchy(root_room_id, user_id, opts) do
      {:error, :invalid_token} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.invalid_argument(),
          message: "invalid pagination token"

      {rooms, next_batch} ->
        %Core.GetSpaceHierarchyResponse{
          rooms: Enum.map(rooms, &to_hierarchy_room/1),
          next_batch_token: next_batch
        }
    end
  end

  # ── GET /_matrix/client/v1/room_summary/{roomIdOrAlias} (story oauth-room-summary-unrecognized) ──
  #
  # LOCAL-ONLY room preview (RU1): an alias resolves only through the local alias store, `via` does not
  # exist here. Order is load-bearing (RU3, trap 1): alias -> `get_room_status/1` (must be `"active"`) ->
  # ONLY THEN `get_state/1`. The state read lazy-starts a Room and `Room.Server.do_init/1` inserts a
  # `rooms` row for an unknown id: it must never see an unchecked, attacker-chosen id. Unknown, archived and
  # not-visible rooms all raise the same `not_found` (the router answers the byte-identical `404
  # M_NOT_FOUND "Room not found"`, anti-enumeration). Visibility (RU4): joined, a pending invite, a
  # `public` / `knock` / `knock_restricted` join rule or `world_readable` history; `restricted` rooms are
  # NOT visible through `allow`. Returns the plain, JSON-ready map of `Nebu.Matrix.RoomSummary.build/3`.
  # A store error raises `internal` (500 M_UNKNOWN) and logs ONLY the error class (no alias, no room id, no
  # error detail).
  def get_room_summary(%{room_id_or_alias: raw, user_id: user_id}, _stream) do
    room_id = resolve_summary_room_id(raw)
    state = fetch_summary_state(room_id)
    state_events = build_state_events(state, room_id)
    membership = summary_membership(room_id, user_id, state, state_events)

    Nebu.Matrix.RoomSummary.build(room_id, state_events, %{
      num_joined_members: MapSet.size(state.members),
      membership: membership
    })
  end

  defp resolve_summary_room_id("#" <> _ = alias_str) do
    case alias_db_module().lookup_alias(alias_str) do
      {:ok, room_id} when is_binary(room_id) -> room_id
      {:error, :not_found} -> raise_room_not_found(alias_str)
      {:error, reason} -> raise_summary_store_error(reason)
      _ -> raise_summary_store_error(:unexpected)
    end
  end

  defp resolve_summary_room_id(room_id), do: room_id

  # Existence BEFORE state (trap 1): only an active, known room may reach `fetch_room_state/1`.
  defp fetch_summary_state(room_id) do
    case rooms_db_module().get_room_status(room_id) do
      {:ok, "active"} -> fetch_room_state(room_id)
      {:ok, _archived} -> raise_room_not_found(room_id)
      {:error, :not_found} -> raise_room_not_found(room_id)
      {:error, reason} -> raise_summary_store_error(reason)
      _ -> raise_summary_store_error(:unexpected)
    end
  end

  defp summary_visible_by_rule?(state_events) do
    join_rule(state_events) in ["public", "knock", "knock_restricted"] or
      history_visibility(state_events) == "world_readable"
  end

  defp summary_pending_invite?(room_id, user_id) do
    case db_module_invite().pending_invite?(room_id, user_id) do
      {:ok, pending?} -> pending? == true
      {:error, reason} -> raise_summary_store_error(reason)
      _ -> raise_summary_store_error(:unexpected)
    end
  end

  defp summary_latest_membership(room_id, user_id) do
    case rooms_db_module().get_member_membership(room_id, user_id) do
      {:ok, m} -> m
      {:error, reason} -> raise_summary_store_error(reason)
      _ -> raise_summary_store_error(:unexpected)
    end
  end

  # The caller's `membership` AND the visibility decision in one place (RU4, RU5; review cycle 1, Kassandra
  # M-1). Joined => `join`. Otherwise the latest m.room.member event is read first: a `ban` revokes a still
  # pending invitation row (defence in depth next to `ban_user/2` rejecting the invitation), so a banned
  # former invitee sees the room only when its join rule / history makes it visible (membership `ban`). Then a
  # pending invite => `invite`; then the rule-visible case (`knock` / `leave`, never a member => `leave`, a
  # Nebu choice); anything else raises the RU3 not_found.
  defp summary_membership(room_id, user_id, state, state_events) do
    if MapSet.member?(state.members, user_id) do
      "join"
    else
      latest = summary_latest_membership(room_id, user_id)
      by_rule? = summary_visible_by_rule?(state_events)

      cond do
        latest == "ban" and by_rule? -> "ban"
        latest == "ban" -> raise_room_not_found(room_id)
        summary_pending_invite?(room_id, user_id) -> "invite"
        by_rule? and latest == "knock" -> "knock"
        by_rule? -> "leave"
        true -> raise_room_not_found(room_id)
      end
    end
  end

  defp raise_room_not_found(_what) do
    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "room not found"
  end

  defp raise_summary_store_error(reason) do
    Logger.warning("get_room_summary: store error (#{summary_error_class(reason)})")
    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "room summary unavailable"
  end

  defp summary_error_class(%{__struct__: module}), do: inspect(module)
  defp summary_error_class(reason) when is_atom(reason), do: inspect(reason)
  defp summary_error_class(_reason), do: "unknown"

  # child_lookup for the BFS: the room's current m.space.child edges
  # (state_key → child room id, decoded content). DB error → no children
  # (fail-closed: a transient error must not crash the whole hierarchy read).
  defp space_child_lookup(room_id) do
    case rooms_db_module().get_space_children(room_id) do
      {:ok, children} -> children
      {:error, reason} ->
        Logger.warning("get_space_hierarchy: child lookup failed for #{room_id}: #{inspect(reason)}")
        []
    end
  end

  # Root gate: resolve the root to {state, summary} or raise 403/404.
  # A non-existent room raises not_found inside fetch_room_state. A room the user
  # cannot see (private + non-member, not world-readable) → permission_denied.
  defp visible_summary_or_forbid!(room_id, user_id) do
    state = fetch_room_state(room_id)
    state_events = build_state_events(state, room_id)

    unless room_visible?(state, state_events, user_id) do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        message: "you are not allowed to view the hierarchy of #{room_id}"
    end

    {state, build_room_summary(room_id, state, state_events)}
  end

  # Per-room visibility resolver used during traversal: {:ok, summary} | :hidden.
  # A room whose GenServer cannot start (deleted / never existed) is :hidden — a
  # dangling m.space.child edge must not crash the traversal or leak a 404.
  defp room_visibility_summary(room_id, user_id) do
    try do
      state = fetch_room_state(room_id)
      state_events = build_state_events(state, room_id)

      if room_visible?(state, state_events, user_id) do
        {:ok, build_room_summary(room_id, state, state_events)}
      else
        :hidden
      end
    rescue
      Nebu.Matrix.Error -> :hidden
    end
  end

  # Visibility predicate: a user may see a room iff they are a member, OR the room
  # is publicly joinable (join_rule == "public"), OR it is world-readable
  # (history_visibility == "world_readable"). Otherwise hidden.
  defp room_visible?(state, state_events, user_id) do
    MapSet.member?(state.members, user_id) or
      join_rule(state_events) == "public" or
      history_visibility(state_events) == "world_readable"
  end

  # Build an MSC2946 room summary map from the room's resolved state events.
  defp build_room_summary(room_id, state, state_events) do
    hv = history_visibility(state_events)

    %{
      room_id: room_id,
      name: state_event_string(state_events, "m.room.name", "name"),
      topic: state_event_string(state_events, "m.room.topic", "topic"),
      canonical_alias: state_event_string(state_events, "m.room.canonical_alias", "alias"),
      num_joined_members: MapSet.size(state.members),
      world_readable: hv == "world_readable",
      guest_can_join: state_event_string(state_events, "m.room.guest_access", "guest_access") == "can_join",
      join_rule: join_rule(state_events),
      room_type: room_type_from_create(state_events),
      avatar_url: state_event_string(state_events, "m.room.avatar", "url"),
      children_state: stripped_children_state(state_events)
    }
  end

  # join_rule with the Matrix default ("invite") when no m.room.join_rules event.
  defp join_rule(state_events) do
    case state_event_string(state_events, "m.room.join_rules", "join_rule") do
      "" -> "invite"
      jr -> jr
    end
  end

  # history_visibility with the Matrix default ("shared") when unset.
  defp history_visibility(state_events) do
    case state_event_string(state_events, "m.room.history_visibility", "history_visibility") do
      "" -> "shared"
      hv -> hv
    end
  end

  # room_type comes from the m.room.create content `type` ("m.space" for spaces).
  defp room_type_from_create(state_events) do
    case find_state_content(state_events, "m.room.create", "") do
      %{"type" => t} when is_binary(t) and t != "" -> t
      _ -> nil
    end
  end

  # Stripped m.space.child state events (MSC2946 children_state): the room's child
  # edges as {type, state_key, content, sender}. Empty list when none.
  defp stripped_children_state(state_events) do
    state_events
    |> Enum.filter(fn ev -> ev.type == "m.space.child" end)
    |> Enum.map(fn ev ->
      %{
        "type" => ev.type,
        "state_key" => ev.state_key,
        "content" => decode_state_content(ev.content),
        "sender" => ev.sender
      }
    end)
  end

  # Pull a single string field out of the latest state event of `type`/state_key "".
  # find_state_content/3 always returns a map (nil → %{}), so match the field directly.
  defp state_event_string(state_events, type, key) do
    case find_state_content(state_events, type, "")[key] do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  defp find_state_content(state_events, type, state_key) do
    state_events
    |> Enum.find(fn ev -> ev.type == type and ev.state_key == state_key end)
    |> case do
      nil -> %{}
      ev -> decode_state_content(ev.content)
    end
  end

  defp decode_state_content(content) when is_binary(content) and content != "" do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_state_content(_), do: %{}

  # Summary map → Core.HierarchyRoom (children_state serialised to a JSON array).
  defp to_hierarchy_room(summary) do
    %Core.HierarchyRoom{
      room_id: summary.room_id,
      name: summary.name,
      topic: summary.topic,
      canonical_alias: summary.canonical_alias,
      num_joined_members: summary.num_joined_members,
      world_readable: summary.world_readable,
      guest_can_join: summary.guest_can_join,
      join_rule: summary.join_rule,
      room_type: summary.room_type || "",
      avatar_url: summary.avatar_url,
      children_state_json: Jason.encode!(summary.children_state)
    }
  end

  # ─── AC: GetMutualRooms — MSC2666 shared-room intersection ──────────────────
  #
  # Pure direct-DB-read, no Room GenServer/:pg/Horde touch (bugfix-mutual-rooms
  # bug-context.md §8 — only the id-level join fact matters here, not room
  # content, unlike get_space_hierarchy which legitimately needs per-room
  # GenServer state). Calls rooms_db_module().get_rooms_for_user/1 ONCE for the
  # caller and ONCE for `user_id` (same injectable DI seam get_initial_sync
  # already uses), intersects the two id sets, sorts deterministically by
  # room_id (so the offset-window pagination below is stable across calls),
  # then applies an opaque offset-token page over the sorted list, via the
  # SHARED `Nebu.Matrix.PageToken` encode/2 + decode/2 helpers (own "mr1:"
  # prefix, same fail-closed-on-forged-token contract as
  # Nebu.Matrix.SpaceHierarchy's "h1:" hierarchy cursor — both call sites need
  # an opaque offset-pagination token with the same fail-closed-on-forged-
  # token contract, so the codec lives in one shared module instead of being
  # duplicated). A forged/
  # malformed `from` token raises Nebu.Matrix.Error(invalid_argument), caught
  # by the SAME call_core/map_error path protected.ex already uses for
  # get_space_hierarchy's own `from` token → 400 M_INVALID_PARAM, no bespoke
  # error plumbing needed.
  #
  # `user_id` that is syntactically valid but does not resolve to a real/known
  # user is NOT special-cased: get_rooms_for_user/1 naturally returns
  # `{:ok, []}` for such an id, so the intersection is empty and the response
  # is a plain `{count: 0, joined: []}` — never 404 (MSC2666's own
  # anti-user-enumeration rule).
  #
  # Page size is test-overridable via `Application.put_env(:event_dispatcher,
  # :mutual_rooms_page_size, n)` (mirrors this module's own
  # `:event_dispatcher`-namespaced config convention), clamped to a minimum of
  # 1, so a misconfigured 0/negative value can never reach the pagination
  # windowing logic, falling back to a real default when unset.
  # `opts[:unpaginated]` (default `false`) exists because the unstable
  # MSC2666 alias route (protected.ex) needs a complete, untruncated response:
  # the historical/unstable endpoint never paginated, so when `true` this
  # forces offset 0
  # (the caller already passes `from_token: nil` in that case — see
  # protected.ex's do_mutual_rooms/2) and an effectively-unlimited page size
  # (the full sorted intersection length itself), guaranteeing `joined` is
  # always complete and `next_batch` is always `nil` — without touching the
  # stable v1 route's own paginated call (which keeps passing `unpaginated:
  # false`/omitted, i.e. the original behavior, unchanged).
  def get_mutual_rooms(caller_id, user_id, from_token, opts \\ []) do
    unpaginated? = Keyword.get(opts, :unpaginated, false)

    with {:ok, decoded_offset} <- decode_mutual_rooms_token(from_token) do
      # The unpaginated alias always starts from the beginning of the sorted
      # intersection, regardless of what offset a caller's `from_token` decoded
      # to — this is enforced here rather than relied upon via caller
      # convention, since `unpaginated?` and `from_token` are independent
      # arguments to this public function.
      offset = if unpaginated?, do: 0, else: decoded_offset

      caller_rooms = mutual_rooms_id_set!(caller_id)
      target_rooms = mutual_rooms_id_set!(user_id)

      shared = caller_rooms |> MapSet.intersection(target_rooms) |> Enum.sort()
      total = length(shared)
      limit = if unpaginated?, do: total, else: mutual_rooms_page_size()

      page = shared |> Enum.drop(offset) |> Enum.take(limit)
      next_offset = offset + length(page)

      next_batch =
        if not unpaginated? and next_offset < total,
          do: encode_mutual_rooms_token(next_offset),
          else: nil

      %{count: total, joined: page, next_batch: next_batch}
    else
      {:error, :invalid_token} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.invalid_argument(),
          message: "invalid pagination token"
    end
  end

  # Wrapped in try/catch (not just a case on {:ok,_}/{:error,_}): a pure-unit
  # test run with no live Postgres has no Nebu.Repo process at all (AC10's
  # rate-limit probe runs requests through the FULL handler before the
  # limiter trips — it is not exempt from reaching this call), and
  # Ecto.Adapters.SQL.query/3 against an unstarted repo RAISES ("could not
  # lookup Ecto repo …") rather than returning an {:error, reason} tuple.
  # Converting that into the same 503 M_UNAVAILABLE path as a genuine DB
  # error keeps such a request from crashing the caller instead of cleanly
  # failing closed.
  defp mutual_rooms_id_set!(user_id) do
    result =
      try do
        rooms_db_module().get_rooms_for_user(user_id)
      rescue
        e -> {:error, e}
      catch
        :exit, reason -> {:error, reason}
      end

    case result do
      {:ok, ids} ->
        MapSet.new(ids)

      {:error, reason} ->
        Logger.warning(
          "mutual_rooms: get_rooms_for_user failed for #{user_id}: #{inspect(reason)}"
        )

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.unavailable(),
          message: "database unavailable: #{inspect(reason)}"
    end
  end

  defp mutual_rooms_page_size do
    max(Application.get_env(:event_dispatcher, :mutual_rooms_page_size, 50), 1)
  end

  @mutual_rooms_token_prefix "mr1:"

  defp encode_mutual_rooms_token(offset) when is_integer(offset) and offset >= 0 do
    Nebu.Matrix.PageToken.encode(@mutual_rooms_token_prefix, offset)
  end

  defp decode_mutual_rooms_token(nil), do: {:ok, 0}
  defp decode_mutual_rooms_token(""), do: {:ok, 0}

  defp decode_mutual_rooms_token(token) when is_binary(token) do
    Nebu.Matrix.PageToken.decode(@mutual_rooms_token_prefix, token)
  end

  defp decode_mutual_rooms_token(_), do: {:error, :invalid_token}

  # ─── GetInitialSync / GetSyncDelta — /sync partitioned by membership (story sync-membership-partition) ──────────────────
  #
  # ONE builder (`sync_partition/1`, rule table of the story) classifies every room the user has a membership row for as
  # `:join` | `:invite` | `:leave` | `:none`; the initial sync, the incremental sync and the long-poll wake-up rebuild all go
  # through it, so a room is in at most ONE section and a room the user is not in never delivers its events:
  #
  #   class   initial sync                              incremental sync
  #   join    current state + the last 20 events        `fetch_delta_rooms/5`: the events after the device's cursor
  #   invite  rooms.invite (stripped invite_state)      only a NEW invitation (by position and class), D4 / D5
  #   leave   never (no include_leave support)          only a NEW leave: the leave window, nothing after the leave, D6
  #   none    nothing                                   nothing (forgotten, ignored inviter, left before the last sync, ...)
  #
  # Story sync-stream-position: "new" is decided per room against the device's CURSOR row (`sync_room_cursors`: the room position
  # the device was synced to and the room's class then), never by a timestamp; the since token is an opaque nonce of the row.
  #
  # The class is decided by the membership ROW for `join` (the member set /messages and /send authorise against), and the
  # latest `m.room.member` event only DEMOTES a joined row to `leave` (a `ban`): the classification can only remove delivery
  # relative to the row, never add it (D1). Every read fails closed (D10): see `partition_read!/2`.
  #
  # Flow of get_initial_sync/2:
  #   1. sync_partition/1: candidates (rows), latest member events, forgotten rooms, ignored inviters.
  #   2. ONE head statement (story sync-stream-position, D12): the committed position of every partition room.
  #   3. For every join room: state + the last <=20 events up to that head (reversed: DB returns newest first, Matrix expects
  #      oldest first).
  #   4. For every invite room: the stripped invite_state (build_invite_rooms/2).
  #   5. Generate the opaque since_token and persist it ONCE under the request's key (story sync-token-per-device, D1 / D4:
  #      `(user, device)` for a device-bound request, the per-user '' row otherwise), together with one cursor row per partition
  #      room at its head (D12), in ONE transaction.
  #   6. Return %Core.GetInitialSyncResponse{}.

  def get_initial_sync(request, stream), do: with_degraded_rooms_report(fn -> initial_sync(request, stream) end)

  defp initial_sync(request, _stream) do
    user_id = request.user_id
    device_id = request.device_id

    delivery = consistent_delivery(user_id, nil, &initial_delivery(&1, user_id, device_id))

    # informational only (D6): the newest delivered event (join timelines and the event-backed invitations), never read back
    last_event_id = newest_event_id(timeline_event_pairs(delivery.rooms) ++ invite_event_pairs(delivery.invite_entries), nil)
    since_token = new_since_token()

    # D12: the device's cursor rows become one row per partition room at the head read BEFORE its page was fetched (an event
    # committed after that read has a higher position and comes with the next delta: no loss, no duplicate). A joined room whose
    # fetch was dropped (killed after 10 s, a room process that cannot start: not in `delivery.rooms`) gets NO row (code review
    # cycle 0, MINOR-1): the next delta reads it without a base, as a newly joined room (its newest 20 and all its room account
    # data), instead of only the events after a head the client never received.
    delivered = MapSet.new(delivery.rooms, & &1.room_id)

    rows =
      for %{class: class, room_id: room_id} = entry <- delivery.partition,
          class != :none,
          class != :join or MapSet.member?(delivered, room_id),
          %{head: head} <- [delivery.heads[room_id]] do
        %{room_id: room_id, pos: head, class: Atom.to_string(class), invite_marker: invite_marker(entry), base: nil}
      end

    persist_position!(user_id, device_id, %{
      mode: :initial,
      new_token: since_token,
      last_event_id: last_event_id,
      base_token: nil,
      rows: rows,
      keep: Enum.map(rows, & &1.room_id)
    })

    %Core.GetInitialSyncResponse{
      since_token: since_token,
      rooms: delivery.rooms,
      join_room_ids: delivery.join_room_ids,
      invite_rooms: delivery.invite_rooms,
      leave_rooms: []
    }
  end

  # What an initial sync delivers for one partition: every join room (state + the last 20 events up to its head), every pending
  # invitation. The heads (and the partition) are kept for the cursor rows of the persist.
  defp initial_delivery(partition, user_id, device_id) do
    join_room_ids = partition_room_ids(partition, :join)
    invite_entries = partition_entries(partition, :invite)
    heads = room_heads!(partition, user_id, device_id)
    rooms = initial_join_rooms(join_room_ids, user_id, heads)

    %{
      partition: partition,
      heads: heads,
      join_room_ids: join_room_ids,
      rooms: rooms,
      invite_entries: invite_entries,
      invite_rooms: build_invite_rooms(invite_entries, user_id),
      moves_cursors?: rooms != [] or invite_entries != []
    }
  end

  # Kassandra L-1 / N-1 (review cycles 1 and 2): the partition is read BEFORE the join rooms are fetched, and the fetch can take
  # hundreds of milliseconds. A user who is kicked or banned in that gap would get the leave event AND a later message in
  # rooms.join (the security reason, unchanged). Story sync-stream-position: the former second reason, a GLOBAL anchor that passes
  # an undelivered leave, is moot (each room has its own cursor, a leave is new against it), but a cursor that moves past a
  # demotion is still never written without the check. So whenever the delivery would deliver a join room or move a cursor, the
  # partition is read AGAIN and compared with the WHOLE join class of the build (not only with the delivered rooms: a room fetched
  # without news can be demoted just as well): if any room left the join class, the delivery is rebuilt from the fresh partition,
  # in which that room is a NEW leave of this very sync. After `@consistency_rebuilds` rebuilds (a membership that keeps changing
  # under the sync) the sync is `unavailable` (503, no token persisted, the client retries with the same token): never a silent
  # drop. An event is only ever delivered after the re-read confirmed the membership. Costs the two partition statements once more, only when something is delivered. `build`
  # answers a map with `:rooms`, `:join_room_ids` and `:moves_cursors?`.
  @consistency_rebuilds 2

  defp consistent_delivery(user_id, partition, build, rebuilds_left \\ @consistency_rebuilds) do
    partition = partition || sync_partition(user_id)
    delivery = build.(partition)

    if delivery.rooms == [] and not delivery.moves_cursors? do
      delivery
    else
      fresh = sync_partition(user_id)
      demoted = delivery.join_room_ids -- partition_room_ids(fresh, :join)

      cond do
        demoted == [] ->
          delivery

        rebuilds_left > 0 ->
          consistent_delivery(user_id, fresh, build, rebuilds_left - 1)

        true ->
          Logger.error("sync: #{length(demoted)} joined room(s) were demoted during the fetch again and again, the sync is unavailable")

          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.unavailable(),
            message: "sync: the membership state keeps changing"
      end
    end
  end

  defp initial_join_rooms(room_ids, user_id, heads) do
    # Fetch all rooms concurrently — wall-clock is bounded by the slowest single
    # room rather than the sum of all rooms. max_concurrency: 5 caps concurrent
    # DB checkouts below the pool size (each room task runs its statements one after
    # the other, so at most 5 checkouts at a time; per room: the visible page, the
    # predecessor / redaction batches and, per message, one thread-child count plus
    # one visible-children read only for a root that has children). on_timeout:
    # :kill_task drops slow rooms; they re-appear on the next incremental sync (the
    # statement of a killed task is not cancelled server-side: follow-up `gk`).
    Task.async_stream(
      room_ids,
      fn room_id ->
        try do
          state = room_registry_module().get_state(room_id)
          state_events = build_state_events(state, room_id, true, member_slice: :events, viewer: user_id)

          # story history-visibility-enforcement (D6): the newest 20 events the syncing user may see, up to the head (D12)
          {events, _next_batch, prev_batch} = visible_page!(room_id, user_id, "b", 20, "", head: head_of(heads, room_id))

          raw_tl_events =
            events
            |> Enum.reverse()
            |> event_maps_to_core_events(user_id)

          timeline_events =
            raw_tl_events
            |> attach_thread_aggregations(room_id, user_id)

          limited = length(events) >= 20
          deduped_state = dedup_member_state_events(state_events, timeline_events)

          sync_room =
            %Core.SyncRoom{
              room_id: room_id,
              state_events: deduped_state,
              timeline_events: timeline_events,
              limited: limited,
              prev_batch: prev_batch
            }
            |> attach_heroes(user_id, deduped_state)

          [sync_room]
        rescue
          # story state-writer-redaction (D6, AC5 (g)): a failing prune lookup raises inside this task; it is handed back and
          # re-raised in the caller (a handled 500), never a crash of the linked caller
          e in Nebu.Matrix.Error -> {:refused, e}
        catch
          # Room GenServer not running (e.g. after core restart). Start it on demand —
          # Room.init/1 reloads all state from DB, so this is always safe.
          :exit, {:noproc, _} ->
            _ = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
            try do
              state      = room_registry_module().get_state(room_id)
              state_evs  = build_state_events(state, room_id, true, member_slice: :events, viewer: user_id)
              {evs, _next_batch, prev_b} = visible_page!(room_id, user_id, "b", 20, "", head: head_of(heads, room_id))
              raw_tl_evs = evs |> Enum.reverse() |> event_maps_to_core_events(user_id)

              tl_evs =
                raw_tl_evs
                |> attach_thread_aggregations(room_id, user_id)

              deduped = dedup_member_state_events(state_evs, tl_evs)
              sync_room =
                %Core.SyncRoom{
                  room_id:         room_id,
                  state_events:    deduped,
                  timeline_events: tl_evs,
                  limited:         length(evs) >= 20,
                  prev_batch:      prev_b
                }
                |> attach_heroes(user_id, deduped)
              [sync_room]
            rescue
              e in Nebu.Matrix.Error -> {:refused, e}
            catch
              :exit, _ -> []
            end
        end
      end,
      max_concurrency: 5,
      timeout: 10_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {:refused, error}} ->
        raise error

      {:ok, rooms} ->
        rooms

      {:exit, reason} ->
        require Logger
        Logger.warning("[get_initial_sync] room fetch timed out (10s) for user #{user_id}: #{inspect(reason)}")
        []
    end)
  end

  # The core since token (story sync-stream-position, D6): `s2_` + base64url (no padding, never a `.`) of 16 random bytes. A
  # constant-size nonce that names nothing (no user id, no event id, no position): what the device was sent lives in its cursor
  # rows, the token only selects the row's current or previous generation.
  @since_token_prefix "s2_"
  defp new_since_token, do: @since_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  defp head_of(heads, room_id) do
    case heads do
      %{^room_id => %{head: head}} -> head
      _ -> nil
    end
  end

  # The event with the newest `origin_server_ts` over `{origin_server_ts, event_id}` pairs; `fallback` when there is none.
  defp newest_event_id(pairs, fallback) do
    case Enum.max_by(pairs, &elem(&1, 0), fn -> nil end) do
      nil -> fallback
      {_origin_ts, event_id} -> event_id
    end
  end

  # `{origin_server_ts, event_id}` of the delivered events: they only feed the informational `last_event_id` of the token row (story
  # sync-stream-position D6; nothing reads it back).
  defp timeline_event_pairs(rooms) do
    Enum.flat_map(rooms, fn room -> Enum.map(room.timeline_events, &{&1.origin_ts, &1.event_id}) end)
  end

  # Only an event-backed invitation has an event (a row-only invitation has none, D5).
  defp invite_event_pairs(invite_entries) do
    for %{latest: %{membership: "invite"} = latest} <- invite_entries, do: {latest.origin_server_ts, latest.event_id}
  end

  # ─── the partition (D1, rule table) ─────────────────────────────────────────────────────────────────────────────────────

  # Three statements regardless of the number of rooms (D2): the candidate rows, the two latest member events of every
  # candidate room, and (only with a pending invitation) the ignore list; plus the forgotten set (existing read).
  #
  # Returns one entry per candidate room: `%{room_id, class, latest, previous, invitation, inviter, left_at, joined_at}` where `latest` /
  # `previous` are the newest / second newest member event of the user (L and P of the story; nil when absent), `invitation` the
  # pending `room_invitations` candidate (nil when there is none), `inviter` the user an invitation counts as coming from and
  # `left_at` / `joined_at` the end / start of the membership as the ROW knows it (nil while active / when the module does not tell).
  defp sync_partition(user_id) do
    candidates = partition_read!(:membership_candidates, [user_id])
    forgotten = forgotten_room_ids(user_id)

    room_ids = candidates |> Enum.map(& &1.room_id) |> Enum.uniq()
    rows_by_room = Enum.group_by(candidates, & &1.room_id)
    member_events = if room_ids == [], do: %{}, else: partition_read!(:latest_member_events, [room_ids, user_id])

    ignored =
      if Enum.any?(candidates, &(&1.kind == :invitation and &1.pending)),
        do: ignored_inviters(user_id),
        else: MapSet.new()

    Enum.map(room_ids, fn room_id ->
      classify_room(room_id, Map.fetch!(rows_by_room, room_id), Map.get(member_events, room_id, []), forgotten, ignored)
    end)
  end

  # The rule table, first match wins:
  #   1. forgotten and not an active member                                    -> none
  #   2. the latest member event is a `ban`                                    -> leave (whatever the rows say)
  #   3. an active member row                                                  -> join (the row decides)
  #   4. a pending invitation that was NOT taken back                          -> invite (an ignored inviter: none, D8)
  #   5. a left / rejected / taken-back row and the latest event is leave|ban  -> leave
  #   6. anything else (a left row whose leave event was never written, `knock`) -> none
  #
  # A TAKEN-BACK invitation (D13) is a pending row behind a `leave` event that is at least as new as `invited_at`: a decline,
  # kick or removal whose row reject failed (best effort in the writers). `>=`: a tie counts as taken back (most restrictive).
  defp classify_room(room_id, rows, member_events, forgotten, ignored) do
    member_row = Enum.find(rows, &(&1.kind == :member))
    invitation = Enum.find(rows, &(&1.kind == :invitation))
    {latest, previous} = latest_and_previous(member_events)
    latest_membership = latest && latest.membership

    active? = member_row != nil and member_row.active
    pending? = invitation != nil and invitation.pending
    ended? = (member_row != nil and not member_row.active) or (invitation != nil and not invitation.pending)
    taken_back? = pending? and latest_membership == "leave" and latest.origin_server_ts >= invitation.invited_at

    # the ignore list judges the inviter of the invitation the client would see: the author of the invite EVENT when there is
    # one (it can differ from the row after a re-invite by another user), else the row's inviter
    inviter =
      cond do
        latest_membership == "invite" -> latest.sender
        invitation != nil -> invitation.inviter_id
        true -> nil
      end

    class =
      cond do
        MapSet.member?(forgotten, room_id) and not active? -> :none
        latest_membership == "ban" -> :leave
        active? -> :join
        pending? and not taken_back? -> if MapSet.member?(ignored, inviter), do: :none, else: :invite
        (ended? or pending?) and latest_membership in ["leave", "ban"] -> :leave
        true -> :none
      end

    if class == :none and ended? and latest_membership not in ["leave", "ban"] and not MapSet.member?(forgotten, room_id) do
      Logger.debug("sync: room #{room_id} has an ended membership row but no leave event, it is not delivered")
    end

    left_at = member_row && Map.get(member_row, :left_at)
    joined_at = member_row && Map.get(member_row, :joined_at)

    %{
      room_id: room_id,
      class: class,
      latest: latest,
      previous: previous,
      invitation: invitation,
      inviter: inviter,
      left_at: left_at,
      joined_at: joined_at
    }
  end

  defp latest_and_previous([latest, previous | _]), do: {latest, previous}
  defp latest_and_previous([latest]), do: {latest, nil}
  defp latest_and_previous([]), do: {nil, nil}

  defp partition_entries(partition, class), do: Enum.filter(partition, &(&1.class == class))
  defp partition_room_ids(partition, class), do: for(%{class: ^class, room_id: room_id} <- partition, do: room_id)

  # The DB reads of the partition (D2, D2a) are reached through `rooms_db_module()` and are not `DBBehaviour` callbacks: a
  # module that does not export one of them, an error tuple and an exception are all the same answer: 503 M_UNAVAILABLE, no
  # token persisted. NEVER a partial classification (a missing ban would deliver a banned user's room) and never "no
  # memberships" (D10). Logs carry the read name and the error class only.
  defp partition_read!(fun, args) do
    mod = rooms_db_module()

    result =
      if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
        try do
          apply(mod, fun, args)
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      else
        {:error, :not_exported}
      end

    case result do
      {:ok, value} ->
        value

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("sync: the membership read #{fun} failed (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.unavailable(),
          message: "sync: the membership state is unavailable"
    end
  end

  # Story sync-stream-position (D4 / D12): ONE statement for the committed head and the device's cursor row of every partition
  # room (`Room.DB.room_heads/3`, a partition read: a module without it, an error or an exception is the 503). The cursor is the
  # one of THIS request's key (the authenticated device, '' for a device-less request), never of request input. No partition
  # room, no statement.
  defp room_heads!(partition, user_id, device_id) do
    case for(%{class: class, room_id: room_id} <- partition, class != :none, do: room_id) do
      [] -> %{}
      room_ids -> partition_read!(:room_heads, [room_ids, user_id, device_id])
    end
  end

  # D8: the users in `m.ignored_user_list` (the KEYS of `content.ignored_users`). It only ever SUPPRESSES an invitation, it
  # never grants anything, so it fails OPEN: an absent, unreadable (the store answers `:error` for both, also without a running
  # Repo: the Repo-less unit job), malformed or non-object list suppresses nothing. Read only for the syncing user, only when
  # there is a pending invitation. Logs never carry the list.
  defp ignored_inviters(user_id) do
    case Nebu.Matrix.AccountDataStore.get(user_id, "m.ignored_user_list") do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"ignored_users" => %{} = ignored}} ->
            ignored |> Map.keys() |> MapSet.new()

          _ ->
            Logger.debug("sync: m.ignored_user_list is malformed, no invitation is suppressed")
            MapSet.new()
        end

      :error ->
        MapSet.new()
    end
  end

  # ─── delivery of the invite / leave classes (D4, D5, D6) ───────────────────────────────────────────────────────────────

  # Story sync-stream-position (D9): an invitation or a leave is NEW against the device's base row of the room (`nil`: the room
  # entered the partition since this device's last sync), by position and class, never by a clock. An invitation is new without
  # a base, after another class, when its invite EVENT is above the base position (a re-invite after a decline), or, for a
  # ROW-ONLY invitation (upgrade, legacy: no event), when its `invited_at` differs from the marker the device was sent (an exact
  # equality on the row's own value): each is delivered exactly once. An invite event without a position (stored before
  # migration 000053) is only new without an invite base.
  defp invite_new?(_entry, nil), do: true
  defp invite_new?(_entry, %{class: class}) when class != "invite", do: true
  defp invite_new?(%{latest: %{membership: "invite", room_pos: pos}}, base) when is_integer(pos), do: pos > base.pos
  defp invite_new?(%{latest: %{membership: "invite"}}, _base), do: false
  defp invite_new?(%{invitation: %{invited_at: invited_at}}, base), do: invited_at != base.invite_marker
  defp invite_new?(_entry, _base), do: false

  # A leave is new when its event L has a position and the base is absent, of another class or below L. A legacy L (no position)
  # predates every cursor and is never new.
  defp leave_new?(%{latest: %{room_pos: pos}}, nil) when is_integer(pos), do: true
  defp leave_new?(%{latest: %{room_pos: pos}}, base) when is_integer(pos), do: base.class != "leave" or pos > base.pos
  defp leave_new?(_entry, _base), do: false

  # the marker of a delivered ROW-ONLY invitation (its `invited_at`); an event-backed invitation and the other classes have none
  defp invite_marker(%{class: :invite, latest: %{membership: "invite"}}), do: nil
  defp invite_marker(%{class: :invite, invitation: %{invited_at: invited_at}}), do: invited_at
  defp invite_marker(_entry), do: nil

  # rooms.invite entries (D4): ONLY stripped state events (exactly type, state_key, sender, content), in this order: the
  # `m.room.create` (synthesized for a legacy room: the spec requires it since v1.16), name / avatar / topic / canonical_alias /
  # join_rules / encryption as they are now, the INVITER's member event, then the invitee's OWN member event (the invite
  # event with its real sender and content incl. `is_direct`; synthesized for a row-only invitation). Nothing else: no
  # history, no power levels, no member list, no heroes.
  # byte budget constants of the rooms.invite section (see `limit_invite_state/3` below)
  @invite_event_max_bytes 65_536
  @invite_state_budget_bytes 8 * 1024 * 1024
  @invite_optional_drop_order ~w(m.room.topic m.room.avatar m.room.canonical_alias m.room.encryption m.room.join_rules m.room.name)

  defp build_invite_rooms([], _user_id), do: []

  defp build_invite_rooms(entries, user_id) do
    stripped_by_room = partition_read!(:invite_state_events, [Enum.map(entries, & &1.room_id)])
    inviter_events = inviter_member_events(entries)

    entries
    |> Enum.map(fn entry ->
      stripped = Map.get(stripped_by_room, entry.room_id, [])
      {create, others} = Enum.split_with(stripped, &(&1["type"] == "m.room.create"))

      events =
        [List.first(create) || synthesized_create_event(entry)] ++
          others ++ inviter_member_event(inviter_events, entry) ++ [own_invite_event(entry, user_id)]

      %Core.SyncInviteRoom{
        room_id: entry.room_id,
        invite_state:
          Enum.map(events, fn event ->
            %Core.StrippedStateEvent{
              type: event["type"],
              state_key: event["state_key"],
              sender: event["sender"],
              content: stripped_content(event)
            }
          end)
      }
    end)
    |> limit_invite_state()
  end

  # The encoded content of a stripped event. An `m.room.create` above 64 KiB (a row written before story event-size-limit through
  # `creation_content`, then bounded only by the 1 MB body; since that story createRoom refuses such an event, so this reduction is
  # defence in depth for legacy rows) is reduced to the keys the spec defines for it (creator, room_version, type, predecessor): the
  # invitation, and with it the room type a client needs to render it, stays; the junk does not travel into the victim's sync
  # (delta gate L-1). Every other event keeps its content (the optional ones are handled by `limit_invite_state/3`).
  defp stripped_content(%{"type" => "m.room.create", "content" => content}) when is_map(content) do
    encoded = Jason.encode!(content)

    if byte_size(encoded) > @invite_event_max_bytes,
      do: content |> Map.take(~w(creator room_version type predecessor)) |> Jason.encode!(),
      else: encoded
  end

  defp stripped_content(event), do: Jason.encode!(event["content"])

  # Byte budget of the rooms.invite section of ONE response (story rate-limits-join-invite-create-room, review cycle 1, Kassandra
  # M-2): the count of invitations is capped (100 per invitee), but the name / topic / avatar / join rules / alias / encryption
  # content of a room was attacker-written and bounded only by the 1 MB request body, so one invitation could carry megabytes into
  # every initial sync of the victim. Since story event-size-limit every NEW event is at most 65 536 bytes (the write sites refuse a
  # larger one), so this budget is defence in depth for rows written before that story. Only OPTIONAL stripped events are dropped,
  # never an invitation and never the `m.room.create` (above 64 KiB it is reduced to its spec keys, `stripped_content/1`) or a member
  # event (they carry the invitation itself; their content stays as written, defence in depth for legacy rows only):
  #   1. an optional event whose content exceeds `max_event_bytes` (64 KiB) is dropped;
  #   2. while the total of all invite_state contents of the response exceeds `budget` (8 MiB), the optional events of one type at a
  #      time are dropped, largest first, in the order topic, avatar, canonical alias, encryption, join rules, name.
  # Logs the number of dropped events only (no ids, no content). Public for the unit test, not part of the API.

  @doc false
  @spec limit_invite_state([struct()], pos_integer(), pos_integer()) :: [struct()]
  def limit_invite_state(rooms, max_event_bytes \\ @invite_event_max_bytes, budget \\ @invite_state_budget_bytes) do
    droppable? = fn event -> event.type in @invite_optional_drop_order end
    size = fn event -> byte_size(event.content) end
    original = rooms

    rooms = Enum.map(rooms, fn room -> %{room | invite_state: Enum.reject(room.invite_state, &(droppable?.(&1) and size.(&1) > max_event_bytes))} end)
    total = rooms |> Enum.flat_map(& &1.invite_state) |> Enum.map(size) |> Enum.sum()

    {rooms, _total} =
      Enum.reduce_while(@invite_optional_drop_order, {rooms, total}, fn type, {rooms, total} ->
        if total <= budget do
          {:halt, {rooms, total}}
        else
          {:cont, drop_largest_of_type(rooms, type, total, budget)}
        end
      end)

    dropped = count_events(original) - count_events(rooms)
    if dropped > 0, do: Logger.warning("sync: the rooms.invite byte budget dropped #{dropped} optional stripped state event(s)")
    rooms
  end

  defp count_events(rooms), do: rooms |> Enum.map(&length(&1.invite_state)) |> Enum.sum()

  defp drop_largest_of_type(rooms, type, total, budget) do
    victims =
      for {room, room_index} <- Enum.with_index(rooms),
          {event, event_index} <- Enum.with_index(room.invite_state),
          event.type == type,
          do: {byte_size(event.content), room_index, event_index}

    {drop, total} =
      victims
      |> Enum.sort(:desc)
      |> Enum.reduce_while({MapSet.new(), total}, fn {bytes, room_index, event_index}, {drop, total} ->
        if total <= budget, do: {:halt, {drop, total}}, else: {:cont, {MapSet.put(drop, {room_index, event_index}), total - bytes}}
      end)

    rooms =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, room_index} ->
        kept = for {event, event_index} <- Enum.with_index(room.invite_state), not MapSet.member?(drop, {room_index, event_index}), do: event
        %{room | invite_state: kept}
      end)

    {rooms, total}
  end

  # The same fallback `build_state_events/3` uses for a room created before the create event was persisted.
  defp synthesized_create_event(entry) do
    creator =
      case messages_db_module().get_room_creator(entry.room_id) do
        {:ok, creator} -> creator
        _ -> entry.inviter || ""
      end

    %{
      "type" => "m.room.create",
      "state_key" => "",
      "sender" => creator,
      "content" => %{"creator" => creator, "room_version" => Nebu.Matrix.RoomVersions.default()}
    }
  end

  # The invitee's own member event: the invite event when the invitation has one, else synthesized from the row.
  defp own_invite_event(%{latest: %{membership: "invite"} = latest}, user_id) do
    %{"type" => "m.room.member", "state_key" => user_id, "sender" => latest.sender, "content" => latest.content}
  end

  defp own_invite_event(entry, user_id) do
    %{"type" => "m.room.member", "state_key" => user_id, "sender" => entry.inviter, "content" => %{"membership" => "invite"}}
  end

  # The inviters' own member events as `%{{room_id, inviter} => event}`. ONE batched statement for all (room, inviter) pairs
  # (`Room.DB.inviter_member_events/1`, review cycle 1 / Kassandra L-3: no statement per distinct inviter, which invitation spam
  # would turn into an N+1 of the initial sync). A rooms module without the batched read (the unit fakes) is served per inviter
  # by the pinned `latest_member_events/2`.
  defp inviter_member_events(entries) do
    pairs = for %{inviter: inviter, room_id: room_id} <- entries, is_binary(inviter), uniq: true, do: {room_id, inviter}
    mod = rooms_db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :inviter_member_events, 1) do
      partition_read!(:inviter_member_events, [pairs])
    else
      pairs
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
      |> Enum.flat_map(fn {inviter, room_ids} ->
        for {room_id, [event | _]} <- partition_read!(:latest_member_events, [room_ids, inviter]), do: {{room_id, inviter}, event}
      end)
      |> Map.new()
    end
  end

  defp inviter_member_event(inviter_events, %{inviter: inviter, room_id: room_id}) when is_binary(inviter) do
    case Map.get(inviter_events, {room_id, inviter}) do
      nil -> []
      event -> [%{"type" => "m.room.member", "state_key" => inviter, "sender" => event.sender, "content" => event.content}]
    end
  end

  defp inviter_member_event(_inviter_events, _entry), do: []

  # rooms.leave entries (D6): the LEAVE WINDOW. `state` and `account_data` are empty (no current state: it would carry changes
  # made after the leave; room account data is joined-only). The timeline never contains an event at or after the leave other
  # than the leave event itself:
  #   * the user was joined right before the leave (P = join): P (when it is above the device's base position and the window is
  #     not limited), the events strictly between max(base, P) and L by POSITION (story sync-stream-position, D10: the newest 20,
  #     oldest first), then L;
  #   * otherwise (a declined invitation, ban while invited, no join event): [L] only.
  # The member row's clocks restrict the window further (window_after_ts/1, window_before_ts/1): they can only shrink it.
  # `limited` when a 21st event exists (then `prev_batch` is the `/messages` token of the oldest delivered event and P is not
  # prepended: the state changes in the gap are NOT delivered, pre-leave events the user was allowed to see); a non-limited window
  # has no `prev_batch` (the renderer omits the key for ""). No heroes, no thread aggregations. The predecessor keys of the state
  # events are NOT attached here: `attach_leave_predecessors/2` does it with ONE batched lookup for ALL leave rooms (D6).
  defp build_leave_room(%{room_id: room_id, latest: latest, previous: previous} = entry, base, user_id) do
    {events, limited} =
      if previous != nil and previous.membership == "join" do
        base_pos = if base, do: base.pos, else: 0
        join_pos = Map.get(previous, :room_pos) || 0

        newest_first =
          partition_read!(:leave_window_events, [
            room_id,
            max(base_pos, join_pos),
            latest.room_pos,
            window_after_ts(entry),
            window_before_ts(entry)
          ])

        limited = length(newest_first) > 20
        window = newest_first |> Enum.take(20) |> Enum.reverse()
        head = if not limited and join_pos > base_pos, do: [own_member_event_map(room_id, user_id, previous)], else: []

        {head ++ window ++ [own_member_event_map(room_id, user_id, latest)], limited}
      else
        {[own_member_event_map(room_id, user_id, latest)], false}
      end

    %Core.SyncRoom{
      room_id: room_id,
      state_events: [],
      timeline_events: Enum.map(events, &event_map_to_core_event/1),
      limited: limited,
      prev_batch: if(limited, do: Nebu.Matrix.Room.DB.pagination_token(hd(events)), else: "")
    }
  end

  # Story member-event-prev-content (D6): the leave windows get the same three predecessor fields as every other state event
  # (`put_predecessor/2`) through ONE `fetch_state_predecessors/1` statement for ALL new leave entries of the response (the
  # slots of every state event of every leave timeline, across rooms: not one statement per entry). A response without a leave
  # entry, or without a state event in them, runs no statement. A message in the window has no slot and stays untouched.
  defp attach_leave_predecessors([], _viewer), do: []

  defp attach_leave_predecessors(leave_rooms, viewer) do
    slots =
      for room <- leave_rooms,
          event <- room.timeline_events,
          event.is_state_event == true,
          event.event_id != "",
          do: {event.event_id, event.room_id, event.event_type, event.state_key, event.origin_ts}

    predecessors_by_id = fetch_state_predecessors_batch(messages_db_module(), slots, viewer)

    Enum.map(leave_rooms, fn room ->
      %{room | timeline_events: Enum.map(room.timeline_events, &put_predecessor(&1, predecessors_by_id))}
    end)
  end

  # story state-writer-redaction (D6): the leave windows are pruned like every other timeline, through ONE `redactions_for/1`
  # statement for ALL new leave entries of the response (fail-closed as redaction_index/1); no leave entry, no statement
  defp attach_leave_redactions([]), do: []

  defp attach_leave_redactions(leave_rooms) do
    index = redaction_index(for room <- leave_rooms, %{event_id: id} <- room.timeline_events, id != "", do: id)
    Enum.map(leave_rooms, fn room -> %{room | timeline_events: apply_redactions(room.timeline_events, index)} end)
  end

  # The row clocks of the leave window (story sync-stream-position D10: an EXTRA restriction of the position bounds, strict).
  # Upper: the end of the membership as the ROW knows it (review cycle 1, Kassandra M-1). Member event writes are fail-open, so P
  # (the join) can be stale: a self-leave, kick or ban whose event write failed leaves a left row WITHOUT an event, and a later ban
  # would otherwise open a window from the join up to the ban that also covers the time the user was already out of the room.
  # Lower: the start of the membership as the row knows it (review cycle 2, Kassandra I-1): a double fail-open (a re-join whose
  # join event write failed) leaves P older than the real membership. Node clocks: under skew they only shrink the window.
  @no_ts_bound 9_223_372_036_854_775_807
  defp window_after_ts(%{joined_at: joined_at}) when is_integer(joined_at), do: joined_at
  defp window_after_ts(_entry), do: 0

  defp window_before_ts(%{left_at: left_at}) when is_integer(left_at), do: left_at
  defp window_before_ts(_entry), do: @no_ts_bound

  # a member event of the user as a DB event map (the shape `event_map_to_core_event/1` reads)
  defp own_member_event_map(room_id, user_id, event) do
    %{
      "event_id" => event.event_id,
      "room_id" => room_id,
      "sender" => event.sender,
      "event_type" => "m.room.member",
      "content" => event.content,
      "origin_server_ts" => event.origin_server_ts,
      "state_key" => user_id
    }
  end

  # ─── AC: GetSyncDelta — incremental sync with long-polling ─────────────────
  #
  # Flow:
  #   1. Extract user_id, since_token, timeout_ms from request.
  #   2. Clamp timeout_ms to max 25 000 ms (was 30 000; reduced for ALB headroom). `full_state` with a since token returns at
  #      once (D14: the spec ignores `timeout`).
  #   3. Look up the token row via pg_store_module().get_since_token(user_id, device_id) for a device-bound request (story
  #      sync-token-per-device: the route passes the AUTHENTICATED device), get_since_token(user_id) (the '' row) otherwise.
  #      - {:error, :not_found} / a token that is neither the row's current nor its previous `s2_` token / a row of the
  #        timestamp era → fallback to get_initial_sync under the same key, fallback_to_initial: true (a token stored under ''
  #        is never read for a device: one fallback, D3).
  #   4. do_incremental_sync/3 (in a Task): subscribe to :pg, classify the rooms (sync_partition/1), read the heads and the
  #      device's cursors, deliver the join rooms' new events, the NEW invitations and the NEW leaves; return at once when
  #      something ends the wait, else long-poll.
  #   5. Generate the new since_token and persist it with the changed cursor rows (ONE transaction guarded by the base token).
  #   6. Return %Core.GetSyncDeltaResponse{}.

  def get_sync_delta(request, stream), do: with_degraded_rooms_report(fn -> sync_delta(request, stream) end)

  defp sync_delta(request, _stream) do
    user_id = request.user_id
    # proto3 string fields are never nil — no need for `|| ""`
    device_id = request.device_id
    # client_since_token is validated against the stored token after lookup (AC2, Story 9-22).
    client_since_token = request.since_token
    full_state? = request.full_state == true
    timeout_ms = if full_state?, do: 0, else: request.timeout_ms |> max(0) |> min(25_000)

    # Step 3: Read the caller's token row (the current / previous token, its era and generation).
    # Use per-device lookup when device_id is present (Story 9-22).
    lookup_result =
      if device_id != "" do
        pg_store_module().get_since_token(user_id, device_id)
      else
        pg_store_module().get_since_token(user_id)
      end

    case lookup_result do
      {:error, :not_found} ->
        # AC3: No stored token for this (user_id, device_id) → full initial sync.
        # This handles first sync after re-login, unknown device_id, or missing row.
        fallback_to_initial_sync(user_id, device_id)

      {:ok, row} ->
        # AC2 / story sync-stream-position (D6 / D8): the client must echo the row's CURRENT token or the previous generation's
        # (a retry after a lost response). Anything else (a stale or replayed token, another device's or user's token: the row
        # is the caller's own, a forged token, a row or token of the timestamp era) is an initial-shaped fallback, never read as
        # positions.
        case base_generation(row, client_since_token) do
          :none ->
            fallback_to_initial_sync(user_id, device_id)

          base ->
            ctx = %{
              user_id: user_id,
              device_id: device_id,
              base: base,
              base_token: client_since_token,
              generation: Map.get(row, :generation, 0),
              last_event_id: row.last_event_id
            }

            # Run the incremental sync in a short-lived Task so the Task's process
            # joins and leaves :pg groups. When the Task exits, :pg auto-cleans its
            # membership. This ensures the handler process itself never appears in any
            # room :pg group after get_sync_delta/2 returns.
            #
            # Capture all module-level injectable deps before spawning (they are looked
            # up at call time via Application.get_env, so the Task re-evaluates them in
            # its own context automatically — no capture needed).
            task_timeout = timeout_ms + 10_000

            # An exception, throw or exit inside the Task would be an EXIT of the caller (not a `Nebu.Matrix.Error` that the HTTP
            # layer maps to 503): hand it back and re-raise it HERE (D10). The stacktrace is handed back with every argument list
            # replaced by its arity (a FunctionClauseError would otherwise carry client values into the log).
            task =
              Task.async(fn ->
                try do
                  {:ok, do_incremental_sync(ctx, timeout_ms, full_state?)}
                rescue
                  e -> {:raise, e, strip_stacktrace_args(__STACKTRACE__)}
                catch
                  kind, reason -> {:caught, kind, reason}
                end
              end)

            case Task.await(task, task_timeout) do
              {:ok, response} -> response
              {:raise, e, stacktrace} -> reraise e, stacktrace
              {:caught, :throw, value} -> throw(value)
              {:caught, :exit, reason} -> exit(reason)
            end
        end
    end
  end

  # Which generation of the caller's token row the client's core token names: `:current`, `:previous` (one generation old, D8)
  # or `:none` (fallback). Only a row of the stream era (`stream_version` 1, written by this code) and an `s2_` token qualify: a
  # row or token of the timestamp era is never continued (D6; a row without the field, e.g. an old node's, counts as that era).
  # The comparison is with the row of the AUTHENTICATED key only, so another device's or user's token never matches.
  defp base_generation(%{since_token: current} = row, @since_token_prefix <> _ = client) do
    cond do
      Map.get(row, :stream_version, 0) != 1 -> :none
      client == current -> :current
      is_binary(Map.get(row, :prev_since_token)) and client == row.prev_since_token -> :previous
      true -> :none
    end
  end

  defp base_generation(_row, _client), do: :none

  # An unknown or stale since token: a full initial sync (no rooms.leave: it is an initial sync). Story sync-token-per-device
  # (D4): the initial sync persists the fresh token under THIS request's key (the device, or '' for a device-less request)
  # together with the device's cursor rows (story sync-stream-position, D12), so that is the only write of the request.
  defp fallback_to_initial_sync(user_id, device_id) do
    initial_resp =
      get_initial_sync(%Core.GetInitialSyncRequest{user_id: user_id, device_id: device_id}, %{http_request_headers: %{}})

    %Core.GetSyncDeltaResponse{
      since_token: initial_resp.since_token,
      rooms: initial_resp.rooms,
      fallback_to_initial: true,
      join_room_ids: initial_resp.join_room_ids,
      invite_rooms: initial_resp.invite_rooms,
      leave_rooms: []
    }
  end

  # The ONE write of a /sync request (story sync-stream-position, D7 / D12; under the request's key, story sync-token-per-device
  # D1: `(user, device)` for a device-bound request, the per-user '' row for a device-less one, D2): the token row and the cursor
  # rows in one transaction. `:stale` (a delta whose base token was replaced meanwhile by a concurrent request of the same device,
  # or whose row is gone) wrote nothing: the response is still sent, its token is unknown and the next request falls back (`cj`
  # (b)). A failure is the handled 503 (nothing was written, the client's token stays valid) and never a 200 with a token that
  # was not stored. The log carries the error class only.
  defp persist_position!(user_id, device_id, spec) do
    case pg_store_module().persist_sync_position(user_id, device_id, spec) do
      :ok ->
        :ok

      :stale ->
        Logger.debug("sync: the base token was replaced by a concurrent request of the same device, this response's token is not stored")
        :ok

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("sync: the since token and the room cursors could not be stored (#{db_error_class(reason)})")
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.unavailable(), message: "sync: the sync position could not be stored"
    end
  end

  # Runs the incremental sync logic in a separate (Task) process so that
  # :pg group subscriptions are owned by a process that exits when done.
  # :pg auto-removes dead processes; the explicit leaves below make a failed build leave its groups at once, too.
  #
  # Subscriptions: `user:<id>` (invite / join / leave / account data wake-ups) and `room:<id>` for every JOIN and INVITE room,
  # never for leave / none rooms (their events must not wake the poll). A change between the partition read and the
  # subscription is repaired by the next sync.
  defp do_incremental_sync(%{user_id: user_id, device_id: device_id} = ctx, timeout_ms, full_state?) do
    build = &build_delta(&1, ctx, full_state?)
    user_group = "user:#{user_id}"
    :pg.join(user_group, self())

    delivery =
      try do
        partition = sync_partition(user_id)
        subscribed = for %{class: class, room_id: room_id} <- partition, class in [:join, :invite], do: room_id
        Enum.each(subscribed, &:pg.join("room:#{&1}", self()))

        try do
          first = consistent_delivery(user_id, partition, build)

          if first.ends_wait? or timeout_ms <= 0 do
            first
          else
            case wait_for_wakeup(timeout_ms, MapSet.new(first.join_room_ids), user_id) do
              # memberships may have changed meanwhile (invite -> join, join -> leave): rebuild EVERYTHING from fresh reads
              :wake -> consistent_delivery(user_id, nil, build)
              :timeout -> first
            end
          end
        after
          Enum.each(subscribed, &:pg.leave("room:#{&1}", self()))
        end
      after
        :pg.leave(user_group, self())
      end

    delivered_events = timeline_event_pairs(delivery.rooms) ++ timeline_event_pairs(delivery.leave_rooms) ++ invite_event_pairs(delivery.invite_entries)
    new_since_token = new_since_token()

    # D7: the new generation of the token row and the changed cursor rows, written only while the base token is still the row's
    # current or previous one AND the row is still at the generation this request read (compare-and-set, code review cycle 0
    # MAJOR-1): the cursor rows were interpreted against that generation, so a concurrent request of the same device that
    # committed first makes this one `:stale` (its token unknown, the next request falls back once) instead of writing a token
    # whose cursors the winner advanced past events this response never carried. Story sync-wakeups-cluster-wide (D5) is per room
    # now (D13): an unresolved joined room keeps ITS cursor (`cursor_rows`), every other room advances.
    persist_position!(user_id, device_id, %{
      mode: :delta,
      new_token: new_since_token,
      last_event_id: newest_event_id(delivered_events, ctx.last_event_id),
      base_token: ctx.base_token,
      expected_generation: ctx.generation,
      rows: delivery.cursor_rows,
      keep: delivery.keep
    })

    %Core.GetSyncDeltaResponse{
      since_token: new_since_token,
      rooms: delivery.rooms,
      fallback_to_initial: false,
      join_room_ids: delivery.join_room_ids,
      invite_rooms: delivery.invite_rooms,
      leave_rooms: delivery.leave_rooms,
      newly_joined_room_ids: delivery.newly_joined_room_ids
    }
  end

  # The base of ONE room for this request (D8): the values the device was synced to by the token it presented. For the CURRENT
  # token the row's current values. For the PREVIOUS token (a retry after a lost response) a row written in the generation being
  # replaced (`gen == generation`) answers its previous values (`prev_pos` NULL: the row did not exist then, no base); an older
  # row did not change since and answers its current values. `nil`: no row, the room entered the partition since.
  defp cursor_base(nil, _ctx), do: nil

  defp cursor_base(%{gen: gen} = cursor, %{base: :previous, generation: gen}) do
    if is_nil(cursor.prev_pos),
      do: nil,
      else: %{pos: cursor.prev_pos, class: cursor.prev_class, invite_marker: cursor.prev_invite_marker}
  end

  defp cursor_base(cursor, _ctx), do: %{pos: cursor.pos, class: cursor.class, invite_marker: cursor.invite_marker}

  # D3: a cursor row is written when it is new or its value changes; a retry with the PREVIOUS token (D8 / story D20 (1)) also
  # rewrites every row of the generation being replaced, so its previous values become this request's base (otherwise a second
  # retry with the same token would read that row's lost values as unchanged).
  defp write_cursor?(nil, _value, _ctx), do: true

  defp write_cursor?(stored, value, ctx) do
    (ctx.base == :previous and stored.gen == ctx.generation) or
      {stored.pos, stored.class, stored.invite_marker} != {value.pos, value.class, value.invite_marker}
  end

  # What one build delivers. `ends_wait?`: at least one join room with events, one leave entry or one EVENT-BACKED new
  # invitation (row-only invitations and account-data-only rooms never end a wait by themselves, D5).
  #
  # Story sync-stream-position (D4, D9, D11): ONE statement reads the committed head and the device's cursor row of every partition
  # room; only a joined room whose head is above its base position (0 without a base) is fetched, by the exact range
  # `(base, head]` (the head READ is the upper bound, so the cursor written afterwards is exactly what was considered): the plain
  # position range for a continuously joined room, the segmented range read (story sync-rejoin-range-scan-bound) when the base is an
  # invitation / leave or the viewer's own member event is above the base, the segment-driven page read for an absent base or a gated
  # base 0 (see `delta_events!/5`). A quiet
  # room costs no statement. The cursor value of every partition room after this response (`after_values`): a joined room moves
  # to its head (an unresolved one keeps its base, D13), a NEW invitation or leave moves to the head with its class, anything else
  # keeps its base; a room without a value has no row afterwards (`keep`).
  defp build_delta(partition, ctx, full_state?) do
    user_id = ctx.user_id
    join_room_ids = partition_room_ids(partition, :join)
    heads = room_heads!(partition, user_id, ctx.device_id)
    bases = Map.new(heads, fn {room_id, %{cursor: cursor}} -> {room_id, cursor_base(cursor, ctx)} end)

    # D3 / D-A5: the highest position of the viewer's own member events of a joined room (`latest` and `previous` of the entry: the
    # partition picks them by TIMESTAMP, so under clock skew a member event with a higher position but an older timestamp sits in
    # `previous`; both are read, only integer positions count)
    member_positions =
      for %{class: :join, room_id: room_id} = entry <- partition, into: %{} do
        positions = for event <- [entry.latest, entry.previous], is_map(event), is_integer(Map.get(event, :room_pos)), do: event.room_pos
        {room_id, Enum.max(positions, fn -> nil end)}
      end

    {delivered, unresolved} = fetch_delta_rooms(join_room_ids, heads, bases, user_id, member_positions)
    rooms = if full_state?, do: delivered ++ full_state_rooms(join_room_ids, delivered, user_id), else: delivered

    # a room without a `rooms` row has no position: never new (there is nothing to deliver from it)
    new_invites = for %{class: :invite, room_id: room_id} = entry <- partition, Map.has_key?(heads, room_id), invite_new?(entry, bases[room_id]), do: entry
    new_leaves = for %{class: :leave, room_id: room_id} = entry <- partition, Map.has_key?(heads, room_id), leave_new?(entry, bases[room_id]), do: entry
    new_ids = MapSet.new(new_invites ++ new_leaves, & &1.room_id)

    after_values =
      for %{class: class, room_id: room_id} = entry <- partition, class != :none, %{head: head} <- [heads[room_id]], into: %{} do
        base = bases[room_id]

        value =
          cond do
            class == :join and room_id in unresolved -> base
            class == :join or MapSet.member?(new_ids, room_id) -> %{pos: head, class: Atom.to_string(class), invite_marker: invite_marker(entry)}
            true -> base
          end

        {room_id, value}
      end

    cursor_rows =
      for {room_id, value} <- after_values, value != nil, write_cursor?(heads[room_id].cursor, value, ctx) do
        Map.merge(value, %{room_id: room_id, base: bases[room_id]})
      end

    %{
      join_room_ids: join_room_ids,
      rooms: rooms,
      invite_entries: new_invites,
      invite_rooms: build_invite_rooms(new_invites, user_id),
      leave_rooms:
        new_leaves
        |> Enum.map(&build_leave_room(&1, bases[&1.room_id], user_id))
        |> attach_leave_redactions()
        |> attach_leave_predecessors(user_id),
      # D11: a joined room the device had no JOINED base for (the HTTP layer sends all of its room account data)
      newly_joined_room_ids: for(room_id <- join_room_ids, Map.has_key?(heads, room_id), not match?(%{class: "join"}, bases[room_id]), do: room_id),
      cursor_rows: cursor_rows,
      keep: for({room_id, value} <- after_values, value != nil, do: room_id),
      moves_cursors?: cursor_rows != [] or new_invites != [] or new_leaves != [],
      ends_wait?:
        Enum.any?(rooms, &(&1.timeline_events != [])) or new_leaves != [] or
          Enum.any?(new_invites, &match?(%{latest: %{membership: "invite"}}, &1))
    }
  end

  # D14: `full_state=true` with a since token puts EVERY joined room into rooms.join with its full current state. Rooms that
  # already carry new events (`delivered`) keep their state-minus-timeline shape; the others get an empty timeline and
  # `limited: false`. Never a left / invite / none room (only the join class is passed).
  defp full_state_rooms(join_room_ids, delivered, user_id) do
    present = MapSet.new(delivered, & &1.room_id)

    join_room_ids
    |> Enum.reject(&MapSet.member?(present, &1))
    |> Enum.flat_map(fn room_id ->
      try do
        [full_state_room(room_id, user_id)]
      catch
        # Room GenServer not running (e.g. after core restart): start it on demand, as the initial sync does.
        :exit, {:noproc, _} ->
          _ = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)

          try do
            [full_state_room(room_id, user_id)]
          catch
            :exit, _ -> []
          end
      end
    end)
  end

  defp full_state_room(room_id, user_id) do
    state_events = build_state_events(room_registry_module().get_state(room_id), room_id, true, member_slice: :events, viewer: user_id)

    attach_heroes(
      %Core.SyncRoom{room_id: room_id, state_events: state_events, timeline_events: [], limited: false, prev_batch: ""},
      user_id,
      state_events
    )
  end

  # The long-poll wait. Wakes on: an event of a JOIN room, the user's OWN member event in any subscribed room (a decline from
  # another device, a ban of a pending invitee, a kick), `{:new_invite}`, `{:new_join}`, `{:new_leave}` and
  # `{:account_data_changed}`. Any other `{:new_event}` (a message in an invite room, someone else's member event there, a
  # stale event of a room the user has left) is ignored and the wait goes on with the ORIGINAL timer, so a room the user is
  # merely invited to cannot end the long-poll with an empty answer for every message (Kassandra L-3).
  defp wait_for_wakeup(timeout_ms, join_room_ids, user_id) do
    timer_ref = Process.send_after(self(), :sync_long_poll_timeout, timeout_ms)
    result = wait_loop(join_room_ids, user_id)
    Process.cancel_timer(timer_ref)
    flush_long_poll_timeout()
    result
  end

  defp wait_loop(join_room_ids, user_id) do
    receive do
      {:new_event, event} ->
        if wakes_sync?(event, join_room_ids, user_id), do: :wake, else: wait_loop(join_room_ids, user_id)

      {:new_invite, _room_id} ->
        :wake

      # GAP-JOIN-PUBLIC: without this, join_room broadcasts are missed and the long-poll sleeps until the timeout.
      {:new_join, _room_id} ->
        :wake

      # GAP-LEAVE-UI / GAP-FORGET: leave_room broadcasts to room:<id> and to user:<id>; the leave is delivered in rooms.leave.
      {:new_leave, _room_id} ->
        :wake

      # Room account data changed (room-account-data-and-read-markers, `{_, room_id}`) or GLOBAL account data changed (story
      # sync-token-per-device D11, `{_, nil}`): the HTTP layer re-reads it after this call returns.
      {:account_data_changed, _room_id} ->
        :wake

      :sync_long_poll_timeout ->
        :timeout
    end
  end

  defp wakes_sync?(%{"room_id" => room_id} = event, join_room_ids, user_id) do
    MapSet.member?(join_room_ids, room_id) or
      (event["type"] == "m.room.member" and event["state_key"] == user_id)
  end

  defp wakes_sync?(_event, _join_room_ids, _user_id), do: false

  # Fetch the new events of each joined room by position (story sync-stream-position, D4 / D5): the range `(base, head]` of
  # `heads` / `bases` (`build_delta/3`; no base: from the room's start, as for an initial-sync room); a room whose head is not
  # above its joined base runs no statement. A room with more than 20 new visible events delivers its NEWEST 20 with `limited`
  # and the `/messages` token of the oldest delivered event as `prev_batch` (the client fills the gap backwards; the cursor still
  # reaches the head, so nothing is lost). user_id is passed so attach_thread_aggregations can compute current_user_participated.
  # Story history-visibility-enforcement (D6, D14 (a)): the timeline holds the events the syncing user may see; a failed read is the
  # 503 M_UNAVAILABLE of the whole /sync (no since token persisted, the client retries), never a silently dropped room.
  #
  # Story sync-wakeups-cluster-wide (D5): answers `{rooms, unresolved_room_ids}`. A room WITH events whose process this node's Horde registry
  # does not resolve yet (a cluster-wide wake-up can be faster than the registry replication) is polled every
  # `@room_resolve_poll_ms` until ONE deadline per build (`@room_resolve_ms`, shared by all rooms; a room without events is never
  # polled). An archived room or one without a `rooms` row is dead at once (not polled, not counted). After the bound the room is started
  # once on demand. A room still unresolvable then is not delivered and listed in `unresolved_room_ids` (story sync-stream-position
  # D13: the caller keeps THAT room's cursor, the others advance); no error. Runs in the sync request's own Task (`sync_delta/2`):
  # the sleep blocks nothing shared.
  @room_resolve_ms 1_000
  @room_resolve_poll_ms 50
  @sync_timeline_limit 20
  defp fetch_delta_rooms(room_ids, heads, bases, user_id, member_positions) do
    deadline = System.monotonic_time(:millisecond) + @room_resolve_ms

    {rooms, unresolved} = Enum.flat_map_reduce(room_ids, [], fn room_id, unresolved ->
      case delta_events!(room_id, user_id, heads[room_id], bases[room_id], member_positions[room_id]) do
        {[], _limited} ->
          {[], unresolved}

        {events, limited} ->
          try do
            state = resolve_room_state(room_id, deadline)
            raw_timeline_events = event_maps_to_core_events(events, user_id)
            thread_roots = thread_root_updates(events, room_id, user_id)
            timeline_events = attach_thread_aggregations(raw_timeline_events, room_id, user_id)

            timeline_events = thread_roots ++ timeline_events
            # When limited, the `/messages` token of the oldest delivered event is the backward-pagination cursor (Spec §6.3.3,
            # story sync-stream-position D5): GET /messages?from=<prev_batch>&dir=b returns the gap.
            prev_batch = if limited, do: Nebu.Matrix.Room.DB.pagination_token(hd(events)), else: ""

            # §6.3.3: state.events = room state BEFORE the timeline window. Any
            # {type, state_key} already delivered in the timeline must be excluded
            # from state so the client computes the change (not a no-op delta).
            # We detect state events in the raw batch via Map.has_key?("state_key"),
            # which correctly identifies state events with empty state_key (power_levels,
            # name, join_rules) — event_map_to_core_event cannot distinguish them from messages.
            timeline_state_keys =
              events
              |> Enum.filter(fn ev -> Map.has_key?(ev, "state_key") end)
              |> MapSet.new(fn ev -> {ev["event_type"] || "", ev["state_key"] || ""} end)

            state_events =
              build_state_events(state, room_id, true, viewer: user_id)
              |> Enum.reject(fn ev ->
                MapSet.member?(timeline_state_keys, {ev.type, ev.state_key})
              end)

            deduped_state = dedup_member_state_events(state_events, timeline_events)

            # §11.2.2: heroes/counts are attached only when membership changed
            # (the delta contains m.room.member events). When no memberships changed,
            # the summary is omitted (proto3 zero values) — clients use cached heroes.
            membership_changed =
              Enum.any?(events, fn ev -> Map.get(ev, "event_type") == "m.room.member" end)

            sync_room =
              %Core.SyncRoom{
                room_id: room_id,
                state_events: deduped_state,
                timeline_events: timeline_events,
                limited: limited,
                prev_batch: prev_batch
              }

            sync_room =
              if membership_changed do
                attach_heroes(sync_room, user_id, deduped_state)
              else
                sync_room
              end

            {[sync_room], unresolved}
          catch
            # an archived (upgraded) or vanished room: its process never comes back, dropped as before (its cursor advances)
            :throw, :sync_room_dead ->
              Logger.debug("sync: a joined room with new events is archived or gone, not delivered")
              {[], unresolved}

            :exit, {:noproc, _} ->
              {[], [room_id | unresolved]}
          end
      end
    end)

    # value-free: the count only (no room or user id)
    if unresolved != [], do: Logger.warning("sync: #{length(unresolved)} joined room(s) with new events not resolvable in the room registry within #{@room_resolve_ms} ms or after the start attempt; their cursors are kept")

    {rooms, unresolved}
  end

  # The new events of one joined room up to the head that was read: `{events_oldest_first, limited}`. With a base, the position
  # range above it. Without a base (newly joined, or a retry whose base row did not exist), the room is read as an initial-sync room:
  # the newest 20 visible events up to the head through the SEGMENT-DRIVEN page read (security review cycle 0, MEDIUM-1: a range
  # `(0, head]` filtered row by row would scan the invisible history of a `joined` / `invited` room in full, repeatably through the
  # previous token); `limited` when a further visible event exists. No head (no `rooms` row) or nothing above the base: nothing, and
  # no statement. No statement timeout (as every /sync read, follow-up `gk` (4)).
  #
  # Story sync-rejoin-range-scan-bound (D3 / D-A5): the plain position range walks the positions and meets every hidden row between
  # the base and the head. A hidden stretch is possible when the base is an invitation / leave, or when the viewer's own member event
  # is above the base (`member_pos`: left and re-joined, or a profile change, since the base; `nil` / no position: no change). Such a
  # room is read through the segment-driven, position-bounded range read (its cost no longer depends on the hidden history, also on
  # a replay of the previous token: its base is the previous generation's); every other room keeps the plain range read. Base
  # position 0 has no event to anchor the floor of the segmented read: a gated room is read as an absent base (the newest 20 visible
  # events up to the head, legacy events included; for a `join`-class base 0 that can send up to 20 events the device already had,
  # and `limited` / `prev_batch` can be set: accepted, documented in 06-runtime). A wrong gate choice
  # can only change the cost or the delivery shape, never the visibility: both reads use the same fragment.
  defp delta_events!(_room_id, _viewer, nil, _base, _member_pos), do: {[], false}

  defp delta_events!(_room_id, _viewer, %{head: head}, _base, _member_pos) when head <= 0, do: {[], false}

  defp delta_events!(room_id, viewer, %{head: head}, nil, _member_pos), do: paged_events!(room_id, viewer, head)

  defp delta_events!(room_id, viewer, %{head: head}, %{pos: after_pos} = base, member_pos) do
    gated? = base.class != "join" or (is_integer(member_pos) and member_pos > after_pos)

    cond do
      head <= after_pos -> {[], false}
      gated? and after_pos == 0 -> paged_events!(room_id, viewer, head)
      true -> visible_range!(room_id, viewer, after_pos, head, @sync_timeline_limit, gated?)
    end
  end

  defp paged_events!(room_id, viewer, head) do
    {newest_first, next_batch, _prev_batch} =
      visible_page!(room_id, viewer, "b", @sync_timeline_limit, "", head: head, failure: :unavailable)

    {Enum.reverse(newest_first), next_batch != ""}
  end

  # `phase`: :first (the first ask: a dead room is not polled), :polling, :started (the one on-demand start after the bound is spent)
  defp resolve_room_state(room_id, deadline, phase \\ :first) do
    room_registry_module().get_state(room_id)
  catch
    :exit, {:noproc, _} = reason ->
      cond do
        phase == :first and room_dead?(room_id) ->
          throw(:sync_room_dead)

        phase != :started and System.monotonic_time(:millisecond) < deadline ->
          Process.sleep(@room_resolve_poll_ms)
          resolve_room_state(room_id, deadline, :polling)

        phase != :started ->
          # after the bound Horde's registry has converged: start on demand, as full_state_rooms / the initial sync do
          _ = guarded_status_read(fn -> Nebu.Matrix.Room.RoomSupervisor.start_room(room_id) end)
          resolve_room_state(room_id, deadline, :started)

        true ->
          exit(reason)
      end
  end

  # D5: `archived` (Room.Server.init/1 stops for it) or no `rooms` row. An unreadable status is NOT dead (polled, then unresolved).
  defp room_dead?(room_id) do
    mod = rooms_db_module()

    Code.ensure_loaded?(mod) and function_exported?(mod, :get_room_status, 1) and
      guarded_status_read(fn -> mod.get_room_status(room_id) end) in [{:ok, "archived"}, {:error, :not_found}]
  end

  # Removes m.room.member entries from state_events when the same user already has
  # a m.room.member event in timeline_events. This prevents Element Web from logging
  # "No membership changes detected" — without deduplication, matrix-js-sdk sees the
  # join in state (prev=join) and again in the timeline (new=join), computes no change,
  # and silently skips processing the membership event. With deduplication, the member
  # event is ONLY in the timeline, so the sdk correctly detects: none→join.
  #
  # State events for members NOT in the timeline are kept intact (e.g. for rooms with
  # limited=true where historic joins are outside the timeline window).
  defp dedup_member_state_events(state_events, timeline_events) do
    member_state_keys =
      timeline_events
      |> Enum.filter(fn ev -> ev.event_type == "m.room.member" end)
      |> MapSet.new(fn ev -> ev.state_key end)

    if MapSet.size(member_state_keys) == 0 do
      state_events
    else
      Enum.reject(state_events, fn ev ->
        ev.type == "m.room.member" && MapSet.member?(member_state_keys, ev.state_key)
      end)
    end
  end

  # Flush any stale :sync_long_poll_timeout message left in the mailbox
  # after canceling the timer. This prevents leaking messages into the next
  # receive block.
  defp flush_long_poll_timeout do
    receive do
      :sync_long_poll_timeout -> :ok
    after
      0 -> :ok
    end
  end

  # Build state events for a room: m.room.create + the m.room.member slots (see `member_slice` below)
  # + one m.room.power_levels + one m.room.name (if a name has been stored).
  #
  # Bugfix sync-state-events-missing-fields: every Core.SyncRoomStateEvent built here
  # now carries REAL event_id/origin_server_ts (AC1/AC2), not synthesized placeholders —
  # see Nebu.Matrix.Http.build_joined_rooms/1 (http.ex) for where these flow into
  # /sync's rooms.join.*.state.events JSON.
  #
  # Code-review cycle 1 (MAJOR-3): `fetch_predecessors?` (default `false`)
  # opts IN to the extra batched predecessor lookup (see
  # attach_predecessors_to_state_events/2 below) — it must be `true` ONLY
  # at the call sites that actually read the predecessor keys (`replaces_state`,
  # `prev_content`, `prev_sender`) off the result (get_initial_sync/2's two code
  # paths, full_state_room/2, fetch_delta_rooms/3 and, since story
  # membership-state-model (`fl` (c)), get_room_state/2 for /initialSync). The
  # summary callers (get_room_summary/2, visible_summary_or_forbid!/2, and
  # room_visibility_summary/2 — the latter invoked PER ROOM, uncapped, inside
  # the space-hierarchy BFS traversal) never read the predecessor keys off their
  # result, so they default to `false` and skip the extra query entirely.
  # Story membership-state-model (D3): `opts` `member_slice: :events | :joined` (default `:joined`) selects the member slots (and
  # `read: :sync | :request`, default `:sync`, how an unavailable read is answered, D18, and which predecessor lookup runs): the
  # latest member EVENT of every user read from the database (`:events`: the initial `/sync`, `full_state_room/2`, `/initialSync`)
  # or the synthesized joined slice of the room process (`:joined`: the incremental `/sync` delta, the summary / hierarchy paths).
  defp build_state_events(state, room_id, fetch_predecessors? \\ false, opts \\ []) do
    creator_id =
      case messages_db_module().get_room_creator(room_id) do
        {:ok, id} ->
          id
        _ ->
          # Fallback for rooms created before m.room.create was persisted.
          (state.power_levels || %{})
          |> Map.get("users", %{})
          |> Enum.max_by(fn {_uid, lvl} -> lvl end, fn -> {"", 0} end)
          |> elem(0)
      end

    # MAJOR-2 fix: use the persisted m.room.create content when available so that
    # upgraded rooms return the `predecessor` field rather than a synthesized fallback.
    # Fall back to synthesized content for rooms created before create-event persistence,
    # or when the DB query fails (e.g. in unit tests without a real DB).
    #
    # Bugfix sync-state-events-missing-fields (AC2): the real DB returns a wider
    # {:ok, content, event_id, origin_server_ts} 4-tuple — SAME query, no extra DB
    # round trip (this runs on every /sync, a hot path). The original {:ok,
    # content} 2-tuple is still matched for fakes that predate this widening.
    {create_content, create_event_id, create_ts} =
      case messages_db_module().get_room_create_event(room_id) do
        {:ok, persisted_content, event_id, ts} when is_map(persisted_content) ->
          {persisted_content, event_id, ts}
        {:ok, persisted_content} when is_map(persisted_content) ->
          {persisted_content, "", 0}
        _ ->
          {%{"creator" => creator_id, "room_version" => Nebu.Matrix.RoomVersions.default()}, "", 0}
      end

    create_event = %Core.SyncRoomStateEvent{
      type: "m.room.create",
      state_key: "",
      content: Jason.encode!(create_content),
      sender: creator_id,
      event_id: create_event_id,
      origin_server_ts: create_ts
    }

    member_events =
      case Keyword.get(opts, :member_slice, :joined) do
        :joined -> joined_member_events(state)
        :events -> member_slice_events(room_id, state, [], Keyword.get(opts, :read, :sync))
      end

    # power_levels_event is captured by Room.Server when set_power_levels applies a
    # change (AC2 addendum: that handler now also emits a real backing event) and
    # restored from the DB on every restart. nil (no event yet, or a state map that
    # predates this field) falls back to "" / 0 / "".
    #
    # Code-review cycle 1 (MINOR-2): the identity tuple now carries `sender` as a
    # third element (both the live Room.Server GenServer state and the DB-restored
    # value from load_members/1 do this) — matched here, with the original 2-tuple
    # shape still accepted for state maps/fakes that predate this widening.
    {pl_event_id, pl_ts, pl_sender} =
      case Map.get(state, :power_levels_event) do
        {event_id, ts, sender} -> {event_id, ts, sender}
        {event_id, ts} -> {event_id, ts, ""}
        _ -> {"", 0, ""}
      end

    pl_event = %Core.SyncRoomStateEvent{
      type: "m.room.power_levels",
      state_key: "",
      content: Jason.encode!(state.power_levels),
      sender: pl_sender,
      event_id: pl_event_id,
      origin_server_ts: pl_ts
    }

    # Bugfix sync-state-events-missing-fields (AC2): the real DB returns a wider
    # {:ok, name, event_id, origin_server_ts} 4-tuple — SAME query, no extra DB
    # round trip. Code-review cycle 1 (MINOR-2): the real DB now returns an even
    # wider {:ok, name, event_id, origin_server_ts, sender} 5-tuple (still the
    # SAME query) so sender is no longer left as "" once event_id is real. Both
    # narrower shapes are still matched for fakes that predate these widenings.
    name_events =
      case messages_db_module().get_room_name(room_id) do
        {:ok, name, event_id, ts, sender} ->
          [%Core.SyncRoomStateEvent{
            type: "m.room.name",
            state_key: "",
            content: Jason.encode!(%{"name" => name}),
            sender: sender,
            event_id: event_id,
            origin_server_ts: ts
          }]
        {:ok, name, event_id, ts} ->
          [%Core.SyncRoomStateEvent{
            type: "m.room.name",
            state_key: "",
            content: Jason.encode!(%{"name" => name}),
            sender: "",
            event_id: event_id,
            origin_server_ts: ts
          }]
        {:ok, name} ->
          [%Core.SyncRoomStateEvent{
            type: "m.room.name",
            state_key: "",
            content: Jason.encode!(%{"name" => name}),
            sender: "",
            event_id: "",
            origin_server_ts: 0
          }]
        _ -> []
      end

    # Story 9-7: load generic state events persisted via PUT /rooms/{roomId}/state/{eventType}.
    # These cover m.room.topic, m.room.join_rules, m.room.encryption, m.room.avatar, etc.
    # Excludes types already assembled above (member, power_levels, create, name).
    generic_state_events =
      case messages_db_module().get_generic_state_events(room_id) do
        {:ok, evs} ->
          Enum.map(evs, fn ev ->
            %Core.SyncRoomStateEvent{
              type: ev.type,
              state_key: ev.state_key,
              content: ev.content_json,
              sender: ev.sender,
              event_id: Map.get(ev, :event_id, ""),
              origin_server_ts: Map.get(ev, :origin_server_ts, 0)
            }
          end)
        _ -> []
      end

    all_state_events =
      [create_event] ++ member_events ++ [pl_event] ++ name_events ++ generic_state_events

    if fetch_predecessors? do
      attach_predecessors_to_state_events(all_state_events, room_id, Keyword.get(opts, :read, :sync), Keyword.get(opts, :viewer))
    else
      all_state_events
    end
  end

  # ─── story membership-state-model: the member slots of the state ─────────────────────────────────────────────────

  # The joined slice of the room process (`member_slice: :joined`): one synthesized join per member, the identity captured by
  # Room.Server at the join and restored by do_init/1 (no per-sync DB round trip); the content is what a join persists.
  defp joined_member_events(state) do
    member_identity = Map.get(state, :member_identity, %{})

    state.members
    |> MapSet.to_list()
    |> Enum.map(fn uid ->
      {member_event_id, member_ts} = Map.get(member_identity, uid, {"", 0})

      %Core.SyncRoomStateEvent{
        type: "m.room.member",
        state_key: uid,
        content: Jason.encode!(%{"membership" => "join"}),
        sender: uid,
        event_id: member_event_id,
        origin_server_ts: member_ts
      }
    end)
  end

  # The EVENT-based member slots of ONE room (D1, D2, D8): `member_state_slice/2` through the messages db seam (read per request, no
  # cache, behind the node-wide gate of D19), D6 order; `filters` = the `/members` query (`[]` for the full state). A member WITHOUT
  # any member event is added as the synthesized join (D8 (a)); a latest `join` of a user outside the set is served as the event
  # says (D8 (b)). `read` is `:sync` (the `/sync` paths) or `:request` (`/members`, `/initialSync`). A read that could not run in
  # time (the 2 s statement timeout, a lost pool checkout, a full gate) DEGRADES the room on `/sync` to the joined slice (D18:
  # completeness gap, not a leak; ONE aggregated WARNING per response, L-3) and is the fixed 503 on a request; every other failure is the handled
  # 500 (fail closed: never a joined-only state). Only a TEST db module without the read gets the joined slice.
  defp member_slice_events(room_id, state, filters, read) do
    mod = messages_db_module()

    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, :member_state_slice, 2) ->
        case read_member_slice(mod, room_id, filters, read) do
          {:ok, slice} when is_list(slice) ->
            slice_with_legacy_members(slice, state, filters)

          other ->
            reason = with({:error, reason} <- other, do: reason)

            cond do
              not member_read_unavailable?(reason) ->
                Logger.error("member state: the member events of #{room_id} could not be read (#{db_error_class(reason)})")
                room_state_unavailable!()

              read == :sync ->
                note_degraded_room(room_id, reason)
                joined_member_events(state)

              true ->
                raise Nebu.Matrix.Error, member_list_unavailable(room_id, reason)
            end
        end

      mod == Nebu.Matrix.Room.DB ->
        Logger.error("member state: the db module of #{room_id} has no member_state_slice/2")
        room_state_unavailable!()

      true ->
        if legacy_join_listed?(filters), do: joined_member_events(state), else: []
    end
  end

  # D18 (security cycle 3, L-3): a degraded room of a `/sync` is reported to the request process (the rooms are built in tasks it
  # spawns), which logs ONE aggregated WARNING per response (`with_degraded_rooms_report/1`); per room: debug
  defp note_degraded_room(room_id, reason) do
    Logger.debug("member state: the member events of #{room_id} were not read (#{db_error_class(reason)}), the room is served joined-only")
    # the request process itself carries the marker; a room task reports to the process that spawned it (the request process)
    target = if Process.get(:member_state_report), do: self(), else: List.first(Process.get(:"$callers") || [self()])
    send(target, {:member_state_degraded, room_id, db_error_class(reason)})
  end

  @degraded_rooms_listed 10

  defp with_degraded_rooms_report(fun) do
    _stale = collect_degraded_rooms([])
    # the wait budget of the slice reads starts fresh with every response (a keep-alive connection process serves many)
    Process.delete(:member_slice_wait_deadline)
    nested? = Process.put(:member_state_report, true) == true

    result =
      try do
        fun.()
      after
        unless nested?, do: Process.delete(:member_state_report)
      end

    case collect_degraded_rooms([]) do
      [] ->
        :ok

      degraded ->
        classes = degraded |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.join(", ")
        rooms = degraded |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.take(@degraded_rooms_listed) |> Enum.join(" ")

        Logger.warning("sync: the member state of #{length(degraded)} room(s) was not read (#{classes}), served joined-only: #{rooms}")
    end

    result
  end

  defp collect_degraded_rooms(acc) do
    receive do
      {:member_state_degraded, room_id, class} -> collect_degraded_rooms([{room_id, class} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # D15 / D18 / D19: the read did not run in time (SQLSTATE 57014), lost its pool checkout, or the node-wide gate was full
  defp member_read_unavailable?(%Postgrex.Error{postgres: %{pg_code: "57014"}}), do: true
  defp member_read_unavailable?(%DBConnection.ConnectionError{}), do: true
  defp member_read_unavailable?(reason), do: reason == :overflow

  # the ONE 503 of the member reads (value-free WARNING: the room id and the error class), as the attributes of `Nebu.Matrix.Error`
  defp member_list_unavailable(room_id, reason) do
    Logger.warning("member state: the member events of #{room_id} were not read in time (#{db_error_class(reason)})")
    [status: Nebu.Matrix.Status.unavailable(), errcode: "M_UNAVAILABLE", message: "The member list is temporarily unavailable, try again"]
  end

  # D19: a `/sync` read waits briefly for a slot (one initial `/sync` reads up to 5 rooms in parallel), a request read never. The
  # wait is ONE budget per process and response (security cycle 3, L-3': `full_state_rooms` reads its rooms one after the other in
  # one process): the first read sets the deadline, an overflow spends it; `with_degraded_rooms_report/1` resets it per response.
  @sync_slice_wait_ms 1_000

  defp slice_wait_ms(:request), do: 0

  defp slice_wait_ms(:sync) do
    now = System.monotonic_time(:millisecond)

    deadline =
      case Process.get(:member_slice_wait_deadline) do
        nil ->
          Process.put(:member_slice_wait_deadline, now + @sync_slice_wait_ms)
          now + @sync_slice_wait_ms

        deadline ->
          deadline
      end

    max(deadline - now, 0)
  end

  defp read_member_slice(mod, room_id, filters, read) do
    case Nebu.Matrix.MemberSliceGate.run(fn -> mod.member_state_slice(room_id, filters) end, slice_wait_ms(read)) do
      {:ok, result} ->
        result

      :overflow ->
        # security cycle 3 (L-3'): the wait budget of this process is spent: the remaining rooms are not waited for
        if read == :sync, do: Process.put(:member_slice_wait_deadline, System.monotonic_time(:millisecond))
        {:error, :overflow}
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp slice_with_legacy_members(slice, state, filters) do
    from_events =
      Enum.map(slice, fn row ->
        {row.membership, row.state_key,
         %Core.SyncRoomStateEvent{
           type: "m.room.member",
           state_key: row.state_key,
           content: Jason.encode!(row.content),
           sender: row.sender,
           event_id: row.event_id,
           origin_server_ts: row.origin_server_ts
         }}
      end)

    # D8 (a): a member without a captured join identity and without a row in the slice has no member event at all (the identity
    # test keeps a member of a legacy half state, whose latest event a filter left out, from being synthesized as a join)
    legacy =
      if legacy_join_listed?(filters) do
        with_event = MapSet.new(slice, & &1.state_key)

        for ev <- joined_member_events(state), ev.event_id == "", not MapSet.member?(with_event, ev.state_key), do: {"join", ev.state_key, ev}
      else
        []
      end

    (from_events ++ legacy)
    |> Enum.sort_by(fn {membership, state_key, _ev} -> {Nebu.Matrix.Room.DB.member_slice_class(membership), state_key} end)
    |> Enum.map(&elem(&1, 2))
  end

  # a synthesized (legacy) join passes the `/members` filters like any join slot
  defp legacy_join_listed?(filters) do
    membership = Keyword.get(filters, :membership)
    not_membership = Keyword.get(filters, :not_membership)
    membership in [nil, "join"] and not_membership != "join"
  end

  # Bugfix unsigned-replaces-state (AC1/AC3/AC5), widened by story member-event-prev-content (D1): ONE additional
  # batched query per room (not per state event, not per sync response — "per room" is the Dev Notes' explicitly-sanctioned
  # alternative to "per response"). Enriches every Core.SyncRoomStateEvent built above with its real predecessor
  # (event_id, content, sender), if any.
  #
  # Code-review cycle 1 (MAJOR-3): this is only REACHED from build_state_events
  # when its caller opted in via `fetch_predecessors?: true` (see its own comment
  # for the call sites) and from get_room_members/2 (/members, story
  # membership-state-model). The summary / hierarchy callers never reach it.
  #
  # m.room.create's own entry is harmlessly included (always resolves to
  # no match, per Matrix invariant — first-ever event at its slot) rather than
  # specially filtered out, per the Dev Notes' "including it is also correct".
  # Entries with event_id == "" (no real persisted identity — legacy rooms
  # pre-dating migration 000035, see Nebu.Matrix.Http.build_joined_rooms/1's
  # own comment) are excluded from the batch — there is no stable anchor to
  # order against for those.
  # Story membership-state-model (security cycle 2, MINOR 2): `read: :request` (`/members`, `/initialSync`) uses the STRICT lookup:
  # its own 2 s statement timeout, a failure is the fixed 503 / the handled 500, never silently no predecessor keys.
  defp attach_predecessors_to_state_events(state_events, room_id, read, viewer) do
    slots =
      state_events
      |> Enum.filter(&(&1.event_id != ""))
      |> Enum.map(&{&1.event_id, room_id, &1.type, &1.state_key, &1.origin_server_ts})

    predecessors_by_id =
      if read == :request,
        do: fetch_state_predecessors_strict!(messages_db_module(), slots, room_id, viewer),
        else: fetch_state_predecessors_batch(messages_db_module(), slots, viewer)

    Enum.map(state_events, &put_predecessor(&1, predecessors_by_id))
  end

  # ─── Story direct-room-heroes: attach_heroes/3 ─────────────────────────────
  #
  # Attaches m.heroes / m.joined_member_count / m.invited_member_count to a
  # SyncRoom when the room has no explicit name (m.room.name event with a
  # non-empty name). Named rooms do not need heroes — clients use the room name.
  #
  # Called from get_initial_sync (always) and fetch_delta_rooms (only when
  # membership_changed = delta contains m.room.member events) per §11.2.2.
  #
  # On DB error: logs a warning and returns sync_room unchanged (fail-open).
  defp attach_heroes(%Core.SyncRoom{} = sync_room, user_id, state_events) do
    room_id = sync_room.room_id

    has_name =
      Enum.any?(state_events, fn ev ->
        ev.type == "m.room.name" and ev.state_key == "" and
          case Jason.decode(ev.content) do
            {:ok, %{"name" => name}} when is_binary(name) and name != "" -> true
            _ -> false
          end
      end)

    if has_name do
      # Named room — leave proto3 zero values so Go omits Summary via omitempty.
      sync_room
    else
      case messages_db_module().get_room_heroes(room_id, user_id) do
        {:ok, %{heroes: heroes, joined: joined, invited: invited}} ->
          %Core.SyncRoom{
            sync_room
            | heroes: heroes,
              joined_member_count: joined,
              invited_member_count: invited
          }

        {:error, reason} ->
          Logger.warning(
            "attach_heroes: DB error for room #{room_id}: #{inspect(reason)}"
          )

          sync_room
      end
    end
  end

  # ─── bugfix-autojoin-real-login-path: shared post-login provisioning entry point ──
  #
  # ROOT CAUSE (bugfix "Autojoin funktioniert nicht"): the real Matrix client
  # login endpoint `POST /_matrix/client/v3/login` (Nebu.Matrix.HttpPublic.do_login)
  # calls Nebu.Matrix.Session.TokenValidator.validate/4 DIRECTLY — it never goes
  # through this module's validate_token/2. The personal-room + auto-join Task.start
  # trigger lived ONLY inside validate_token/2, which turned out to have no
  # production caller at all (verified via a full-repo grep): every real login
  # (Element Web, FluffyChat, any Matrix client) skipped auto-join entirely, so a
  # brand-new user's very first login never joined `is_auto_join=true` rooms/spaces.
  #
  # Fix: extract the fire-and-forget provisioning into this single public function
  # so BOTH callers — validate_token/2 (kept for parity/tests) and
  # Nebu.Matrix.HttpPublic.provision_and_respond/6 (the actual production login
  # path) — trigger the same behaviour. `is_new` gates auto-join exactly as before;
  # the personal room is (idempotently) ensured on every login regardless.
  # Task.start/1 (unlike Task.start_link/1) has typespec dynamic({:ok, pid()}) — its
  # return value is never tagged {:error, reason}, so there is no failure branch to
  # pattern-match on here. Confirmed by the compiler's own type checker (Elixir 1.20
  # set-theoretic types): a prior {:error, reason} -> Logger.warning(...) clause was
  # flagged as "will never match" and removed — see bugfix-remove-unused-confirm-default.
  # Note: this does NOT mean spawning can never fail (VM-level resource exhaustion is
  # always possible) — only that Task.start/1 does not surface such failures as a
  # return value for us to branch on. If that telemetry gap ever matters (e.g. for
  # alerting), a system-level probe (:erlang.system_info/1 process/memory limits) would
  # be the right tool, not a case clause here.
  @spec run_post_login_provisioning(String.t(), boolean()) :: :ok
  def run_post_login_provisioning(user_id, is_new) do
    Task.start(fn ->
      ensure_personal_room(user_id)

      if is_new do
        ensure_auto_join_memberships(user_id)
        # Spaces S5 (AC6): auto-join flagged Spaces alongside flagged rooms.
        ensure_auto_join_space_memberships(user_id)
      end
    end)

    :ok
  end

  # ─── Story personal-self-room: ensure_personal_room/1 ───────────────────────

  # Idempotently ensures a personal self-room exists for `user_id`.
  # Called from run_post_login_provisioning/2 via Task.start (fire-and-forget,
  # non-blocking).
  #
  # Flow:
  #   1. Extract localpart from user_id (e.g. "alice" from "@alice:nebu.local").
  #   2. Check messages_db_module().get_personal_room_id/1.
  #      - {:ok, nil}       → no self-room yet → create one and set the ID.
  #      - {:ok, _room_id}  → already exists → no-op (idempotent).
  #      - {:error, reason} → DB down → log warning and return :ok (non-fatal).
  #   3. Creation failure is also non-fatal (logged as warning, returns :ok).
  #
  # AC4: any error path returns :ok and logs a warning — login is never blocked.
  defp ensure_personal_room(user_id) do
    localpart =
      user_id
      |> String.split(":")
      |> hd()
      |> String.trim_leading("@")

    case messages_db_module().get_personal_room_id(user_id) do
      {:ok, nil} ->
        # First login — create the personal room and record the ID.
        # create_personal_room/2 is non-fatal: it logs warnings on DB errors and always
        # returns {:ok, room_id}. set_personal_room_id/2 failure is also non-fatal.
        {:ok, room_id} = create_personal_room(user_id, localpart)
        case messages_db_module().set_personal_room_id(user_id, room_id) do
          :ok ->
            :ok

          {:ok, :already_set} ->
            # F-3 (SEC): concurrent first-login race — another Task won the claim.
            # The room we created is now an orphan (user is sole member, not canonical).
            # No security boundary crossed; orphan appears in /sync until a janitor removes it.
            Logger.warning(
              "ensure_personal_room: concurrent first-login race detected for #{user_id} — " <>
                "orphan room #{room_id} created. Another Task won the claim."
            )
            :ok

          {:error, reason} ->
            Logger.warning("ensure_personal_room: set_personal_room_id failed for #{user_id}: #{inspect(reason)}")
            :ok
        end

      {:ok, _existing_room_id} ->
        # Already exists — idempotent no-op (AC2).
        :ok

      {:error, reason} ->
        # DB error checking existence — non-fatal (AC4).
        Logger.warning("ensure_personal_room: DB error for #{user_id}: #{inspect(reason)}")
        :ok
    end
  end

  # ─── Story admin-auto-join-rooms: ensure_auto_join_memberships/1 ─────────────
  #
  # Public so that ExUnit AC5/AC6 tests can call it directly in isolation.
  # Called from run_post_login_provisioning/2 via Task.start for new users only
  # (is_new: true) — the shared entry point invoked from 3 places: validate_token/2,
  # bulk_import_users/2, and Nebu.Matrix.HttpPublic's real /login path.
  # Non-fatal: any error logs a warning and returns :ok — login is never blocked.
  #
  # Flow:
  #   1. Fetch all rooms with is_auto_join=true from messages_db_module().
  #   2. For each room_id: start the Room GenServer (idempotent), then join.
  #   3. {:error, :already_member} → :ok silently (idempotent AC5).
  #   4. Other join errors → log warning, continue (non-fatal).
  #   5. list_auto_join_rooms error → log warning, return :ok (non-fatal AC6).
  def ensure_auto_join_memberships(user_id) do
    # F-4 (SEC), updated by story create-room-presets-power-levels-topic (D1): this call site bypasses the join
    # DECISION of join_room/2 (the join rule: auto-join is admin policy, an operator flags a room and every new user is
    # put into it, invite-only rooms included) but RESPECTS AN EXISTING BAN: a user whose latest membership in the room is
    # `ban` is skipped (decision of the pipeline orchestrator; flip together with auto_join_join_rule_test.exs if the
    # owner decides otherwise). A membership that cannot be read is skipped as well (fail closed: never join a user
    # that may be banned). Logs: room id and error class only.
    case messages_db_module().list_auto_join_rooms() do
      {:ok, room_ids} ->
        # Story rm5 (AC5): skip rooms the user has explicitly opted out of (left).
        # A left auto-join room must NOT reappear on the next login/sync.
        room_ids = reject_opted_out(room_ids, user_id)

        Enum.each(room_ids, fn room_id ->
          _ = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
          # Wrap in try/catch to handle GenServer.call exits (:noproc) non-fatally.
          # GenServer.call raises an exit exception when the target process is not alive,
          # so a bare case match is insufficient — exits must be caught explicitly.
          try do
            case auto_join_member_join(room_id, user_id) do
              :ok -> :ok
              {:error, :already_member} -> :ok
              {:error, reason} ->
                # A genuine (non-idempotent) join failure means the user did NOT get
                # auto-joined to a room they should have — this must be observable in
                # production (bugfix: "Autojoin funktioniert nicht"), so log at :error.
                Logger.error(
                  "ensure_auto_join_memberships: join #{room_id} for #{user_id} failed: #{inspect(reason)}"
                )
            end
          catch
            :exit, reason ->
              Logger.error(
                "ensure_auto_join_memberships: join #{room_id} for #{user_id} exited: #{inspect(reason)}"
              )
          end
        end)
        :ok

      {:error, reason} ->
        Logger.warning(
          "ensure_auto_join_memberships: list_auto_join_rooms failed for #{user_id}: #{inspect(reason)}"
        )
        :ok
    end
  end

  # The auto-join itself: the direct Room.Server.join/2 (no join rule decision), unless the user is banned from the room.
  defp auto_join_member_join(room_id, user_id) do
    if auto_join_banned?(room_id, user_id), do: :ok, else: Nebu.Matrix.Room.Server.join(room_id, user_id)
  end

  # True when the auto-join of the user into the room must be skipped: the user's latest membership is `ban` or (fail
  # closed) cannot be read. The read goes through messages_db_module() like opted_out?/2; an injected fake without
  # get_member_membership/2 (older unit tests) has no ban state to read. Value-free logs: room id and error class.
  defp auto_join_banned?(room_id, user_id) do
    mod = messages_db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :get_member_membership, 2) do
      result =
        try do
          mod.get_member_membership(room_id, user_id)
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case result do
        {:ok, "ban"} ->
          Logger.warning("auto_join: skipping room #{room_id}: the user is banned from it")
          true

        {:ok, _membership} ->
          false

        other ->
          reason = with {:error, reason} <- other, do: reason
          Logger.error("auto_join: skipping room #{room_id}: the membership state cannot be read (#{db_error_class(reason)})")
          true
      end
    else
      false
    end
  end

  # ─── Spaces S5: ensure_auto_join_space_memberships/1 ───────────────────────
  #
  # Public so that ExUnit AC6 tests can call it directly in isolation.
  # Called from run_post_login_provisioning/2 for new users only, right next to
  # ensure_auto_join_memberships/1 — the shared entry point invoked from 3
  # places: validate_token/2, bulk_import_users/2, and Nebu.Matrix.HttpPublic's
  # real /login path. Non-fatal: any error logs a warning and returns :ok —
  # login is never blocked.
  #
  # A Space is a room (room_type = 'm.space'), so the join machinery is identical
  # to ensure_auto_join_memberships/1; only the source list differs
  # (list_auto_join_spaces/0 vs list_auto_join_rooms/0). Keeping the two scoped and
  # separate means a flagged Space is processed exactly once (AC6) and a future
  # space-specific join policy (e.g. auto-joining the space's suggested children)
  # has a single call site.
  def ensure_auto_join_space_memberships(user_id) do
    mod = messages_db_module()

    # Tolerate injected fakes that predate Spaces S5 (no list_auto_join_spaces/0):
    # treat them as "no auto-join spaces" rather than crashing the fire-and-forget Task.
    # function_exported? is the established degrade-gracefully pattern here
    # (see safe_generic_state_events/1).
    result =
      if function_exported?(mod, :list_auto_join_spaces, 0) do
        mod.list_auto_join_spaces()
      else
        {:ok, []}
      end

    case result do
      {:ok, space_ids} ->
        # Story rm5 (AC5): skip auto-join spaces the user has opted out of (left).
        space_ids = reject_opted_out(space_ids, user_id)

        Enum.each(space_ids, fn space_id ->
          _ = Nebu.Matrix.Room.RoomSupervisor.start_room(space_id)

          try do
            case auto_join_member_join(space_id, user_id) do
              :ok -> :ok
              {:error, :already_member} -> :ok
              {:error, reason} ->
                # See ensure_auto_join_memberships/1: a genuine join failure must be
                # visible in production, not just a warning that gets filtered out.
                Logger.error(
                  "ensure_auto_join_space_memberships: join #{space_id} for #{user_id} failed: #{inspect(reason)}"
                )
            end
          catch
            :exit, reason ->
              Logger.error(
                "ensure_auto_join_space_memberships: join #{space_id} for #{user_id} exited: #{inspect(reason)}"
              )
          end
        end)

        :ok

      {:error, reason} ->
        Logger.warning(
          "ensure_auto_join_space_memberships: list_auto_join_spaces failed for #{user_id}: #{inspect(reason)}"
        )
        :ok
    end
  end

  # ─── Story rm5 (AC5): filter out rooms/spaces the user has opted out of ──────
  #
  # Given a candidate list of auto-join room/space ids, drop any the user has an
  # opt-out row for, so a left auto-join room is NOT re-joined on next login/sync.
  #
  # Default-deny on the suppression direction: if the opt-out check errors for a
  # room, we KEEP it (re-join) rather than silently dropping it — an opt-out must be
  # positively proven before it suppresses an auto-join, so a transient DB error can
  # never strip a user of a legitimate auto-join membership. Degrades gracefully for
  # injected fakes that predate rm5 (function_exported?/3) — they keep all rooms.
  #
  # Uses messages_db_module() — the same seam list_auto_join_rooms/0 and
  # list_auto_join_spaces/0 come from — so the opt-out check is injected together
  # with the candidate list in tests (predating fakes simply lack opted_out?/2).
  defp reject_opted_out(room_ids, user_id) do
    mod = messages_db_module()

    if function_exported?(mod, :opted_out?, 2) do
      Enum.reject(room_ids, fn room_id ->
        case mod.opted_out?(room_id, user_id) do
          {:ok, true} ->
            true

          {:ok, false} ->
            false

          {:error, reason} ->
            Logger.warning(
              "reject_opted_out: opted_out? check failed for #{user_id}/#{room_id}: #{inspect(reason)} — keeping room"
            )

            false
        end
      end)
    else
      room_ids
    end
  end

  # Creates a private personal room for `user_id` named after `localpart`.
  #
  # This is a direct-DB creation path — it does NOT start a Room GenServer via
  # Nebu.Matrix.Room.RoomSupervisor. Instead it writes all required rows and events
  # directly to the database. The Room GenServer will be started on-demand when
  # the user calls GET /sync (via get_initial_sync → start_room on :noproc catch).
  #
  # Event order follows Matrix spec §8.5.1:
  #   1. m.room.create (first event — room identity)
  #   2. m.room.member join (membership)
  #   3. m.room.power_levels (power levels)
  #   4. m.room.name (room name = localpart)
  #
  # Using only messages_db_module() makes this function fully testable via
  # fake DB injection (no Horde / room_manager dependency in tests).
  #
  # Returns {:ok, room_id} on success or {:error, reason} on failure.
  defp create_personal_room(user_id, localpart) do
    room_id = generate_room_id()
    now_ms = Nebu.DB.Helpers.now_ms()

    # 1. Insert the room record (private visibility).
    # Non-fatal: ON CONFLICT DO NOTHING means a concurrent race may have already succeeded.
    # A real DB error is also non-fatal — we still attempt the member insert below.
    case messages_db_module().insert_room(room_id) do
      {:ok, _} ->
        :ok
      {:error, reason} ->
        Logger.warning("create_personal_room: insert_room failed for #{room_id}: #{inspect(reason)}")
    end

    # 2. Insert the creator as the sole member.
    case messages_db_module().insert_member(room_id, user_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("create_personal_room: insert_member failed for #{room_id}: #{inspect(reason)}")
    end

    # Helper to sign and persist an event.
    persist_event = fn event_map ->
      event_id = Nebu.Matrix.EventId.generate(event_map)
      event_with_id = Map.put(event_map, "event_id", event_id)
      {_pub, priv} = :persistent_term.get(:nebu_signing_key)
      event_json = Nebu.Matrix.CanonicalJson.encode!(event_map)
      sig = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
      signed = Map.put(event_with_id, "signatures", %{"nebu" => Base.encode64(sig)})
      case messages_db_module().insert_event(signed) do
        :ok ->
          Enum.each(:pg.get_members("room:#{room_id}"), &send(&1, {:new_event, signed}))
          :ok
        {:error, reason} ->
          Logger.warning("create_personal_room: insert_event failed (#{event_map["type"]}): #{inspect(reason)}")
          :ok
      end
    end

    # 3. Emit m.room.create (Matrix spec §8.5.1: first event).
    create_event = %{
      "room_id"          => room_id,
      "type"             => "m.room.create",
      "state_key"        => "",
      "sender"           => user_id,
      "content"          => %{"creator" => user_id, "room_version" => Nebu.Matrix.RoomVersions.default()},
      "origin_server_ts" => now_ms
    }
    persist_event.(create_event)

    # 4. Emit m.room.member join (membership).
    member_event = %{
      "room_id"          => room_id,
      "type"             => "m.room.member",
      "state_key"        => user_id,
      "sender"           => user_id,
      "content"          => %{"membership" => "join"},
      "origin_server_ts" => now_ms + 1
    }
    persist_event.(member_event)

    # 5. Emit m.room.power_levels with creator at PL 100.
    default_pl = Nebu.Matrix.Room.Server.default_power_levels()
    creator_pl = put_in(default_pl, ["users", user_id], 100)
    pl_event = %{
      "room_id"          => room_id,
      "type"             => "m.room.power_levels",
      "state_key"        => "",
      "sender"           => user_id,
      "content"          => creator_pl,
      "origin_server_ts" => now_ms + 2
    }
    case messages_db_module().set_power_levels(room_id, Jason.encode!(creator_pl)) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("create_personal_room: set_power_levels failed for #{room_id}: #{inspect(reason)}")
    end
    persist_event.(pl_event)

    # 6. Emit m.room.name with the Matrix localpart as the room name.
    name_event = %{
      "room_id"          => room_id,
      "type"             => "m.room.name",
      "state_key"        => "",
      "sender"           => user_id,
      "content"          => %{"name" => localpart},
      "origin_server_ts" => now_ms + 3
    }
    persist_event.(name_event)

    {:ok, room_id}
  end

  # ─── Room moderation: kick, ban, unban (Story 7-22; story moderation-routes-atomic-ban) ─────────────────────────────
  #
  # POST /rooms/{roomId}/kick | ban | unban. The router charges the `moderation` tier and validates the body
  # (`moderation_body!/1`) first; these functions are thin: the pure checks (the room is running, the local-domain rule of a
  # ban), then ONE call of `Room.Server.moderate/6`, which decides and writes the change in the room process in ONE transaction
  # (D1-D4), then the error mapping (D6: an explicit errcode and a fixed text for every refusal, no user id and no reason in a
  # message or a log line) and the audit row of a committed change (D12).

  # the 403 texts of a refused moderation (D6; the spec's example wording for the power level)
  @moderation_refusals %{
    sender_not_joined: "You are not a member of this room",
    target_not_lower: "You cannot act on a user whose power level is not lower than yours",
    target_banned: "The user is banned from this room: unban them instead",
    target_not_in_room: "The user is not in this room",
    not_banned: "The user is not banned from this room"
  }

  # D10: the `reason` cap in bytes (a Nebu choice: 1024 bytes keep every moderation event far below the 65 536 byte limit)
  @moderation_reason_max_bytes 1024

  @doc false
  # Story moderation-routes-atomic-ban (D6, D10): the body of POST /rooms/{roomId}/kick | ban | unban (a JSON OBJECT: the router has
  # told M_NOT_JSON and a non-object M_BAD_JSON apart) -> `{user_id, reason | nil}` or a raised Nebu.Matrix.Error. Only `user_id`
  # and `reason` are read (3pid and unknown keys are ignored); `user_id` has the shape rules of the invitee of POST /invite.
  # Fixed messages, no client value.
  @spec moderation_body!(map()) :: {String.t(), String.t() | nil}
  def moderation_body!(params) when is_map(params) do
    {validate_invitee_shape!(Map.get(params, "user_id")), moderation_reason!(Map.get(params, "reason"))}
  end

  # absent / null / "" = no reason (no `reason` key on the event); NUL is refused (PostgreSQL JSONB cannot store it), the cap
  # counts BYTES (UTF-8), not code points
  defp moderation_reason!(nil), do: nil
  defp moderation_reason!(""), do: nil

  defp moderation_reason!(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, <<0>>) -> reject!("M_BAD_JSON", "reason must not contain NUL")
      byte_size(reason) > @moderation_reason_max_bytes -> reject!("M_INVALID_PARAM", "reason exceeds #{@moderation_reason_max_bytes} bytes")
      true -> reason
    end
  end

  defp moderation_reason!(_other), do: reject!("M_BAD_JSON", "reason must be a string")

  # a stored reason that passes the D10 rules (the ban copy of an upgrade copies only such a reason, D11)
  defp valid_moderation_reason?(reason) do
    is_binary(reason) and byte_size(reason) <= @moderation_reason_max_bytes and not String.contains?(reason, <<0>>)
  end

  @doc """
  Handles POST /_matrix/client/v3/rooms/{roomId}/kick: removes a member, or REVOKES the pending invitation of an invitee (Element's
  "Disinvite"), through `Room.Server.moderate/6` (story moderation-routes-atomic-ban). Audit `room_member_kicked`.
  """
  def kick_user(request, stream) do
    moderate!(:kick, request, stream)
    %Core.KickUserResponse{}
  end

  @doc """
  Handles POST /_matrix/client/v3/rooms/{roomId}/ban: bans a member, an invitee, a user who left or a local id that never joined
  (pre-emptive), through `Room.Server.moderate/6`; a repeated ban is an idempotent success without a new event. A user of another
  server is refused before the room call. Audit `room_member_banned` (not for the idempotent repeat).
  """
  def ban_user(request, stream) do
    moderate!(:ban, request, stream)
    %Core.BanUserResponse{}
  end

  @doc """
  Handles POST /_matrix/client/v3/rooms/{roomId}/unban: the leave of a BANNED user by the unbanner (needs the `ban` AND the `kick`
  level), through `Room.Server.moderate/6`. Audit `room_member_unbanned`.
  """
  def unban_user(request, stream) do
    moderate!(:unban, request, stream)
    %Core.UnbanUserResponse{}
  end

  defp moderate!(action, request, stream) do
    room_id = request.room_id
    {caller_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)
    target_id = request.target_id
    reason = if is_binary(request.reason) and request.reason != "", do: request.reason

    # a room whose process is not running is 404 like /invite and /join (a Nebu choice: the spec lists only 403); no room process
    # is started and no rooms row is created for an unknown id
    if Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) == {:error, :not_found} do
      raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "Room not found"
    end

    # D4 (b), a Nebu choice: no federation, a user of another server can never join, so there is nothing to ban (pure, no read)
    if action == :ban and not local_domain?(target_id) do
      raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: "Only users of this server can be banned"
    end

    result =
      try do
        Nebu.Matrix.Room.Server.moderate(room_id, action, caller_id, target_id, reason, outcome: true)
      catch
        :exit, _reason -> {:error, :room_unavailable}
      end

    case result do
      {:ok, outcome} -> audit_moderation(action, caller_id, room_id, target_id, outcome)
      {:error, refusal} -> raise_moderation_refusal!(action, room_id, refusal)
    end
  end

  defp raise_moderation_refusal!(action, room_id, refusal) do
    cond do
      # review cycle 2 (Kassandra L-5): an archived room takes no moderation, also while its process still runs: the answer of a
      # room whose process is not running
      refusal == :room_archived ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "Room not found"

      Map.has_key?(@moderation_refusals, refusal) ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: Map.fetch!(@moderation_refusals, refusal)

      refusal == :insufficient_level ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.permission_denied(),
          errcode: "M_FORBIDDEN",
          message: "You do not have a high enough power level to #{action} from this room."

      # the size backstop of the event (unreachable through the routes: the reason cap and the key limits come first)
      refusal in [:event_too_large, :state_key_too_long, :type_too_long] ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.too_large(), message: Nebu.Matrix.EventSize.message(refusal)

      refusal == :sender_too_long ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: Nebu.Matrix.EventSize.message(refusal)

      # D3: the GenServer call exited (timeout, the process died): the outcome is ambiguous for the CALLER only, the room committed
      # or rolled back. Not a spec errcode (kept for consistency with the other 503s).
      refusal == :room_unavailable ->
        Logger.error("#{action}: the room process of #{room_id} did not answer")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.unavailable(),
          errcode: "M_UNAVAILABLE",
          message: "The room did not answer, the change may or may not have been applied"

      # :write_failed, :unsupported_db_module, :membership_unavailable: nothing was written (Room.Server logged the class)
      true ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "#{action} failed"
    end
  end

  # D12: ONE audit row after a COMMITTED change, best effort (like `room_joined`): a failing writer is a value-free ERROR log and
  # never undoes or fails the action. Metadata is the target id only (kick: plus `invitation_revoked`); the `reason` is user text,
  # it lives in the signed event and is never copied here. Not for the idempotent ban (nothing changed: no new event).
  defp audit_moderation(:ban, _caller_id, _room_id, _target_id, %{event_written: false}), do: :ok

  defp audit_moderation(action, caller_id, room_id, target_id, outcome) do
    {audit_action, metadata} =
      case action do
        :kick -> {"room_member_kicked", %{"user_id" => target_id, "invitation_revoked" => outcome.invitation_revoked}}
        :ban -> {"room_member_banned", %{"user_id" => target_id}}
        :unban -> {"room_member_unbanned", %{"user_id" => target_id}}
      end

    result =
      try do
        audit_writer_module().log(caller_id, audit_action, "room", room_id, metadata, "success")
      rescue
        e -> {:error, e}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      :ok ->
        :ok

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("#{action}: the audit row of #{room_id} could not be written (#{db_error_class(reason)})")
        :ok
    end
  end

  @doc """
  Handles POST /_matrix/client/v3/rooms/{roomId}/forget.

  Marks a room as excluded from future /sync for the calling user:
  1. Verifies room exists.
  2. Verifies caller is NOT currently joined (must leave first).
  3. Returns empty ForgetRoomResponse on success.

  On success the `(user_id, room_id)` pair is recorded in `forgotten_rooms`
  (idempotent — `ON CONFLICT DO NOTHING`) so the room is excluded from future
  `/sync` responses (story forget-room-membership-purge). The join-guard rejection
  path writes nothing.
  """
  def forget_room(request, _stream) do
    room_id = request.room_id
    user_id = request.user_id

    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        state = Nebu.Matrix.Room.Server.get_state(room_id)

        # Cannot forget a room while still joined. This guard runs BEFORE any
        # write, so a rejected forget leaves forgotten_rooms untouched (AC2).
        if MapSet.member?(state.members, user_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.failed_precondition(),
            message: "user must leave the room before forgetting"
        end

        # Room is not currently joined — persist the forget. user_id comes from the
        # validated token (never the request body), so a user can only forget their
        # own membership. Idempotent: a repeated forget is a no-op.
        #
        # This DB call is DELIBERATELY unguarded (no function_exported?/Process.whereis
        # fallback): forget MUST fail loudly so the client never gets a 200 for a forget
        # that was not durably recorded — a DB error raises `unavailable` below. This is
        # the deliberate asymmetry vs unforget_room/2 (best-effort on re-join, may be
        # silently skipped if the Repo is down): a missed unforget only delays a room
        # reappearing until the next re-join, whereas a missed forget would silently
        # re-leak a room the user asked to forget.
        case rooms_db_module().insert_forgotten_room(user_id, room_id) do
          :ok ->
            %Core.ForgetRoomResponse{}

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.unavailable(),
              message: "failed to record forgotten room: #{inspect(reason)}"
        end
    end
  end

  # ─── Story 6.9: ArchiveRoom + UnarchiveRoom ────────────────────────────────────
  #
  # archive_room/2:
  #   Called by the Admin HTTP handler after successfully setting rooms.status = 'archived' in DB.
  #   Best-effort: terminates the running Room GenServer via Horde so in-memory state is
  #   cleared. The DB is authoritative — even if the GenServer is not running, ok=true.
  #   On next start, Room.Server.init/1 sees status="archived" → {:stop, :normal} → no loop.
  #
  # unarchive_room/2:
  #   Called by the Admin HTTP handler after successfully setting rooms.status = 'active' in DB.
  #   Best-effort: starts the Room GenServer so it is immediately available for messages.
  #   Returns ok=true even if start_room fails (DB is authoritative; returns 200).

  # ─── Story 9.1 AC:4 — ArchiveRoom with atomic SELECT FOR UPDATE ─────────────
  #
  # IMPORTANT CONTRACT CHANGE (Story 9.1):
  # Pre-9.1: Go Gateway set rooms.status='archived' in DB, then called this RPC
  #          which only terminated the GenServer.
  # Post-9.1: Core now owns the DB write atomically (SELECT FOR UPDATE) before
  #           terminating the GenServer. The Gateway call sequence must adapt in
  #           Story 9.2 — the Gateway should no longer update DB before calling
  #           this RPC; Core is now the authoritative writer for archive operations.
  #
  # The admin_db_module().archive_room_atomic/1 call performs:
  #   1. BEGIN TRANSACTION
  #   2. SELECT status FROM rooms WHERE room_id = ? FOR UPDATE
  #   3. UPDATE rooms SET status = 'archived' WHERE room_id = ?
  #   4. COMMIT
  # Then the GenServer is terminated (best-effort).

  def archive_room(%Core.ArchiveRoomRequest{} = req, stream) do
    room_id = req.room_id
    {actor_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    # ─── Story rm5 (AC2): personal-room ARCHIVE guard — server-side, default-deny ─
    #
    # An admin must never be able to archive ANY user's personal self-room, even by
    # calling this path directly (the Admin UI also hides the control, but UI-only
    # hiding is not a security boundary — SEC finding). The guard runs BEFORE the
    # atomic status write, so a rejected archive leaves rooms.status = 'active'.
    # We reuse the Nebu.Matrix.Error permission_denied shape (→ 403 M_FORBIDDEN), the
    # same mapping as the personal-room leave guard and the restricted-join path.
    #
    # get_personal_room_owner/1 is an exact-match parameterised lookup (ADR-018).
    # A DB error there is treated as "cannot prove it is a personal room" → fall
    # through; the guard only ever BLOCKS, so this never opens an unintended archive.
    #
    # In production admin_db_module() is the real Nebu.Admin.DB, which always exports
    # get_personal_room_owner/1, so the guard is always active. function_exported?/3
    # degrades gracefully only for older injected fakes in unrelated archive tests.
    admin_mod = admin_db_module()

    if function_exported?(admin_mod, :get_personal_room_owner, 1) do
      case admin_mod.get_personal_room_owner(room_id) do
        {:ok, _owner_id} ->
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "cannot archive a personal room"

        _ ->
          :ok
      end
    end

    # Step 1: Atomically update rooms.status='archived' in DB (SELECT FOR UPDATE).
    # This replaces the old pre-9.1 contract where the Go Gateway did the DB write.
    case admin_db_module().archive_room_atomic(room_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "archive_room DB update failed: #{inspect(reason)}"
    end

    # Step 2: Terminate the running GenServer (best-effort — idempotent if not running).
    # Room.Server.child_spec uses :transient restart, so Horde will NOT restart it
    # after a terminate_child call. DB status is the authoritative archived flag.
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} ->
        case Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid) do
          :ok ->
            :ok

          {:error, reason} ->
            # Race: process likely crashed between lookup and terminate. The DB
            # is already archived, so this is a soft failure — log and continue.
            Logger.warning("ArchiveRoom: terminate_child failed (likely already stopped) — #{inspect(reason)}",
              room_id: room_id
            )

            :ok
        end

      {:error, :not_found} ->
        # Already stopped — no-op (idempotent).
        :ok
    end

    # Story 9.3: Audit log for room archival (mirrors deactivate_user pattern from Story 9.2).
    audit_writer_module().log(
      actor_id,
      "room_archived",
      "room",
      room_id,
      %{},
      "success"
    )

    %Core.ArchiveRoomResponse{ok: true}
  end

  def unarchive_room(%Core.UnarchiveRoomRequest{} = req, stream) do
    room_id = req.room_id
    {actor_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    # Step 1: Atomically update rooms.status='active' in DB (SELECT FOR UPDATE).
    # Contract fix (full-elixir-stack / ADR-021): pre-removal the Go Gateway wrote
    # rooms.status='active' before calling this RPC; with the Gateway gone Core must
    # own this write, mirroring archive_room/2. Without it an unarchive reported
    # success but left rooms.status='archived', stranding the room as "Archived".
    case admin_db_module().unarchive_room_atomic(room_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "could not unarchive room: #{inspect(reason)}"
    end

    # Step 2: Start the Room GenServer so it is immediately available.
    # Room.Server.init/1 now calls get_room_status/1 on start:
    #   → {:ok, "active"} means the room is unarchived — init proceeds normally.
    #   → {:ok, "archived"} would be a race condition (DB not yet updated) — init stops.
    # Best-effort: if start_room fails, the DB is already updated to 'active';
    # the GenServer will start on the next client request.
    case Nebu.Matrix.Room.RoomSupervisor.start_room(room_id) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> :ok
    end

    # Story 9.3: Audit log for room unarchival (mirrors reactivate_user pattern from Story 9.2).
    audit_writer_module().log(
      actor_id,
      "room_unarchived",
      "room",
      room_id,
      %{},
      "success"
    )

    %Core.UnarchiveRoomResponse{ok: true}
  end

  # ─── Story 9.1: Admin RPCs — User + Room Management ───────────────────────────

  # ─── ListAdminUsers ──────────────────────────────────────────────────────────
  #
  # Returns paginated users from PostgreSQL for the Admin UI.
  # Email masking: returns "u***@domain" pattern (first char + *** + @domain).
  # PII: display_name_encrypted (Tier 1) is decrypted here via admin_db_module.
  # Email (Tier 2) is returned masked — never in plaintext.
  # Security: admin RPCs verified via RequireRole middleware in Go Gateway (HTTP layer).

  def list_admin_users(%Core.ListAdminUsersRequest{} = req, _stream) do
    limit = if req.limit > 0, do: min(req.limit, 100), else: 20
    cursor = req.cursor || ""
    search = req.search || ""

    {users, next_cursor} = admin_db_module().list_users(limit, cursor, search)

    proto_users =
      Enum.map(users, fn user ->
        %Core.AdminUserProto{
          user_id: user.user_id,
          display_name: decrypt_display_name(user),
          email_masked: mask_email(user),
          is_active: user.is_active,
          system_role: user.system_role || "user",
          created_at: user.created_at || 0
        }
      end)

    %Core.ListAdminUsersResponse{
      users: proto_users,
      total: length(proto_users),
      next_cursor: next_cursor
    }
  end

  # ─── GetAdminUser ────────────────────────────────────────────────────────────

  def get_admin_user(%Core.GetAdminUserRequest{} = req, _stream) do
    case admin_db_module().get_user(req.user_id) do
      {:ok, user} ->
        %Core.GetAdminUserResponse{
          user: %Core.AdminUserProto{
            user_id: user.user_id,
            display_name: decrypt_display_name(user),
            email_masked: mask_email(user),
            is_active: user.is_active,
            system_role: user.system_role || "user",
            created_at: user.created_at || 0
          }
        }

      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "user not found: #{req.user_id}"

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "get_admin_user failed: #{inspect(reason)}"
    end
  end

  # ─── DeactivateUser ──────────────────────────────────────────────────────────
  #
  # Sets is_active=false in DB, then calls destroy_session/1 AFTER the DB commit.
  # Security invariant: DB update must complete before session invalidation.

  def deactivate_user(%Core.DeactivateUserRequest{} = req, stream) do
    user_id = req.user_id
    {actor_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    case admin_db_module().set_is_active(user_id, false) do
      :ok ->
        # Session invalidation happens AFTER DB commit (sequencing invariant).
        case session_supervisor_module().destroy_session(user_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("DeactivateUser: destroy_session failed for #{user_id}: #{inspect(reason)}")
        end

        # oidc-session-refresh cycle-2 (Kassandra HIGH): destroy_session/1 only
        # clears the legacy sessions/sync_tokens tables — it does NOT delete the
        # opaque matrix_sessions rows. Without this, an admin-deactivated user
        # keeps a fully working opaque Matrix AT (up to 8h) and POST /refresh
        # mints fresh tokens for them. Delete the opaque AT+RT rows here too, in
        # the same AFTER-DB-commit position (sequencing invariant preserved).
        # Best-effort: delete_for_user/1 log-swallows and returns :ok.
        Nebu.Matrix.Session.MatrixSessionStore.delete_for_user(user_id)

        audit_writer_module().log(
          actor_id,
          "user_deactivated",
          "user",
          user_id,
          %{},
          "success"
        )

        %Core.DeactivateUserResponse{ok: true}

      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "user not found: #{user_id}"

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "deactivate_user DB update failed: #{inspect(reason)}"
    end
  end

  # ─── ReactivateUser ──────────────────────────────────────────────────────────
  #
  # Sets is_active=true in DB. Does NOT call destroy_session (reactivation must
  # not invalidate existing sessions).

  def reactivate_user(%Core.ReactivateUserRequest{} = req, stream) do
    user_id = req.user_id
    {actor_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    case admin_db_module().set_is_active(user_id, true) do
      :ok ->
        audit_writer_module().log(
          actor_id,
          "user_reactivated",
          "user",
          user_id,
          %{},
          "success"
        )

        %Core.ReactivateUserResponse{ok: true}

      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "user not found: #{user_id}"

      # story gdpr-erasure-global-data: the erasure is terminal, an erased user is never reactivated (a clean refusal, no audit row)
      {:error, :erased} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.failed_precondition(),
          message: "user has been erased and cannot be reactivated: #{user_id}"

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "reactivate_user DB update failed: #{inspect(reason)}"
    end
  end

  # ─── UpdateUserRole ──────────────────────────────────────────────────────────
  #
  # Updates users.system_role directly (NOT role_overrides — those are Gateway-side
  # overrides with TTL cache). Valid values: "user", "instance_admin", "compliance_officer".

  @valid_roles ~w(user instance_admin compliance_officer)

  def update_user_role(%Core.UpdateUserRoleRequest{} = req, stream) do
    user_id = req.user_id
    role = req.role
    {actor_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    unless role in @valid_roles do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.invalid_argument(),
        message: "invalid role '#{role}'; must be one of: #{Enum.join(@valid_roles, ", ")}"
    end

    case admin_db_module().set_system_role(user_id, role) do
      :ok ->
        audit_writer_module().log(
          actor_id,
          "update_user_role",
          "user",
          user_id,
          %{"role" => role},
          "success"
        )

        %Core.UpdateUserRoleResponse{ok: true}

      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "user not found: #{user_id}"

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "update_user_role DB update failed: #{inspect(reason)}"
    end
  end

  # ─── ListAdminRooms ──────────────────────────────────────────────────────────

  def list_admin_rooms(%Core.ListAdminRoomsRequest{} = req, _stream) do
    limit = if req.limit > 0, do: min(req.limit, 100), else: 20
    cursor = req.cursor || ""
    status_filter = req.status_filter || ""
    search = req.search || ""

    {rooms, next_cursor} = admin_db_module().list_rooms(limit, cursor, status_filter, search)

    proto_rooms =
      Enum.map(rooms, fn room ->
        %Core.AdminRoomProto{
          room_id: room.room_id,
          name: room.name || "",
          status: room.status || "active",
          member_count: room.member_count || 0,
          created_at: room.created_at || 0
        }
      end)

    %Core.ListAdminRoomsResponse{
      rooms: proto_rooms,
      total: length(proto_rooms),
      next_cursor: next_cursor
    }
  end

  # ─── GetAdminRoom ────────────────────────────────────────────────────────────

  def get_admin_room(%Core.GetAdminRoomRequest{} = req, _stream) do
    case admin_db_module().get_room(req.room_id) do
      {:ok, room} ->
        %Core.GetAdminRoomResponse{
          room: %Core.AdminRoomDetailProto{
            room_id: room.room_id,
            name: room.name || "",
            status: room.status || "active",
            member_count: room.member_count || 0,
            max_members: room.max_members || 0,
            visibility: room.visibility || "private",
            created_at: room.created_at || 0,
            is_auto_join: Map.get(room, :is_auto_join, false)
          }
        }

      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{req.room_id}"

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "get_admin_room failed: #{inspect(reason)}"
    end
  end

  # ─── ListAdminRoomMembers (Story 9.18) ───────────────────────────────────────
  #
  # Returns all current members (left_at IS NULL) for a room, ordered by joined_at ASC.
  # display_name is decrypted via the same decrypt_display_name/1 helper used by
  # list_admin_users/get_admin_user. On decryption failure, display_name = "" (non-fatal).
  # Empty room returns empty members list (not an error).

  def list_admin_room_members(%Core.ListAdminRoomMembersRequest{} = req, _stream) do
    case admin_db_module().list_room_members(req.room_id) do
      {:ok, members} ->
        proto_members =
          Enum.map(members, fn member ->
            %Core.AdminRoomMemberProto{
              user_id: member.user_id,
              display_name: decrypt_display_name(member),
              joined_at: member.joined_at || 0
            }
          end)

        %Core.ListAdminRoomMembersResponse{members: proto_members}

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "list_admin_room_members failed: #{inspect(reason)}"
    end
  end

  # ─── GetServerConfig ─────────────────────────────────────────────────────────
  #
  # Security invariant: oidc_client_secret MUST NOT be returned in the response.
  # It is AES-256-GCM encrypted in the DB and only the Go Gateway has the key.
  # The admin_db_module().get_server_config/0 already filters it out at DB level.

  def get_server_config(%Core.GetServerConfigRequest{} = _req, _stream) do
    case admin_db_module().get_server_config() do
      {:ok, config} ->
        %Core.GetServerConfigResponse{
          config: %Core.ServerConfigProto{
            instance_name: Map.get(config, "instance_name", ""),
            oidc_issuer: Map.get(config, "oidc_issuer", ""),
            oidc_client_id: Map.get(config, "oidc_client_id", ""),
            room_default_max_members: parse_int_config(config, "room_default_max_members"),
            room_default_visibility: Map.get(config, "room_default_visibility", ""),
            audit_log_retention_days: parse_int_config(config, "audit_log_retention_days")
          }
        }

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "get_server_config failed: #{inspect(reason)}"
    end
  end

  # ─── UpdateServerConfig ──────────────────────────────────────────────────────
  #
  # Upserts server_config table rows for provided fields.
  # Empty string / zero fields are not updated (callers omit fields they don't change).
  # NOTE: The Gateway calls CoreClient.InvalidateAllAdminSessions after OIDC config changes
  # (Story 6.10) — Core only persists the data here.

  def update_server_config(%Core.UpdateServerConfigRequest{} = req, stream) do
    {actor_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    # Story 14.1a: enforce claim lock — matrix_user_id_claim cannot be changed
    # after bootstrap_completed is set in server_config.
    if req.matrix_user_id_claim != "" do
      {:ok, config} = admin_db_module().get_server_config()

      if Map.get(config, "bootstrap_completed") != nil do
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.failed_precondition(),
          message: "matrix_user_id_claim cannot be changed after bootstrap"
      end
    end

    changes =
      []
      |> maybe_add_change("instance_name", req.instance_name)
      |> maybe_add_change("oidc_issuer", req.oidc_issuer)
      |> maybe_add_change("oidc_client_id", req.oidc_client_id)
      |> maybe_add_int_change("room_default_max_members", req.room_default_max_members)
      |> maybe_add_change("room_default_visibility", req.room_default_visibility)
      |> maybe_add_int_change("audit_log_retention_days", req.audit_log_retention_days)
      |> maybe_add_change("oidc_user_id_claim", req.matrix_user_id_claim)
      # Story 14-2a: oidc_directory_endpoint is a string — safe to use maybe_add_change
      # (empty string = "do not update" convention). oidc_directory_enabled is a bool
      # proto3 field — cannot distinguish false-from-unset, so it is persisted via the
      # direct DB upsert path in the Admin PATCH handler. The Core.* field exists for
      # completeness; the Core path does not process bool fields to avoid inadvertently
      # overwriting the stored value with the default (false) on unrelated calls.
      |> maybe_add_change("oidc_directory_endpoint", req.oidc_directory_endpoint)

    if changes == [] do
      %Core.UpdateServerConfigResponse{ok: true}
    else
      case admin_db_module().upsert_server_config(Map.new(changes)) do
        :ok ->
          # Audit log for server config update (Story 9.4 — mirrors deactivate_user pattern from Story 9.2).
          audit_writer_module().log(
            actor_id,
            "server_config_updated",
            "server_config",
            "config",
            %{changed_keys: Map.keys(Map.new(changes))},
            "success"
          )

          %Core.UpdateServerConfigResponse{ok: true}

        {:error, reason} ->
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.internal(),
            message: "update_server_config failed: #{inspect(reason)}"
      end
    end
  end

  # ─── Private helpers for admin handlers ──────────────────────────────────────

  # Decrypts display_name from the user map returned by admin_db_module.
  #
  # Two supported layouts:
  #   - Test fakes (FakeAdminDB): return %{display_name: "Alice"} (already plaintext).
  #   - Real DB (Nebu.Admin.DB): returns %{display_name_encrypted: <<...>>,
  #     display_name_nonce: <<...>>}; decrypted via Nebu.Matrix.Signature.decrypt_operational_pii/3.
  #
  # Falls back to empty string on decryption failure or missing data.
  defp decrypt_display_name(%{display_name: dn}) when is_binary(dn) do
    dn
  end

  defp decrypt_display_name(%{display_name_encrypted: enc, display_name_nonce: nonce})
       when is_binary(enc) and is_binary(nonce) do
    server_key = Application.get_env(:signature, :pii_encryption_key)

    case Nebu.Matrix.Signature.decrypt_operational_pii(enc, nonce, server_key) do
      {:ok, plaintext} -> plaintext
      {:error, _} -> ""
    end
  end

  defp decrypt_display_name(_), do: ""

  # Masks email to "u***@domain" format.
  #
  # Two supported layouts:
  #   - Test fakes (FakeAdminDB): return %{email_masked: "a***@example.com"} (pre-masked).
  #   - Real DB (Nebu.Admin.DB): returns %{email_encrypted: <<...>>, email_nonce: <<...>>,
  #     email_ephemeral_pub: <<...>>}; decrypted via Nebu.Matrix.Signature.decrypt_sensitive_pii/4.
  #
  # Email masking pattern: first char of local part + "***" + "@" + domain.
  defp mask_email(%{email_masked: masked}) when is_binary(masked) and byte_size(masked) > 0 do
    masked
  end

  defp mask_email(%{email_encrypted: enc, email_nonce: nonce, email_ephemeral_pub: ephemeral_pub})
       when is_binary(enc) and is_binary(nonce) and is_binary(ephemeral_pub) do
    {_pub, priv} = :persistent_term.get(:nebu_encryption_key, {nil, nil})

    case Nebu.Matrix.Signature.decrypt_sensitive_pii(enc, ephemeral_pub, nonce, priv) do
      {:ok, email} -> do_mask_email(email)
      {:error, _} -> "***@unknown"
    end
  end

  defp mask_email(_), do: "***@unknown"

  defp do_mask_email(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] when byte_size(local) > 0 ->
        first = String.first(local)
        "#{first}***@#{domain}"

      _ ->
        "***@unknown"
    end
  end

  defp parse_int_config(config, key) do
    case Map.get(config, key) do
      nil -> 0
      val when is_integer(val) -> val
      val when is_binary(val) -> String.to_integer(val)
      _ -> 0
    end
  end

  defp maybe_add_change(acc, _key, ""), do: acc
  defp maybe_add_change(acc, key, value) when is_binary(value), do: [{key, value} | acc]
  defp maybe_add_change(acc, _key, _), do: acc

  defp maybe_add_int_change(acc, _key, 0), do: acc
  defp maybe_add_int_change(acc, key, value) when is_integer(value) and value > 0, do: [{key, value} | acc]
  defp maybe_add_int_change(acc, _key, _), do: acc

  # ─── Private helpers ──────────────────────────────────────────────────────────

  # Emits a signed m.room.member leave event into the events table and broadcasts
  # it to any :pg subscribers of the room. Since story moderation-routes-atomic-ban (D8) ONLY for a decline in a room whose
  # process cannot be started (an archived room, decline_in_room!/2); every other decline is written by the room process.
  # Called when an invite is declined via POST /rooms/{roomId}/leave so that:
  #   1. fetch_delta_rooms can detect the decline even across sync-cycle boundaries
  #      (race-proof — event persisted in DB, not just a volatile :pg message).
  #   2. Any sync task subscribed to the room's :pg group wakes up immediately.
  #
  # Story member-event-prev-content (D4 (c)): the event is stamped max(now, latest member event ts + 1), so a decline right
  # after an invitation that createRoom stamped slightly AHEAD of the clock is still strictly newer than the invite (the
  # strict slot order the predecessor lookup relies on).
  defp emit_decline_event(room_id, user_id) do
    event_map = %{
      "room_id"          => room_id,
      "type"             => "m.room.member",
      "state_key"        => user_id,
      "sender"           => user_id,
      "content"          => %{"membership" => "leave"},
      "origin_server_ts" => member_event_stamp(room_id, user_id)
    }
    event_id      = Nebu.Matrix.EventId.generate(event_map)
    event_with_id = Map.put(event_map, "event_id", event_id)
    {_pub, priv}  = :persistent_term.get(:nebu_signing_key)
    event_json    = Nebu.Matrix.CanonicalJson.encode!(event_map)
    signature     = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
    sig_b64       = Base.encode64(signature)
    signed        = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})

    case messages_db_module().insert_event(signed) do
      :ok ->
        Enum.each(:pg.get_members("room:#{room_id}"), &send(&1, {:new_event, signed}))

      {:error, reason} ->
        require Logger
        Logger.warning("emit_decline_event: failed for #{user_id} in #{room_id}: #{inspect(reason)}")
    end
  end

  # Story member-event-prev-content (D4): the `origin_server_ts` of a member event written for the user's own transition:
  # max(now, ts of the user's latest member event in the room + 1), from ONE indexed read through `rooms_db_module()`. A db
  # module without `latest_member_event/2` (unit fakes), a failed or empty read stamps the clock (`now`): the write is never
  # refused because of this read.
  defp member_event_stamp(room_id, user_id) do
    now = Nebu.DB.Helpers.now_ms()
    mod = rooms_db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :latest_member_event, 2) do
      try do
        case mod.latest_member_event(room_id, user_id) do
          {:ok, %{origin_server_ts: ts}} when is_integer(ts) -> max(now, ts + 1)
          _ -> now
        end
      rescue
        _ -> now
      catch
        _, _ -> now
      end
    else
      now
    end
  end

  # ─── UpgradeRoom — Story 9.8: atomic room version upgrade ─────────────────────
  #
  # Sequence (all in one call, no extra GenServer abstraction needed):
  #   1. Verify old room exists, the requester is a member whose level reaches the upgrade level (the tombstone level with a floor
  #      of 100, story state-writer-redaction D11) and not banned; the cheap ban read (cap, carry pre-check).
  #   2. The m.room.tombstone in the old room, decided and written by its room process (Room.Server.write_state/5, mode :tombstone).
  #   3. Freeze the old room (archive + stop), then the authoritative read of its bans and members (story
  #      moderation-routes-atomic-ban, review cycle 2).
  #   4. Emit m.room.create in new room WITH predecessor (old_room_id + tombstone_event_id), join the requester as creator, set
  #      creator power levels, carry the bans.
  #   5. Copy state events from old room (excluding create, tombstone, aliases, member).
  #      Emit m.room.join_rules LAST per Matrix spec.
  #   6. Invite the old members (except requester, who is already joined, and the banned users).
  #   7. Write audit log: room_upgraded.
  #
  # Security: the power level check (step 1) is performed on the snapshot BEFORE any state mutation, and AUTHORITATIVELY by the
  # old room's process at the tombstone write (story state-writer-redaction, D11: Room.Server.write_state/5, mode :tombstone).
  # The events of the NEW room (create, the state copy) are emitted via the private emit_state_event/5 helper (same signing
  # pattern as create_room/2): a brand-new room no other client can reach yet.

  # the answers of write_state/5 after which nothing was written (D11): every other answer (`:room_unavailable`) may hide a commit
  @definite_tombstone_refusals [:insufficient_level, :sender_not_joined, :foreign_user_key, :room_archived, :write_failed, :event_too_large, :unsupported_db_module]

  def upgrade_room(request, stream) do
    {requester_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)
    old_room_id  = request.old_room_id
    new_version  = request.new_version

    # Story create-room-input-validation (D1, Oracle): `new_version` is REQUIRED and Nebu supports exactly one version
    # (Nebu.Matrix.RoomVersions). An empty / absent / unsupported value is 400 M_UNSUPPORTED_ROOM_VERSION, decided BEFORE the
    # room lookup, the power check and any write: nothing is tombstoned, no new room is started. (The router rejects an
    # absent / null / non-string value earlier with M_MISSING_PARAM / M_BAD_JSON; the former "" -> "10" fallback is gone.)
    unless Nebu.Matrix.RoomVersions.supported?(new_version) do
      reject!("M_UNSUPPORTED_ROOM_VERSION", "This server does not support the requested room version")
    end

    # 1. Verify old room exists and the requester reaches the upgrade level (PowerLevels.upgrade_level/1).
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(old_room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{old_room_id}"

      {:ok, _pid} ->
        old_state =
          try do
            room_registry_module().get_state(old_room_id)
          catch
            :exit, {:noproc, _} ->
              raise Nebu.Matrix.Error,
                status: Nebu.Matrix.Status.not_found(),
                message: "room not found: #{old_room_id}"
          end

        # story power-levels-enforcement (D4): the NORMALISED level (a stored string "100" never passes `>= 100`)
        requester_level = Nebu.Matrix.Room.PowerLevels.get_user_level(old_state.power_levels, requester_id)

        # story state-writer-redaction (D11, follow-up `fx`): the permission is the tombstone level with a floor of 100 (a Nebu
        # restriction: the upgrader must be able to carry the levels, whose default level is 100); decided here on the snapshot and
        # AUTHORITATIVELY by the old room's process at the tombstone write
        if requester_level < Nebu.Matrix.Room.PowerLevels.upgrade_level(old_state.power_levels) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            errcode: "M_FORBIDDEN",
            message: "You do not have a high enough power level to upgrade this room"
        end

        # Story moderation-routes-atomic-ban, review cycle 3 (Kassandra L-1, follow-up `fu`): the level alone does not authorise the
        # tombstone and the freeze; a kicked, banned or never-joined holder of level 100 is refused before anything is written
        unless MapSet.member?(old_state.members, requester_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            errcode: "M_FORBIDDEN",
            message: "You are not a member of this room"
        end

        # Story moderation-routes-atomic-ban (D11, follow-up `ew`): a cheap read of the bans BEFORE anything is written, for the cap
        # (review cycle 1, Kassandra L-3), the requester's own ban and a pre-check that every ban can be carried (review cycle 3), and
        # to fail closed early (a failing read: nothing tombstoned, no new room). The AUTHORITATIVE read follows the freeze (step 3b).
        precheck_bans!(banned_members!(old_room_id), requester_id)

        # Story power-levels-enforcement (D8, follow-up `fr`): the levels are carried as a v10 change by the upgrader, so no level of
        # the old room may exceed his own (a Nebu choice: refused, no temporary boost); checked on the snapshot BEFORE the tombstone
        # (nothing written) and again on the authoritative content after the freeze (step 3b).
        precheck_levels!(old_state.power_levels, requester_level)

        # Story membership-state-model (D9, MINOR-7): the `is_direct` flags of the invitations (a pure read of the members' OWN
        # invites, which predate their join) BEFORE anything is written: a failing read writes nothing.
        direct_invitees = direct_invitees!(old_room_id)

        # 2. Create new room and set up creator membership + power levels.
        # MAJOR-3 fix: m.room.create MUST be the first event in any room per Matrix spec.
        # We therefore emit m.room.create BEFORE joining the creator so that the
        # m.room.create event has a lower origin_server_ts than the m.room.member event.
        new_room_id = generate_room_id()

        case Nebu.Matrix.Room.RoomSupervisor.start_room(new_room_id) do
          {:ok, _new_pid} ->
            try do
              # 3. The tombstone in the OLD room, decided and written by its room process (story state-writer-redaction, D11):
              #    membership and the upgrade level again (a demotion or kick committed after the snapshot refuses it), stamped
              #    after the latest tombstone-slot event, archived check and insert in one transaction.
              tombstone_content = %{
                "body"             => "This room has been replaced",
                "replacement_room" => new_room_id
              }

              tombstone_event_id =
                case write_tombstone(old_room_id, requester_id, tombstone_content) do
                  {:ok, event_id} ->
                    event_id

                  {:error, reason} ->
                    # security cycle 1 (Kassandra #3, review M2): only a DEFINITE refusal wrote nothing to the old room, so only then is
                    # the started new room (process and `rooms` row) cleaned up. On `:room_unavailable` (the call timed out) the
                    # tombstone MAY still commit: the new room is KEPT (an orphan without join rule or invitation, nobody can join it),
                    # the answer is 503 "may or may not have been applied" and the client retries /upgrade.
                    if reason in @definite_tombstone_refusals, do: cleanup_orphan_room(new_room_id)
                    upgrade_tombstone_refusal!(old_room_id, reason)
                end

              # 3b. Review cycle 2 (Kassandra L-5): FREEZE the old room right after the tombstone: archived (`rooms.status`, which
              #     `Room.DB.apply_member_change/4` checks for every moderation, invite-event and decline write) and its process stopped, so no join,
              #     invite, decline or moderation can change it any more. Then the ONE authoritative read of its bans and members:
              #     every ban, also one committed during this upgrade, is carried, and no banned user is invited. From here on a
              #     failure is a 500 that leaves the old room archived WITH its tombstone and the new room an orphan without a join
              #     rule or invitation (nobody can join it): to continue, the owner unarchives the old room in the Admin UI and runs
              #     /upgrade again; the orphan room has to be cleaned up (Admin archive).
              freeze_old_room!(old_room_id)
              bans = banned_members!(old_room_id)
              # review cycle 3 (Kassandra I-2): the cap and the carry pre-check again on the authoritative set, before the new room
              # is filled (the old room is frozen: a refusal here leaves it archived, see the scope doc)
              precheck_bans!(bans, requester_id)
              members = members_after_freeze!(old_room_id, old_state)

              # story power-levels-enforcement (D8): the AUTHORITATIVE levels of the frozen old room (the column, also a change
              # committed between the snapshot and the freeze) and the level check again, before the new room is filled: a
              # level above the upgrader's is a 500 here (the post-freeze failure semantics); nothing above it is ever carried
              carried_levels = authoritative_levels!(old_room_id)
              # review cycle 0 (Kassandra L-1): the requester's level is decided AGAIN on the authoritative levels (a demotion in
              # the gap between the snapshot and the freeze): it must still reach 100 and no level may exceed it
              upgrader_level = postcheck_levels!(carried_levels, requester_id)

              # 4. Emit m.room.create in new room WITH predecessor FIRST (before join).
              # MAJOR-3 fix: create event must be the first event written to the new room.
              create_content = %{
                "creator"      => requester_id,
                "room_version" => new_version,
                "predecessor"  => %{
                  "room_id"  => old_room_id,
                  "event_id" => tombstone_event_id
                }
              }
              case emit_state_event(new_room_id, requester_id, "m.room.create", "", create_content) do
                {:ok, _} -> :ok
                {:error, reason} ->
                  raise Nebu.Matrix.Error,
                    status: Nebu.Matrix.Status.internal(),
                    message: "Failed to emit m.room.create in new room: #{inspect(reason)}"
              end

              # Now join the creator and set power levels (m.room.member comes AFTER m.room.create).
              case Nebu.Matrix.Room.Server.join(new_room_id, requester_id) do
                :ok -> :ok
                {:error, reason} ->
                  raise Nebu.Matrix.Error,
                    status: Nebu.Matrix.Status.internal(),
                    message: "Failed to join requester to new room: #{inspect(reason)}"
              end

              # D8 (1): the initial levels are the defaults with the upgrader at his authoritative old level L (>= 100, step 3b)
              default_pl = Nebu.Matrix.Room.Server.default_power_levels()
              creator_pl = put_in(default_pl, ["users", requester_id], upgrader_level)

              case Nebu.Matrix.Room.Server.set_power_levels(new_room_id, requester_id, creator_pl) do
                :ok -> :ok
                {:error, reason} ->
                  raise Nebu.Matrix.Error,
                    status: Nebu.Matrix.Status.internal(),
                    message: "Failed to set power levels on new room: #{inspect(reason)}"
              end

              # 4b. D11: the bans (the authoritative set of step 3b) are re-issued as NEW ban events in the upgrader's own name (joined
              #     at 100, every other user at the default 0: always strictly lower), FIRST: until the join rule is copied the new room
              #     has the invite policy and nobody is invited, so nobody can join in between. Not rate-charged, not audited one by one
              #     (the `room_upgraded` row counts them). A deliberate deviation from the spec's SHOULD NOT transfer membership events
              #     (impersonation over federation; Nebu impersonates nobody): Synapse parity. A failing carry fails the upgrade before
              #     any invitation exists.
              carry_bans!(new_room_id, requester_id, bans)

              # 4c. Story power-levels-enforcement (D8): the old room's levels AFTER the bans (the project's own Oracle note on `fr`:
              #     a copied `users` map must not raise a banned user to the upgrader's level before his ban), as a v10 CHANGE by the
              #     upgrader through the ONE power-level writer (mode: :client); a refusal fails the upgrade (500) before the join
              #     rule and the invitations exist. The old room's levels are NOT lowered: it is archived and stopped.
              carry_power_levels!(new_room_id, requester_id, carried_levels)

              # 5. Copy state events from old room (spec-mandated order).
              copy_state_events(old_room_id, new_room_id, requester_id)

              # 6. Invite the members of the frozen old room (except requester — already joined; a banned user never: ban -> invite
              #    must never happen). Story membership-state-model (D9): the row AND a real invite event in the upgrader's name,
              #    `is_direct` from the member's own old invite (read before the tombstone); best effort per member.
              banned_ids = MapSet.new(bans, & &1.user_id)
              old_members = members |> MapSet.delete(requester_id) |> MapSet.difference(banned_ids)

              invite_upgraded_members(new_room_id, requester_id, Enum.sort(old_members), direct_invitees)

              # 8. Audit log — success.
              audit_writer_module().log(
                requester_id,
                "room_upgraded",
                "room",
                old_room_id,
                %{"new_room_id" => new_room_id, "new_version" => new_version, "bans_carried" => length(bans), "power_levels_carried" => true},
                "success"
              )

              Process.delete({:nebu_upgrade_frozen, old_room_id})

              %Core.UpgradeRoomResponse{new_room_id: new_room_id}
            rescue
              e ->
                # Audit log — partial failure (tombstone may already be in old room).
                # Wrap in its own rescue so an audit-writer outage never masks the original error.
                error_msg = Exception.message(e)
                # review cycle 3 (Kassandra I-4): whether the old room was archived before the failure
                frozen? = Process.delete({:nebu_upgrade_frozen, old_room_id}) == true

                try do
                  audit_writer_module().log(
                    requester_id,
                    "room_upgraded",
                    "room",
                    old_room_id,
                    %{"new_room_id" => new_room_id, "new_version" => new_version, "error" => error_msg, "old_room_archived" => frozen?},
                    "failure"
                  )
                rescue
                  audit_err ->
                    Logger.error(
                      "upgrade_room: failure audit log failed for #{old_room_id}: #{inspect(audit_err)}"
                    )
                end
                reraise e, __STACKTRACE__
            end

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "Failed to start new room: #{inspect(reason)}"
        end
    end
  end

  # ─── the invitations of an upgrade (story membership-state-model, D9) ─────────────────────────────────────────────────

  # The members whose OWN latest invite in the old room carried `is_direct: true` (rooms db seam); an injected fake without the read
  # has none; a failing read is a 500 before the tombstone: nothing is written (MINOR-7).
  defp direct_invitees!(old_room_id) do
    mod = rooms_db_module()

    result =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :direct_invitees, 1) do
        try do
          mod.direct_invitees(old_room_id)
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      else
        {:ok, MapSet.new()}
      end

    case result do
      {:ok, %MapSet{} = direct} ->
        direct

      other ->
        reason = with({:error, reason} <- other, do: reason)
        Logger.error("upgrade_room: failed to read the direct invitations of #{old_room_id} (#{db_error_class(reason)})")
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: the invitations of the room could not be prepared"
    end
  end

  # The members in a fixed order; a room process that does not answer (`:room_unavailable`) will not answer the next member either:
  # the loop stops there with ONE value-free WARNING naming the number skipped (MINOR-6); every other failure is per member.
  defp invite_upgraded_members(new_room_id, requester_id, members, direct_invitees) do
    total = length(members)

    members
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {member_id, done}, :ok ->
      case invite_upgraded_member(new_room_id, requester_id, member_id, direct_invitees) do
        :room_unavailable ->
          Logger.warning(
            "upgrade_room: the room process of #{new_room_id} did not answer an invite event (:room_unavailable), the invitation is " <>
              "taken back and #{total - done} further invitation(s) skipped"
          )

          {:halt, :ok}

        _invited_or_failed ->
          {:cont, :ok}
      end
    end)
  end

  # One old member: the row (plain insert, uncapped, `fi`), the invite EVENT through the new room's process (`write_invite/5`, the
  # upgrader at his carried level), then the unforget and the cluster-wide wake. A refused / failed event write rejects the row
  # again and logs ONE value-free WARNING; the upgrade goes on.
  defp invite_upgraded_member(new_room_id, requester_id, member_id, direct_invitees) do
    case db_module_invite().insert_invitation(new_room_id, requester_id, member_id) do
      :ok ->
        content =
          if MapSet.member?(direct_invitees, member_id),
            do: %{"membership" => "invite", "is_direct" => true},
            else: %{"membership" => "invite"}

        case write_invite_event(new_room_id, requester_id, member_id, content, 0) do
          {:ok, _event_id, _ts} ->
            unforget_room(member_id, new_room_id)
            wake_invitee(member_id, new_room_id)

          {:error, :room_unavailable} ->
            # the caller logs ONE line and stops the loop (MINOR-6)
            Logger.debug("upgrade_room: an invite event of #{new_room_id} was not written, the room did not answer")
            _ = take_back_upgrade_invitation(new_room_id, member_id)
            :room_unavailable

          {:error, reason} ->
            if unique_violation?(reason) and upgraded_member_invited?(new_room_id, member_id) do
              # an identical concurrent invite (Element's upgrade dialog) wrote the very same event: the member is invited
              wake_invitee(member_id, new_room_id)
            else
              reject_upgrade_invitation(new_room_id, member_id, reason)
            end
        end

      {:error, reason} ->
        Logger.warning("upgrade_room: an invitation row of #{new_room_id} was not written (#{db_error_class(reason)})")
    end
  end

  # the latest membership of the member in the new room is `invite` (never raises: an unreadable state is "not invited")
  defp upgraded_member_invited?(new_room_id, member_id) do
    match?({:ok, "invite"}, rooms_db_module().get_member_membership(new_room_id, member_id))
  rescue
    _e -> false
  catch
    _kind, _reason -> false
  end

  # the compensation of a refused / failed invite event: the row this call created is rejected again (a failed reject leaves a
  # half invitation: the ERROR of the invite path)
  defp reject_upgrade_invitation(new_room_id, member_id, reason) do
    Logger.warning("upgrade_room: an invite event of #{new_room_id} was not written, the invitation is taken back (#{db_error_class(reason)})")
    take_back_upgrade_invitation(new_room_id, member_id)
  end

  defp take_back_upgrade_invitation(new_room_id, member_id) do
    case try_reject_invitation(new_room_id, member_id) do
      :ok -> :ok
      {:error, reject_reason} -> log_half_invitation(new_room_id, reject_reason)
    end
  end

  # story state-writer-redaction (D11): the tombstone is written by the room process of the OLD room at the tombstone level
  defp write_tombstone(old_room_id, requester_id, content) do
    room_registry_module().write_state(old_room_id, requester_id, {"m.room.tombstone", ""}, content, mode: :tombstone)
  catch
    :exit, _reason -> {:error, :room_unavailable}
  end

  defp upgrade_tombstone_refusal!(old_room_id, reason) do
    case reason do
      :insufficient_level ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.permission_denied(),
          errcode: "M_FORBIDDEN",
          message: "You do not have a high enough power level to upgrade this room"

      _other ->
        state_write_refusal!(old_room_id, reason)
    end
  end

  # ─── the power levels of an upgrade (story power-levels-enforcement, D8) ─────────────────────────────────────────────

  @upgrade_levels_above_text "The room has power levels above yours: a user with the highest level must upgrade it"

  # every level of the (normalised) content must be at most the upgrader's own; refused BEFORE the tombstone (403)
  defp precheck_levels!(levels, requester_level) do
    if Enum.any?(Nebu.Matrix.Room.PowerLevels.all_levels(levels), &(&1 > requester_level)) do
      raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: @upgrade_levels_above_text
    end

    :ok
  end

  # after the freeze, on the authoritative content (a change committed in the gap): the requester's level is read from it again
  # (Kassandra L-1: a demoted upgrader is refused) and must reach 100, and no level may exceed it; a refusal is a 500 with a fixed
  # text (the post-freeze failure semantics, MINOR-10: the old room stays tombstoned and archived). Answers the level.
  defp postcheck_levels!(levels, requester_id) do
    level = Nebu.Matrix.Room.PowerLevels.get_user_level(levels, requester_id)

    if level < 100 or Enum.any?(Nebu.Matrix.Room.PowerLevels.all_levels(levels), &(&1 > level)) do
      raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: the power levels of the room no longer allow this upgrade"
    end

    level
  end

  # the stored levels of the frozen old room (`rooms.power_levels_json`); a failing read fails the upgrade (500), a content that
  # is not a JSON object reads as %{} (as in the room process)
  defp authoritative_levels!(old_room_id) do
    case rooms_db_module().get_power_levels_json(old_room_id) do
      {:ok, json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> map
          _other -> %{}
        end

      {:ok, nil} ->
        %{}

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("upgrade_room: failed to read the power levels of #{old_room_id} (#{db_error_class(reason)})")
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: the power levels cannot be read"
    end
  end

  # D8 (3): the copy, normalised to its strictly valid part (legacy values that are not v10-valid are not carried)
  defp carry_power_levels!(new_room_id, requester_id, levels) do
    # fix cycle 2 (Kassandra D-L1): the upgrader's own relaxed-grammar id (a port, a long id) is kept, so he keeps his level
    content = Nebu.Matrix.Room.PowerLevels.valid_subset(levels, [requester_id])

    case change_power_levels_as_client(new_room_id, requester_id, content) do
      {:ok, _event_id, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.error("upgrade_room: failed to carry the power levels into #{new_room_id} (#{db_error_class(reason)})")
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: the power levels cannot be carried"
    end
  end

  # Review cycle 1 (Kassandra L-3, review M4): at most this many bans are carried (one room-process transaction each, inside ONE
  # request); a room with more is refused BEFORE anything is written (`upgrade_max_carried_bans`, a seam for the tests; anything but
  # a positive integer there is ignored)
  @upgrade_max_carried_bans 10_000

  defp upgrade_max_carried_bans do
    case Application.get_env(:nebu, :upgrade_max_carried_bans) do
      n when is_integer(n) and n > 0 -> n
      _ -> @upgrade_max_carried_bans
    end
  end

  # ─── Configurable room stop for testability (story moderation-routes-atomic-ban, review cycle 3) ─────────────────────
  # Override via Application.put_env(:event_dispatcher, :room_terminate_fun, fun) in tests: `fun.(pid) :: :ok | {:error, term()}`.
  defp room_terminate_fun do
    Application.get_env(:event_dispatcher, :room_terminate_fun, &Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, &1))
  end

  # Review cycle 1 / 3 (Kassandra L-3 / L-1 / I-2): the bans an upgrade must carry: at most the cap, never the requester's own ban, and
  # every one carriable (the key limits of a member event; the upgrader is the only user above the default level in the new room).
  # Refused with 403 BEFORE the tombstone (the cheap read) and again on the authoritative read after the freeze.
  defp precheck_bans!(bans, requester_id) do
    cond do
      length(bans) > upgrade_max_carried_bans() ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: "The room has too many bans to be upgraded"

      Enum.any?(bans, &(&1.user_id == requester_id)) ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), errcode: "M_FORBIDDEN", message: "You are banned from this room"

      not Enum.all?(bans, &(Nebu.Matrix.EventSize.check_keys("m.room.member", &1.user_id, requester_id) == :ok)) ->
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: a ban of the room cannot be carried"

      true ->
        :ok
    end
  end

  # Review cycle 2 (Kassandra L-5): archive the old room and stop its process; both are FATAL. A stop that fails is re-checked:
  # a process that is still registered fails the upgrade (500, value-free log), never a warning only (an archived room process that
  # keeps running is refused for every moderation, invite-event and decline write anyway, `apply_member_change/4`).
  defp freeze_old_room!(old_room_id) do
    case admin_db_module().archive_room_atomic(old_room_id) do
      :ok ->
        :ok

      # idempotent: the room row was removed by a concurrent admin operation
      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.error("upgrade_room: failed to archive the old room #{old_room_id} (#{db_error_class(reason)})")
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: the old room could not be archived"
    end

    # review cycle 3 (Kassandra I-4): from here on a failure leaves the old room archived (the failure audit row says so)
    Process.put({:nebu_upgrade_frozen, old_room_id}, true)

    with {:ok, old_pid} <- Nebu.Matrix.Room.RoomSupervisor.lookup_room(old_room_id),
         {:error, _reason} <- room_terminate_fun().(old_pid),
         {:ok, still_running} <- Nebu.Matrix.Room.RoomSupervisor.lookup_room(old_room_id),
         # review cycle 3 (INFO-1): a dead LOCAL pid that is still registered for a moment counts as stopped
         false <- node(still_running) == node() and not Process.alive?(still_running) do
      Logger.error("upgrade_room: the process of the old room #{old_room_id} could not be stopped")
      raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: the old room could not be stopped"
    else
      _stopped_or_not_running -> :ok
    end
  end

  # Review cycle 2 (Kassandra L-5): the members to invite, read from the FROZEN old room (`rooms_db_module().load_members/1`, its
  # active member rows); a db module without the read (an injected fake) keeps the snapshot of the power check. A failing read is a
  # 500 (the upgrade must not silently invite nobody).
  defp members_after_freeze!(old_room_id, old_state) do
    mod = rooms_db_module()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :load_members, 1) do
      case mod.load_members(old_room_id) do
        {:ok, user_ids, _created_at, _levels, _identity} ->
          MapSet.new(user_ids)

        {:ok, user_ids, _created_at, _levels} ->
          MapSet.new(user_ids)

        other ->
          reason = with {:error, reason} <- other, do: reason
          Logger.error("upgrade_room: failed to read the members of the old room #{old_room_id} (#{db_error_class(reason)})")
          raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: the members of the room could not be read"
      end
    else
      old_state.members
    end
  end

  # D11: the users banned in the old room, ONE read; a db module without the read (an injected fake of the older upgrade suites)
  # has no bans. A failing read is a 500 (fail closed: an upgrade must never silently drop the bans).
  defp banned_members!(room_id) do
    mod = rooms_db_module()

    result =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :banned_members, 1) do
        try do
          mod.banned_members(room_id)
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      else
        {:ok, []}
      end

    case result do
      {:ok, bans} when is_list(bans) ->
        bans

      other ->
        reason = with {:error, reason} <- other, do: reason
        Logger.error("upgrade_room: failed to read the bans of #{room_id} (#{db_error_class(reason)})")
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: the bans of the room could not be read"
    end
  end

  # D11: one Room.Server.moderate/6 per banned user, the reason copied only when it passes the D10 rules; any failure fails the
  # upgrade (500) before the join rule is copied and before any invitation exists: the new room is an orphan nobody can join, the
  # old room stays archived with its tombstone (to continue: unarchive it in the Admin UI, which restarts its process, and run
  # /upgrade again; the orphan new room has to be cleaned up)
  defp carry_bans!(new_room_id, requester_id, bans) do
    Enum.each(bans, fn %{user_id: user_id, reason: reason} ->
      reason = if valid_moderation_reason?(reason), do: reason

      result =
        try do
          Nebu.Matrix.Room.Server.moderate(new_room_id, :ban, requester_id, user_id, reason)
        catch
          :exit, _reason -> {:error, :room_unavailable}
        end

      with {:error, refusal} <- result do
        Logger.error("upgrade_room: a ban could not be carried into #{new_room_id} (#{inspect(refusal)})")
        raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "upgrade failed: a ban could not be carried into the new room"
      end
    end)
  end

  # ─── SearchMessages — Story 11.3 ────────────────────────────────────────────
  #
  # Full-text search over rooms where the authenticated user is an active member.
  # Delegates to Nebu.Matrix.Search.DB.search_messages/5 which enforces membership at SQL layer.
  #
  # SECURITY: user_id MUST come from request metadata (x-user-id set by OIDC plug).
  # The request.user_id field is IGNORED — reading it would bypass membership enforcement
  # and allow a malicious authenticated user to search any other user's rooms (IDOR).
  # See Security Trust Boundary section in Story 11.3 for full details.

  def search_messages(request, stream) do
    # SECURITY: user_id MUST come from request metadata, never from request.user_id
    {user_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    if is_nil(user_id) or user_id == "" do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.unauthenticated(),
        message: "missing x-user-id metadata"
    end

    search_term = request.search_term

    # Kassandra Finding #4: clamp limit to prevent DOS / over-large queries.
    # limit=0 defaults to 10; clamped to 1–100.
    raw_limit = if request.limit == 0, do: 10, else: request.limit
    limit = min(max(raw_limit, 1), 100)

    # Decode next_batch pagination token (base64-encoded integer offset).
    # Invalid or missing token → default offset 0.
    offset =
      case Base.decode64(request.next_batch || "") do
        {:ok, bin} ->
          case Integer.parse(bin) do
            {n, ""} when n >= 0 -> min(n, 10_000)
            _ -> 0
          end
        :error -> 0
      end

    # room_filter: empty list = no filter; non-empty = intersect with membership at SQL layer.
    room_filter = request.room_filter || []

    # Delegate to Nebu.Matrix.Search.DB — user_id enforces membership scoping at SQL layer.
    # security cycle 1 (HIGH #1 (d)): under the request statement timeout (a timeout is the generic 500 below)
    case with_read_timeout(search_db_module(), fn -> search_db_module().search_messages(user_id, search_term, limit, offset, room_filter) end) do
      {:ok, rows} ->
        results =
          Enum.map(rows, fn row ->
            event_id = Map.get(row, "event_id", "")
            room_id  = Map.get(row, "room_id", "")
            sender   = Map.get(row, "sender", "")

            # Build event JSON from row fields.
            content =
              case Map.get(row, "content") do
                c when is_map(c) -> c
                c when is_binary(c) ->
                  case Jason.decode(c) do
                    {:ok, m} -> m
                    _ -> %{}
                  end
                _ -> %{}
              end

            event_json =
              Jason.encode!(%{
                "event_id"         => event_id,
                "room_id"          => room_id,
                "sender"           => sender,
                "type"             => Map.get(row, "event_type", "m.room.message"),
                "content"          => content,
                "origin_server_ts" => Map.get(row, "origin_server_ts", 0)
              })

            # rank from ts_rank_cd is a float4 (native Elixir float from Ecto)
            rank_val = Map.get(row, "rank", 0.0)
            rank = cond do
              is_float(rank_val)   -> rank_val
              is_integer(rank_val) -> rank_val * 1.0
              true                 -> 0.0
            end

            # story state-writer-redaction (D6, Oracle guardrail, follow-up `fk`): redacted events are excluded by Search.DB; when
            # events_before / events_after are ever filled they MUST go through the redaction prune (redaction_index/1)
            %Core.SearchResult{
              rank:          rank,
              event:         event_json,
              events_before: [],   # MVP: empty — Story 11.6 Godog scenarios do not test context events
              events_after:  [],   # MVP: empty
              profile_info:  %{}   # MVP: empty — get_profile/1 not yet in Nebu.Matrix.Profile.DB
            }
          end)

        # Build next_batch token: if we got `limit` results, there may be more pages.
        next_batch =
          if length(results) == limit do
            Base.encode64(Integer.to_string(offset + limit))
          else
            ""
          end

        %Core.SearchMessagesResponse{
          results:     results,
          next_batch:  next_batch,
          total_count: offset + length(results)  # lower bound — exact COUNT(*) deferred to Story 11.5
        }

      {:error, reason} ->
        # Kassandra Finding LOW-3: log full reason server-side, return sanitized error to client.
        # NEVER expose DB error details (schema names, table names, postgres messages) to caller.
        # story history-visibility-enforcement (D9, D16): value-free (a Postgrex error can echo the statement or a parameter)
        Logger.error("history visibility: search failed (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "search failed"
    end
  end

  # Emits a signed state event into the events table and broadcasts to :pg subscribers.
  # Used by upgrade_room/2 and any other path that needs to write state events directly
  # without going through Room.Server (which would re-check power levels).
  # Returns {:ok, event_id} on success, {:error, reason} on DB failure.
  # State event types that initial_state must NEVER set/forge during createRoom.
  # m.room.create is emitted authoritatively as the first event; m.room.member is
  # forging-sensitive (membership is established via the creator-join + invite/join
  # paths); m.room.power_levels is set authoritatively above (creator = 100).
  #
  # m.room.encryption is forbidden to enforce the managed-decryption model (ADR-011):
  # a persisted m.room.encryption event alone turns a room end-to-end encrypted (clients
  # switch to client-side Megolm and the server can no longer read content). The direct
  # PUT .../state/m.room.encryption path is rejected with 403 in the HTTP router; this
  # entry closes the equivalent createRoom initial_state bypass. Unlike membership/PL
  # (which are GenServer-authoritative, so a forged event is inert), encryption is
  # event-derived — every state-event writer must forbid it, not just one guardrail.
  #
  # All other spec-valid state types (m.space.parent, m.room.join_rules,
  # m.room.guest_access, m.room.history_visibility, …) are honored — this is
  # deliberately NOT a narrow allowlist (see create_room/2 comment).
  #
  # Story create-room-initial-state-conformance (D3): m.room.tombstone (a brand-new room must not
  # claim to be replaced by an arbitrary room) and m.room.third_party_invite (3pid / federation
  # invite machinery Nebu does not have) are forbidden too. These types are SKIPPED, not rejected
  # (Element sends m.room.encryption with its default E2EE on; a 4xx would break every room creation).
  # (@initial_state_forbidden_types is defined next to the createRoom validation constants above: the lock-out planner reads it)

  @initial_state_max_entries 64

  @doc false
  # Structure check of the createRoom `initial_state` field (Matrix CS StateEvent: `type` required
  # string, `content` required object, `state_key` string, default ""), run by the HTTP layer BEFORE
  # a room exists so a bad request creates nothing (story create-room-initial-state-conformance, D1).
  # nil (absent / null) and [] are no-ops. The entry cap is checked before the entry shapes.
  @spec validate_initial_state(term()) :: :ok | {:error, :too_many | :malformed}
  def validate_initial_state(nil), do: :ok

  def validate_initial_state(list) when is_list(list) do
    cond do
      length(list) > @initial_state_max_entries -> {:error, :too_many}
      Enum.all?(list, &valid_initial_state_entry?/1) -> :ok
      true -> {:error, :malformed}
    end
  end

  def validate_initial_state(_other), do: {:error, :malformed}

  defp valid_initial_state_entry?(%{"type" => type} = entry) when is_binary(type) and type != "" do
    # the depth cap runs BEFORE any recursive walk of the content (D5a): contains_nul?/1 and CanonicalJson recurse without a limit
    is_map(entry["content"]) and not content_too_deep?(entry["content"]) and
      (not Map.has_key?(entry, "state_key") or is_binary(entry["state_key"])) and
      not contains_nul?([type, entry["state_key"], entry["content"]])
  end

  defp valid_initial_state_entry?(_entry), do: false

  # A NUL character (U+0000) anywhere in an entry cannot be stored (PostgreSQL jsonb / text reject it): it is
  # client input and must be a 400 before the room exists, not a 500 after it (code-review M3). Walks keys and values.
  @doc false
  def contains_nul?(value) when is_binary(value), do: String.contains?(value, <<0>>)
  def contains_nul?(value) when is_list(value), do: Enum.any?(value, &contains_nul?/1)
  def contains_nul?(value) when is_map(value), do: Enum.any?(value, fn {k, v} -> contains_nul?(k) or contains_nul?(v) end)
  def contains_nul?(_other), do: false

  # D7: one initial_state m.room.power_levels entry, written in mode: :client (the v10 rules again, in the room process); answers
  # the ts of the chain (an identical content is a no-op without an event)
  defp apply_initial_power_levels(room_id, creator_id, content, last_ts) do
    case Nebu.Matrix.Room.Server.change_power_levels(room_id, creator_id, content, mode: :client, not_before: last_ts + 1) do
      {:ok, _event_id, %{changed: true, ts: ts}} ->
        ts

      {:ok, _event_id, %{changed: false}} ->
        last_ts

      {:error, :event_too_large} ->
        too_large!(Nebu.Matrix.EventSize.message(:initial_state_event_too_large))

      {:error, reason} ->
        Logger.error("create_room: failed to write initial_state #{log_type(@power_levels_type)} for #{room_id} (#{db_error_class(reason)})")

        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "create_room: failed to write an initial_state entry"
    end
  end

  # Decode and apply createRoom `initial_state` entries (a JSON array of
  # { "type", "state_key", "content" }) as creator-authored state events, in array
  # order. Malformed/empty JSON → no-op (the HTTP layer rejects a malformed field with
  # 400 M_BAD_JSON before a room exists, see validate_initial_state/1). Forbidden / typeless
  # entries are skipped (logged). A single entry failing to PERSIST fails the creation (raise →
  # orphan cleanup → 500; the spec says the server MUST apply the events).
  #
  # Every entry is stamped max(now, previous event ts + 1) (`min_ts` = the ts the first entry must exceed): the entries
  # of one request never tie, so "the later duplicate (type, state_key) wins" and "an entry beats the explicit alias
  # event" hold deterministically. Returns the ts of the last event written (or `min_ts`).
  defp apply_initial_state(room_id, creator_id, json, min_ts) do
    entries =
      case Jason.decode(json || "") do
        # exact duplicates are dropped: the event id hashes the event incl. a millisecond timestamp, so two
        # identical entries in one millisecond would collide on events.event_id (a 500 now that a failing
        # entry fails the creation; Kassandra delta gate X5-1). A later entry with the same (type, state_key)
        # but another content still wins in array order.
        {:ok, list} when is_list(list) -> Enum.uniq(list)
        _ -> []
      end

    Enum.reduce(entries, min_ts, fn entry, last_ts ->
      type      = is_map(entry) && entry["type"]
      state_key = (is_map(entry) && entry["state_key"]) || ""
      content   = (is_map(entry) && entry["content"]) || %{}

      cond do
        not is_binary(type) or type == "" ->
          Logger.warning("create_room: skipping initial_state entry without a string type in #{room_id}")
          last_ts

        type in @initial_state_forbidden_types ->
          Logger.warning("create_room: refusing initial_state entry of forbidden type #{log_type(type)} in #{room_id}")
          last_ts

        # story power-levels-enforcement (D7, follow-up `er`): spec step 6, a full replacement of the levels through the ONE
        # power-level writer (the creator is the sender, the chain value lifts the stamp; the entry's state key, shape and
        # change rules were validated before the room existed). FATAL on failure (orphan cleanup, 500).
        type == @power_levels_type and is_map(content) ->
          apply_initial_power_levels(room_id, creator_id, content, last_ts)

        not is_map(content) ->
          Logger.warning("create_room: skipping initial_state #{log_type(type)} with non-object content in #{room_id}")
          last_ts

        # MINOR-1 — mirror set_room_state/2's m.space.parent guard (≈line 1648-1650):
        # the referenced parent Space must exist AND the creator must be a member of
        # it. Without this, a creator could author an m.space.parent here pointing at a
        # Space they are not a member of, which the generic state-PUT path rejects.
        # Best-effort at create-time: a guard failure SKIPS this single entry (it is not
        # persisted) and is logged — it does NOT crash room creation (other entries and
        # the room itself still succeed), matching the per-entry failure semantics above.
        # The legitimate owner flow is unaffected: a creator linking a room into a Space
        # they belong to passes the membership check, so the m.space.parent edge persists.
        type == "m.space.parent" and not parent_space_membership_ok?(state_key, creator_id) ->
          Logger.warning(
            "create_room: skipping initial_state m.space.parent for #{room_id} — " <>
              "the creator is not a member of the parent space (or it does not exist)"
          )

          last_ts

        true ->
          sk = if is_binary(state_key), do: state_key, else: ""

          case emit_state_event_at(room_id, creator_id, type, sk, content, last_ts + 1) do
            {:ok, _event_id, ts} ->
              # D4: like the PUT path, an m.room.name keeps the denormalised rooms.name (Admin UI) in
              # sync; a top-level `name` is applied afterwards and wins. Non-fatal denormalisation.
              if type == "m.room.name" and sk == "" and is_binary(content["name"]) do
                case rooms_db_module().update_room_name(room_id, content["name"]) do
                  :ok -> :ok
                  {:error, reason} ->
                    Logger.warning("create_room: failed to persist rooms.name from initial_state for #{room_id} (#{db_error_class(reason)})")
                end
              end

              ts

            # story event-size-limit (D6 (b)): backstop of step 5g (unreachable through createRoom): the raise reaches
            # create_room/2's cleanup, which deletes the half-created room; the client gets the 413, nothing remains
            {:error, :event_too_large} ->
              too_large!(Nebu.Matrix.EventSize.message(:initial_state_event_too_large))

            {:error, reason} ->
              # D5: the spec says the server MUST apply the events: a persistence failure fails the
              # creation (the caller's rescue deletes the half-created room, the client gets a 500).
              # one value-free ERROR (room id, type, the error class only: a database error can carry a snippet of
              # the JSON content, and chat / state content never belongs in a log)
              Logger.error("create_room: failed to write initial_state #{log_type(type)} for #{room_id} (#{db_error_class(reason)})")

              raise Nebu.Matrix.Error,
                status: Nebu.Matrix.Status.internal(),
                message: "create_room: failed to write initial_state #{type} for #{room_id}"
          end
      end
    end)
  end

  # MINOR-1 — non-raising variant of check_parent_space_membership/2 for the
  # createRoom initial_state path. set_room_state/2 raises Nebu.Matrix.Error (404/403)
  # to reject a bad m.space.parent; at create-time we must NOT crash the whole
  # createRoom, so this returns a boolean and the caller skips just that entry.
  # The membership source and parent-exists check mirror check_parent_space_membership/2
  # exactly (get_room_create_event for existence, room state .members for membership).
  defp parent_space_membership_ok?(parent_space_id, sender_id) do
    with true <- is_binary(parent_space_id) and parent_space_id != "",
         true <- parent_space_create_event_exists?(parent_space_id) do
      try do
        parent_state = fetch_room_state(parent_space_id)
        MapSet.member?(parent_state.members, sender_id)
      rescue
        # fetch_room_state/1 raises Nebu.Matrix.Error (room not found) when the parent
        # Space's Room GenServer cannot be started — treat as "not a member".
        Nebu.Matrix.Error -> false
      end
    else
      _ -> false
    end
  end

  # Bugfix sync-state-events-missing-fields: get_room_create_event/1's real DB
  # implementation now returns a wider {:ok, content, event_id, ts} 4-tuple (AC2);
  # this existence check only cares whether an m.room.create event was found, so
  # both the 4-tuple and the original 2-tuple (fakes predating the widening) count.
  defp parent_space_create_event_exists?(parent_space_id) do
    case rooms_db_module().get_room_create_event(parent_space_id) do
      {:ok, _create_content} -> true
      {:ok, _create_content, _event_id, _origin_server_ts} -> true
      _ -> false
    end
  end

  defp emit_state_event(room_id, sender_id, event_type, state_key, content) do
    case emit_state_event_at(room_id, sender_id, event_type, state_key, content, 0) do
      {:ok, event_id, _ts} -> {:ok, event_id}
      {:error, reason} -> {:error, reason}
    end
  end

  # `{:error, :event_too_large}` for a `type` / `state_key` above 255 bytes (the sender is the router's concern, not judged here)
  defp check_state_keys(event_type, state_key) do
    case Nebu.Matrix.EventSize.check_keys(event_type, state_key, "") do
      :ok -> :ok
      {:error, _key_too_long} -> {:error, :event_too_large}
    end
  end

  # Like emit_state_event/5 but stamps the event max(now, not_before) and returns the timestamp used.
  defp emit_state_event_at(room_id, sender_id, event_type, state_key, content, not_before) do
    ts = max(Nebu.DB.Helpers.now_ms(), not_before)

    event_map = %{
      "room_id"          => room_id,
      "type"             => event_type,
      "state_key"        => state_key,
      "sender"           => sender_id,
      "content"          => content,
      "origin_server_ts" => ts
    }

    event_id      = Nebu.Matrix.EventId.generate(event_map)
    event_with_id = Map.put(event_map, "event_id", event_id)
    {_pub, priv}  = :persistent_term.get(:nebu_signing_key)
    event_json    = Nebu.Matrix.CanonicalJson.encode!(event_map)

    # story event-size-limit (D4 (b)): the SIGNED canonical bytes decide, before anything is signed further, inserted or broadcast
    # (no extra encode: `event_json` exists already). The one authoritative size check of every state write that goes through here:
    # PUT state, initial_state, the preset, name, topic and alias events, the upgrade copies.
    # the keys too (a type / state key above 255 bytes cannot come through the router, which refuses it first; this covers every other caller)
    with :ok <- check_state_keys(event_type, state_key),
         :ok <- Nebu.Matrix.EventSize.check_stored(event_json) do
      signature     = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
      sig_b64       = Base.encode64(signature)
      signed        = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})

      case messages_db_module().insert_event(signed) do
        :ok ->
          Enum.each(:pg.get_members("room:#{room_id}"), &send(&1, {:new_event, signed}))
          {:ok, event_id, ts}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Copies state events from old_room to new_room per Matrix spec Section 11.35.1.
  #
  # Filter rules:
  #   - Exclude m.room.create (new room gets its own with predecessor).
  #   - Exclude m.room.tombstone (the old room is dead; we don't copy its tombstone).
  #   - Exclude m.room.aliases (room-alias events are scoped to the old room's alias).
  #   - Exclude m.space.child / m.space.parent (space relationships are not migrated).
  #   - Exclude m.room.member (membership is re-established via invite/join).
  #
  # Required state events to copy per Matrix spec: m.room.name, m.room.topic,
  # m.room.join_rules, m.room.power_levels, m.room.history_visibility,
  # m.room.guest_access, m.room.avatar, m.room.canonical_alias, m.room.encryption.
  #
  # MAJOR-1 fix: m.room.name is excluded by get_generic_state_events/1 (it has a
  # dedicated DB helper in Story 9-7). We fetch it here explicitly and include it in
  # the "other" batch so the upgraded room preserves its name.
  #
  # Order: emit all state events first, then m.room.join_rules last (per spec).
  # Uses get_generic_state_events/1 from Story 9-7 which excludes member,
  # power_levels, create, and name.
  defp copy_state_events(old_room_id, new_room_id, requester_id) do
    # Fetch generic state events (excludes member, power_levels, create, name per 9-7).
    state_events =
      case messages_db_module().get_generic_state_events(old_room_id) do
        {:ok, events} -> events
        {:error, _}   -> []
      end

    # Exclude tombstone, aliases, and space events (get_generic_state_events already
    # excludes member/power_levels/create/name, but tombstone/aliases are included).
    # m.room.encryption is excluded for the same reason it is in @initial_state_forbidden_types:
    # the managed-decryption model (ADR-011) forbids any room from carrying an encryption
    # event, so an upgrade must never copy one forward (defense-in-depth — the create/state-PUT
    # paths already prevent one from existing via the API).
    excluded_types = [
      "m.room.tombstone",
      "m.room.aliases",
      "m.room.encryption",
      "m.space.child",
      "m.space.parent"
    ]

    # MAJOR-1 fix: get_generic_state_events excludes m.room.name, so fetch it
    # separately and prepend it as a synthetic event entry for the copy.
    #
    # Bugfix sync-state-events-missing-fields: the real DB's get_room_name/1 now
    # returns a wider {:ok, name, event_id, ts} 4-tuple (AC2) — this copy path only
    # needs the name, so both shapes are matched (fakes predating the widening
    # still return the original 2-tuple).
    name_state_events =
      case messages_db_module().get_room_name(old_room_id) do
        {:ok, name, _event_id, _ts, _sender} ->
          [%{type: "m.room.name", state_key: "", content_json: Jason.encode!(%{"name" => name})}]
        {:ok, name, _event_id, _ts} ->
          [%{type: "m.room.name", state_key: "", content_json: Jason.encode!(%{"name" => name})}]
        {:ok, name} ->
          [%{type: "m.room.name", state_key: "", content_json: Jason.encode!(%{"name" => name})}]
        {:error, _} ->
          []
      end

    {join_rules_events, other_events} =
      (name_state_events ++ state_events)
      |> Enum.reject(fn e -> e.type in excluded_types end)
      |> Enum.split_with(fn e -> e.type == "m.room.join_rules" end)

    # Story event-size-limit (D8): rows written before the size limit existed can be oversized. Such a legacy state event is NOT copied
    # (the old room keeps it; a copy would be refused by emit_state_event_at/6 anyway). The three ACCESS types are never skipped:
    # skipping one would make the new room MORE open (a missing join rule reads as `invite`, a missing history visibility as
    # `shared`, a missing guest access as `forbidden`: the first two can be more open than what was written), so they are copied
    # REDUCED to their one spec key, decided by the old value, never more open than the old room (reduce_access_content/2).
    # Non-join_rules first, join_rules last (Matrix spec requirement).
    plan =
      Enum.map(other_events ++ join_rules_events, fn e ->
        content =
          case Jason.decode(e.content_json) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        key = e.state_key || ""
        {e.type, key, content, copy_plan(new_room_id, requester_id, e.type, key, content)}
      end)

    skipped = Enum.count(plan, fn {_type, _key, _content, how} -> how == :skip end)
    reduced = Enum.count(plan, fn {_type, _key, _content, how} -> how == :reduce end)

    # ONE value-free warning per upgrade: the counts only (no type, no state key, no content, no room id)
    if skipped + reduced > 0 do
      Logger.warning("upgrade_room: legacy oversized state events: skipped #{skipped}, reduced #{reduced}")
    end

    Enum.each(plan, fn
      {_type, _key, _content, :skip} -> :ok
      {type, key, content, :reduce} -> emit_state_event(new_room_id, requester_id, type, key, reduce_access_content(type, content))
      {type, key, content, :copy} -> emit_state_event(new_room_id, requester_id, type, key, content)
    end)
  end

  @access_types ~w(m.room.join_rules m.room.history_visibility m.room.guest_access)

  # :copy (fits), :reduce (oversized access type) or :skip (any other oversized state event, and any event whose `type` / `state_key` is above
  # 255 bytes: such a slot was never the effective access rule, so nothing is reduced into it), judged like the write (the new room id, the
  # requester as sender): the same accounting as the createRoom size step.
  defp copy_plan(new_room_id, requester_id, type, key, content) do
    envelope = Nebu.Matrix.EventSize.envelope(new_room_id, requester_id, type, key, Nebu.DB.Helpers.now_ms())

    # (the sender is not judged here: an over-long requester id is the router's 403, not a property of the legacy event)
    with :ok <- check_state_keys(type, key) |> key_plan(),
         :ok <- Nebu.Matrix.EventSize.check(envelope, byte_size(Jason.encode!(content))) do
      :copy
    else
      :skip -> :skip
      _too_large -> if type in @access_types, do: :reduce, else: :skip
    end
  end

  defp key_plan(:ok), do: :ok
  defp key_plan({:error, _}), do: :skip

  # The REDUCED copy of an oversized access event: only its spec key, kept when it is a string of at most 255 bytes (an unknown value
  # stays unknown, so the room is not more open than before; `allow` of a restricted join rule is dropped: invitations only), else the
  # most restrictive value of the type: a malformed join rule refused every join (`private` does too), `joined`, `forbidden`.
  defp reduce_access_content("m.room.join_rules", content), do: %{"join_rule" => reduced_value(content["join_rule"], "private")}

  defp reduce_access_content("m.room.history_visibility", content),
    do: %{"history_visibility" => reduced_value(content["history_visibility"], "joined")}

  defp reduce_access_content("m.room.guest_access", content),
    do: %{"guest_access" => reduced_value(content["guest_access"], "forbidden")}

  defp reduced_value(value, _fallback) when is_binary(value) and byte_size(value) <= 255, do: value
  defp reduced_value(_value, fallback), do: fallback

  # ─── GetRelations — Story 9-28 / 9-29 ───────────────────────────────────────
  #
  # Returns events that relate to `event_id`, optionally filtered by rel_type and event_type.
  # Story 9-28: initial implementation for m.thread relations.
  # Story 9-29:
  #   - rel_type empty → return all relation types (no filter).
  #   - event_type non-empty → additionally filter by event_type.
  #   - dir "f" → ASC ordering; dir "b" (default) → DESC ordering.
  #   - recurse: accepted per spec; transitive recursion not yet implemented — ignored by DB layer.
  #
  # Membership check: caller must be a joined room member.
  # Unknown event_id: returns NOT_FOUND.
  # Limit clamped to 1–100 (default 20).

  def get_relations(request, stream) do
    # the viewer (and the member checked below) is the TRUSTED session identity, never the request body's user
    {user_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)
    room_id    = request.room_id
    event_id   = request.event_id
    rel_type   = request.rel_type   # empty = all relation types (Story 9-29)
    event_type = request.event_type # empty = no event_type filter (Story 9-29)
    dir        = if request.dir in ["f", "b"], do: request.dir, else: "b"
    limit      = request.limit |> max(1) |> min(100)

    # Room existence + membership — uses injected room_registry_module for testability.
    # Archived and non-existent rooms have no running GenServer; {:noproc, _} → NOT_FOUND.
    state =
      try do
        room_registry_module().get_state(room_id)
      catch
        :exit, {:noproc, _} ->
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.not_found(),
            message: "room not found: #{room_id}"
      end

    unless MapSet.member?(state.members, user_id) do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        message: "#{user_id} is not a member of #{room_id}"
    end

    # security cycle 1 (MINOR-3): a NUL is not storable, no event can carry it: the unknown-event 404 before any read
    if contains_nul?([event_id, rel_type, event_type]), do: event_not_found!()

    opts = %{
      event_type: event_type,
      dir:        dir
    }

    # Unknown parent event (scoped to this room) → 404 NOT_FOUND.
    # Room-scoped check prevents cross-room event-existence probing by room members.
    # Story history-visibility-enforcement (D8): a parent the caller may not see is the SAME 404 as an unknown one. The parent and
    # the children are read in ONE transaction under the request statement timeout (security cycle 1).
    result =
      with_read_timeout(fn ->
        case visible_parent(event_id, room_id, user_id) do
          {:ok, _parent} -> visible_relations(room_id, user_id, event_id, rel_type, limit, opts)
          {:error, reason} -> {:error, reason}
        end
      end)

    case result do
      {:ok, events} ->
        core_events = event_maps_to_core_events(events, user_id)
        %Core.GetRelationsResponse{events: core_events}

      {:error, :not_found} ->
        event_not_found!()

      {:error, reason} ->
        history_read_failed!(room_id, reason, :internal)
    end
  end

  # ─── get_event — Story 11-8 ────────────────────────────────────────────────────
  #
  # Returns a single event by ID, scoped to a room.
  # The calling user must be a joined member of the room.
  # Used by Element Web's thread.ts fetchRootEvent() to load thread roots.

  def get_event(request, stream) do
    {user_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)
    room_id  = request.room_id
    event_id = request.event_id

    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        state = room_registry_module().get_state(room_id)

        unless MapSet.member?(state.members, user_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "#{user_id} is not a member of #{room_id}"
        end

        # Story history-visibility-enforcement (D7): an event the caller may not see is the SAME 404 as an unknown one; a NUL id
        # names no storable event (security cycle 1, MINOR-3: the same 404 before any read).
        if contains_nul?([event_id]), do: event_not_found!()

        case with_read_timeout(fn -> visible_event(event_id, room_id, user_id) end) do
          {:ok, event_map} ->
            [core_event] = event_maps_to_core_events([event_map], user_id)
            %Core.GetEventResponse{event: core_event}

          {:error, :not_found} ->
            event_not_found!()

          {:error, reason} ->
            history_read_failed!(room_id, reason, :internal)
        end
    end
  end

  # ─── attach_thread_aggregations — Story 9-28 ──────────────────────────────────
  #
  # For each timeline event that has thread children, attach bundled aggregations
  # (unsigned_relations field) so Go can include them in the /sync response.
  # Only m.room.message events can be thread roots — skip state events.
  # Per message ONE `count_thread_children/2` statement, the visibility-filtered latest-child read only when the count is > 0
  # (security cycle 1, MEDIUM #2); unsigned_relations is not rendered today (`gl` (d)).

  defp attach_thread_aggregations(events, room_id, user_id) do
    Enum.map(events, fn ev ->
      # Only message events can be thread roots (skip state events).
      if ev.event_type == "m.room.message" do
        # security cycle 1 (MEDIUM #2): the cheap count first; the visibility-filtered read of the latest child only for a root
        # that has children (a childless message costs ONE statement, as before)
        with {:ok, count} when count > 0 <- messages_db_module().count_thread_children(room_id, ev.event_id),
             {:ok, [latest | _]} <- visible_relations(room_id, user_id, ev.event_id, "m.thread", 1, %{}) do
          current_user_participated =
            latest["sender"] == user_id or ev.sender_id == user_id

          # story state-writer-redaction (D6, Oracle guardrail, follow-up `fk`): a redacted child is neither counted nor fetched
          # (Room.DB excludes it); unsigned_relations is not rendered today, and when it is, latest_event MUST go through the
          # redaction prune and a redacted original MUST NOT bundle an m.replace aggregation
          latest_event_map = %{
            "event_id"         => latest["event_id"] || "",
            "room_id"          => room_id,
            "sender"           => latest["sender"] || "",
            "type"             => latest["event_type"] || "",
            "origin_server_ts" => latest["origin_server_ts"] || 0,
            "content"          => normalise_content(latest["content"])
          }

          agg = %{
            "m.thread" => %{
              "count"                      => count,
              "current_user_participated"  => current_user_participated,
              "latest_event"               => latest_event_map
            }
          }

          %{ev | unsigned_relations: Jason.encode!(agg)}
        else
          _ -> ev
        end
      else
        ev
      end
    end)
  end

  # For each thread reply in the raw DB event batch, fetches the corresponding
  # root event from DB (if not already in the delta) and returns those root events
  # as Core.Event structs with m.thread aggregations attached.
  # Prepended to the timeline so Element Web creates Thread objects in real-time
  # rather than only after a full page reload (initial sync).
  defp thread_root_updates(db_events, room_id, user_id) do
    delta_ids = MapSet.new(db_events, fn ev -> ev["event_id"] end)

    db_events
    |> Enum.flat_map(fn ev ->
      content = normalise_db_content(ev["content"])

      case content do
        %{"m.relates_to" => %{"rel_type" => "m.thread", "event_id" => root_id}}
            when is_binary(root_id) and byte_size(root_id) > 0 ->
          if MapSet.member?(delta_ids, root_id) do
            []
          else
            # story history-visibility-enforcement (D7): only a root the syncing user may see is prepended
            case visible_event(root_id, room_id, user_id) do
              {:ok, root_ev} -> [event_map_to_core_event(root_ev)]
              {:error, :not_found} -> []
              {:error, reason} -> history_read_failed!(room_id, reason, :unavailable)
            end
          end

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(fn ev -> ev.event_id end)
    |> apply_redactions()
    |> attach_thread_aggregations(room_id, user_id)
  end

  # Normalises a DB content value to a plain Elixir map.
  # Handles Postgrex.JSONB structs (shape-matched), plain maps, and JSON strings.
  defp normalise_db_content(raw) do
    cond do
      is_struct(raw) and Map.has_key?(raw, :decoded) and is_map(raw.decoded) -> raw.decoded
      is_map(raw) -> raw
      is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end
      true -> %{}
    end
  end

  # Normalises a content value from the DB (map or JSON string) to a plain map.
  defp normalise_content(raw) do
    cond do
      is_map(raw) -> raw
      is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end
      true -> %{}
    end
  end

  # ─── BulkImportUsers — Story 14-3a: Admin bulk user provisioning ───────────────
  #
  # Delegates to the configurable BulkImporter module to pre-provision
  # OIDC users before first login. Each user is processed with the same flow as
  # validate_token/2 (upsert user row + keypairs + encrypted PII).
  #
  # Security hardening (SEC Gate 2, F-2 + F-3):
  #   1. trusted_identity extracted from request metadata — caller must be identified.
  #   2. system_role is hard-coded to "user" — the field was removed from Core.*; callers
  #      cannot escalate privileges by sending a different role.
  #   3. Audit log emitted after every call (F-3) — aggregate entry per bulk operation.
  #
  # Partial success: imported + skipped + failed = len(request.users).
  # No gRPC error is raised unless the BulkImporter raises an unexpected exception.
  def bulk_import_users(%Core.BulkImportUsersRequest{} = request, stream) do
    {actor_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    users =
      Enum.map(request.users, fn claims ->
        %{
          user_id: claims.user_id,
          # Hard-code "user" — never accept a caller-supplied system_role.
          # The system_role field was removed from the proto (SEC Gate 2, F-2).
          system_role: "user",
          display_name: claims.display_name,
          email: claims.email
        }
      end)

    case bulk_importer_module().import_users(users) do
      {:ok, %{imported: imported, skipped: skipped, failed: failed, imported_user_ids: imported_user_ids}} ->
        # F-3: emit aggregate audit entry — never-raise (ignore return value).
        _audit_result =
          audit_writer_module().log(
            actor_id,
            "users_bulk_imported",
            "users",
            "bulk",
            %{
              imported: imported,
              skipped: skipped,
              failed: failed,
              # Cap to 100 user_ids to prevent multi-MB audit rows on large imports.
              user_ids: request.users |> Enum.map(& &1.user_id) |> Enum.take(100)
            },
            "success"
          )

        # Story auto-join-on-user-import: fire-and-forget room setup for each newly-imported user.
        # Identical to the run_post_login_provisioning/2 pattern for new first-login users.
        # Non-blocking and non-fatal — import response is not delayed by these tasks.
        Enum.each(imported_user_ids, fn uid -> run_post_login_provisioning(uid, true) end)

        %Core.BulkImportUsersResponse{
          imported: imported,
          skipped: skipped,
          failed: failed
        }
    end
  end
end
