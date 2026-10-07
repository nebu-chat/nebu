defmodule Nebu.Matrix.EventDispatcher.Server do
  require Logger

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

  def send_event(request, _stream) do
    room_id = request.room_id
    sender_id = request.sender_id
    event_type = request.event_type
    txn_id = request.txn_id
    # Story 9-7: extract state_key (field 7 in SendEventRequest).
    # SEC Gate 1 fix: use is_state_event (field 8) to decide the power level check.
    # When is_state_event=true, Room.Server uses :change_state (state_default=50).
    # When is_state_event=false (default), Room.Server uses :send_event (events_default=0).
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
        # SEC Gate 1: state_key=nil triggers :send_event check; state_key=string triggers :change_state.
        case Nebu.Matrix.Room.Server.send_event(room_id, sender_id, event_type, content, txn_id, state_key) do
          {:ok, event_id} ->
            %Core.SendEventResponse{event_id: event_id}

          {:error, :forbidden} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.permission_denied(),
              message: "#{sender_id} lacks power level to send events in #{room_id}"

          {:error, :room_archived} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.failed_precondition(),
              message: "M_ROOM_ARCHIVED: room is archived"

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "send_event failed: #{inspect(reason)}"
        end
    end
  end

  def create_room(request, _stream) do
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
            Logger.error(
              "create_room: cleaning up orphan room #{room_id} after failure: " <>
                Exception.format(:error, e, __STACKTRACE__)
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
        Logger.warning("create_room: orphan-room cleanup failed for #{room_id}: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("create_room: orphan-room cleanup raised for #{room_id}: #{Exception.message(e)}")
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
          Map.merge(client_creation_content, %{"creator" => creator_id, "room_version" => "10"})

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
        case messages_db_module().insert_event(create_signed) do
          :ok ->
            Enum.each(:pg.get_local_members("room:#{room_id}"), &send(&1, {:new_event, create_signed}))
          {:error, reason} ->
            Logger.warning("create_room: failed to write m.room.create for #{room_id}: #{inspect(reason)}")
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
        :pg.get_local_members("user:#{creator_id}")
        |> Enum.each(&send(&1, {:new_join, room_id}))

        default_pl = Nebu.Matrix.Room.Server.default_power_levels()
        creator_pl = put_in(default_pl, ["users", creator_id], 100)
        :ok = Nebu.Matrix.Room.Server.set_power_levels(room_id, creator_id, creator_pl)

        # Matrix CS §createRoom `initial_state`: creator-authored room setup applied
        # AFTER create → creator-join → power_levels and BEFORE name/topic (spec
        # ordering). Element relies on this for child-room-in-Space linkage
        # (m.space.parent), restricted join_rules, m.room.encryption, etc. — dropping
        # it orphans the child room from its Space (the bug this fixes).
        #
        # The creator holds power_level 100 in the brand-new room, so each entry is
        # applied as the creator through the SAME signed/persisted/fanned-out path
        # set_room_state uses (emit_state_event/5). Guards (apply_initial_state/3):
        #   - m.room.create / m.room.member / m.room.power_levels are forbidden — they
        #     cannot be clobbered or forged here (the authoritative create/join/PL
        #     setup above stays canonical; no other user's membership can be forged).
        #   - Unknown / spec-valid types are honored (NOT an allowlist), so the Space
        #     flow cannot re-break; only the three privileged types above are blocked.
        #   - Entries apply in array order → later duplicate state_keys win.
        apply_initial_state(room_id, creator_id, Map.get(request, :initial_state_json, ""))

        # Emit m.room.name state event if a name was provided
        name = request.name
        if name != nil and name != "" do
          event_map = %{
            "room_id"          => room_id,
            "type"             => "m.room.name",
            "state_key"        => "",
            "sender"           => creator_id,
            "content"          => %{"name" => name},
            "origin_server_ts" => Nebu.DB.Helpers.now_ms()
          }
          event_id = Nebu.Matrix.EventId.generate(event_map)
          event_with_id = Map.put(event_map, "event_id", event_id)
          {_pub, priv} = :persistent_term.get(:nebu_signing_key)
          event_json = Nebu.Matrix.CanonicalJson.encode!(event_map)
          signature = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
          sig_b64 = Base.encode64(signature)
          signed = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})
          case messages_db_module().insert_event(signed) do
            :ok ->
              Enum.each(:pg.get_local_members("room:#{room_id}"), &send(&1, {:new_event, signed}))
            {:error, reason} ->
              Logger.warning("create_room: failed to write m.room.name for #{room_id}: #{inspect(reason)}")
          end

          # Keep the denormalised rooms.name column in sync so the Admin UI (and any
          # name-based lookup) shows the room name, not a blank. Routed through the
          # injectable rooms_db_module() (default Nebu.Matrix.Room.DB) so unit tests can
          # capture it without a live Repo — same pattern as the room_type write below.
          case rooms_db_module().update_room_name(room_id, name) do
            :ok -> :ok
            {:error, reason} ->
              Logger.warning("create_room: failed to persist rooms.name for #{room_id}: #{inspect(reason)}")
          end

          # Derive + register a canonical alias `#localpart:server` from the name and emit
          # m.room.canonical_alias (story room-canonical-alias-from-name). Ordered AFTER
          # m.room.name (the alias is derived from the same name). The WHOLE step is
          # NON-FATAL — mirrors the name/type handling above: any derivation/registration
          # failure logs a warning and leaves the room created. A room with no name skips
          # this entirely (backwards compat) because we are inside the `if name` block.
          register_canonical_alias(room_id, creator_id, name)
        end

        # Matrix Spaces (spaces-elixir s1): persist the denormalised rooms.room_type
        # column when a type was supplied (e.g. "m.space"). For an ordinary room
        # room_type is "" (empty default) → leave the column NULL (backward compat, AC4).
        # The value is bound as a query parameter in update_room_type/2 (no SQL injection).
        room_type = Map.get(request, :room_type, "")
        if is_binary(room_type) and room_type != "" do
          case rooms_db_module().update_room_type(room_id, room_type) do
            :ok -> :ok
            {:error, reason} ->
              Logger.warning("create_room: failed to persist rooms.room_type for #{room_id}: #{inspect(reason)}")
          end
        end

        audit_writer_module().log(
          creator_id,
          "room_created",
          "room",
          room_id,
          %{"is_direct" => request.is_direct},
          "success"
        )

        %Core.CreateRoomResponse{room_id: room_id}
  end

  # ─── Canonical alias derivation + registration (story room-canonical-alias-from-name) ──

  # Bounded retry budget for the deterministic collision suffix (#localpart, -2, …, -N).
  # Beyond this we give up (non-fatal) rather than loop forever.
  @alias_collision_retries 20

  # Max total alias bytes incl. the leading `#` and the `:server` suffix (Matrix spec).
  @alias_max_bytes 255

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
  # Fully non-fatal: every failure path logs a warning and returns :ok so the room stays
  # created.
  defp register_canonical_alias(room_id, creator_id, name) do
    server_name = Application.get_env(:event_dispatcher, :server_name, "nebu.local")

    case derive_alias_localpart(name) do
      :none ->
        # No usable localpart (e.g. an all-invalid / emoji-only name) — room keeps its
        # m.room.name but gets no alias. Backwards compat / AC3.
        :ok

      {:ok, base_localpart} ->
        base_localpart = bound_localpart(base_localpart, server_name)

        case base_localpart do
          "" ->
            :ok

          _ ->
            try_register_alias(room_id, creator_id, server_name, base_localpart, 1)
        end
    end
  rescue
    e ->
      Logger.warning(
        "create_room: canonical-alias step raised for #{room_id} (non-fatal): #{Exception.message(e)}"
      )

      :ok
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
  defp try_register_alias(room_id, _creator_id, _server_name, _base, attempt)
       when attempt > @alias_collision_retries do
    Logger.warning(
      "create_room: exhausted alias-collision retries for #{room_id} (non-fatal); room created without alias"
    )

    :ok
  end

  defp try_register_alias(room_id, creator_id, server_name, base_localpart, attempt) do
    localpart = if attempt == 1, do: base_localpart, else: "#{base_localpart}-#{attempt}"
    alias_str = "##{localpart}:#{server_name}"

    case alias_db_module().insert_room_alias(alias_str, room_id, Nebu.DB.Helpers.now_ms()) do
      :ok ->
        # Alias registered → emit the canonical_alias state event via the same
        # signed/persisted/fanned-out path used for m.room.name. Already in
        # @writable_state_types and read by build_room_summary/3 → surfaces in sync +
        # space hierarchy with no proto change.
        case emit_state_event(room_id, creator_id, "m.room.canonical_alias", "", %{"alias" => alias_str}) do
          {:ok, _event_id} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "create_room: registered alias #{alias_str} but failed to emit m.room.canonical_alias for #{room_id} (non-fatal): #{inspect(reason)}"
            )

            :ok
        end

      {:error, :conflict} ->
        # Alias taken — try the next deterministic suffix.
        try_register_alias(room_id, creator_id, server_name, base_localpart, attempt + 1)

      {:error, reason} ->
        Logger.warning(
          "create_room: failed to register canonical alias #{alias_str} for #{room_id} (non-fatal): #{inspect(reason)}"
        )

        :ok
    end
  end

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
    server_name = Application.get_env(:event_dispatcher, :server_name, "nebu.local")
    opaque = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "!#{opaque}:#{server_name}"
  end

  def join_room(request, _stream) do
    room_id = request.room_id_or_alias
    user_id = request.user_id

    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        # Spaces S4 (MSC3083): enforce the `restricted` join rule BEFORE the join.
        # SCOPED to `restricted` only — public/invite/default return :ok from
        # check_join_allowed/3, so this is a no-op for every pre-S4 room (AC5).
        # Default-deny on restricted: only a pending invite OR membership of a
        # valid allow[]-space grants the join. Raises 403 M_FORBIDDEN otherwise.
        enforce_restricted_join!(room_id, user_id)

        case Nebu.Matrix.Room.Server.join(room_id, user_id) do
          :ok ->
            # forget-room-membership-purge (AC6): re-joining a forgotten room clears
            # the forget so it reappears in sync. Idempotent — a no-op if not forgotten.
            unforget_room(user_id, room_id)
            # Mark any pending invitation as accepted so it disappears from
            # rooms.invite in subsequent sync responses (no-op for public joins).
            db_module_invite().accept_invitation(room_id, user_id)
            # Wake user's long-polling sync task immediately (mirrors invite_user/2 pattern).
            # Without this, the sync task sleeps 30 s after a public-room join (GAP-JOIN-PUBLIC).
            :pg.get_local_members("user:#{user_id}")
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
            %Core.JoinRoomResponse{room_id: room_id}

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

  # ─── Spaces S4 (MSC3083): restricted join-rule enforcement ───────────────────
  #
  # Resolves the impure inputs (room state, pending invite, allow-room membership)
  # and delegates the decision to the pure Nebu.Matrix.Room.JoinRules module.
  # Raises Nebu.Matrix.Error permission_denied (→ 403 M_FORBIDDEN) on deny.
  #
  # Only `restricted` rooms are gated. For every other join_rule (public / invite /
  # default / unknown) JoinRules returns :ok and this is a no-op (AC5).
  #
  # SECURITY: allow[] is client-writable (S2 PUT) so it is attacker-influenceable.
  # The space_member? resolver returns a plain boolean against each allow-room's
  # actual member set — a non-existent allow-room (room GenServer not running /
  # not found) and an existing-but-not-member allow-room both resolve to false,
  # so they deny identically with no info leak (AC6). JoinRules validates each
  # allow[] entry (type + binary room_id) before the resolver is ever consulted (AC4).
  defp enforce_restricted_join!(room_id, user_id) do
    room_state = restricted_join_state(room_id)

    opts = [
      has_invite?: pending_invite?(room_id, user_id),
      space_member?: &allow_room_member?/2
    ]

    case Nebu.Matrix.Room.JoinRules.check_join_allowed(room_state, user_id, opts) do
      :ok ->
        :ok

      {:error, :forbidden} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.permission_denied(),
          message: "you are not allowed to join this restricted room"
    end
  end

  # The m.room.join_rules state event (incl. allow[]) is persisted as a generic
  # state event (story 9-7 / S2 PUT). Read only that slice so the decision does
  # not depend on the full build_state_events/2 assembly. On any DB error we
  # return [] → JoinRules defaults the rule to "invite" → :ok (preserve current
  # open-join behaviour; real restricted rooms are backed by the real DB).
  defp restricted_join_state(room_id) do
    case safe_generic_state_events(room_id) do
      {:ok, evs} ->
        Enum.map(evs, fn ev ->
          %{type: ev.type, state_key: ev.state_key, content: ev.content_json}
        end)

      _ ->
        []
    end
  end

  defp safe_generic_state_events(room_id) do
    mod = messages_db_module()

    if function_exported?(mod, :get_generic_state_events, 1) do
      try do
        mod.get_generic_state_events(room_id)
      rescue
        _ -> {:error, :unavailable}
      catch
        _, _ -> {:error, :unavailable}
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

    if function_exported?(mod, :get_pending_invite_rooms_for_user, 1) do
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
        Logger.warning(
          "set_room_visibility: update_room_visibility failed for #{room_id}: #{inspect(reason)}"
        )

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
        # room's join_rule (invite/private and even restricted): establish a pending
        # invite from the admin first, then run the normal authorized join path, which
        # honours the invite (enforce_restricted_join!) and accepts it. insert_invitation
        # is idempotent-friendly here — a duplicate pending invite is harmless and is
        # immediately accepted by join_room on success.
        _ = db_module_invite().insert_invitation(room_id, actor_id, user_id)

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
            # join attempt. If the join fails (e.g. room not found), drop the invite
            # so it does not dangle in the target's rooms.invite sync for an add that
            # never completed. reject_invitation is a no-op if nothing is pending.
            _ = db_module_invite().reject_invitation(room_id, user_id)
            map_member_error(e)
        end
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
    if Nebu.Matrix.UserId.valid?(user_id) do
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

    # If the room GenServer is not running (e.g. after stack restart or the user
    # was only invited and the room was never started for them), we still honour
    # the leave / decline-invite semantics by operating on the DB directly.
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        # Room GenServer not running — persist the membership leave first so that
        # room_members.left_at is set before we reject the invitation or emit events.
        # delete_member is idempotent (only updates rows where left_at IS NULL).
        # :ok and {:error, :not_member} are both expected (invite-only user, no room_members row).
        # Any other error is logged as a warning but does not fail the leave (best-effort).
        case rooms_db_module().delete_member(room_id, user_id) do
          :ok -> :ok
          {:error, :not_member} -> :ok
          {:error, reason} ->
            require Logger
            Logger.warning("[leave_room] delete_member failed for #{user_id}/#{room_id}: #{inspect(reason)}")
        end
        # Reject the pending invitation directly in DB.
        db_module_invite().reject_invitation(room_id, user_id)
        # Emit a proper m.room.member leave event so fetch_delta_rooms can find it
        # even if the :pg broadcast arrives between two sync cycles (race-proof).
        emit_decline_event(room_id, user_id)
        maybe_record_auto_join_opt_out(room_id, user_id)
        %Core.LeaveRoomResponse{room_id: room_id}

      {:ok, _pid} ->
        case Nebu.Matrix.Room.Server.leave(room_id, user_id) do
          :ok ->
            # Wake the user's long-polling sync task immediately so rooms.leave
            # arrives within the long-poll window instead of waiting up to 30 s.
            # The sync task may not be subscribed to room:#{room_id} if it started
            # before the user was in this room (e.g. a room the user created and
            # immediately left). Broadcasting to user:#{user_id} guarantees wakeup
            # regardless of room subscriptions. The Go side's buildLeaveRooms does
            # the actual DB query — the sync task just needs to wake up and return [].
            members = :pg.get_local_members("user:#{user_id}")
            require Logger
            Logger.debug("[leave_room] broadcasting {:new_leave, #{room_id}} to #{length(members)} sync tasks for #{user_id}")
            Enum.each(members, &send(&1, {:new_leave, room_id}))
            maybe_record_auto_join_opt_out(room_id, user_id)
            %Core.LeaveRoomResponse{room_id: room_id}

          {:error, :not_member} ->
            # GenServer running but user absent from in-memory state — persist the
            # membership leave first so that room_members.left_at is set.
            # delete_member is idempotent (only updates rows where left_at IS NULL).
            # :ok and {:error, :not_member} are both expected (invite-only user, no room_members row).
            # Any other error is logged as a warning but does not fail the leave (best-effort).
            case rooms_db_module().delete_member(room_id, user_id) do
              :ok -> :ok
              {:error, :not_member} -> :ok
              {:error, reason} ->
                require Logger
                Logger.warning("[leave_room] delete_member failed for #{user_id}/#{room_id}: #{inspect(reason)}")
            end
            # User has a pending invite but hasn't joined — treat as "decline invite".
            db_module_invite().reject_invitation(room_id, user_id)
            emit_decline_event(room_id, user_id)
            maybe_record_auto_join_opt_out(room_id, user_id)
            %Core.LeaveRoomResponse{room_id: room_id}

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "leave failed: #{inspect(reason)}"
        end
    end
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

  def invite_user(request, _stream) do
    room_id = request.room_id
    inviter = request.inviter_id
    invitee = request.invitee_id

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

        case db_module_invite().insert_invitation(room_id, inviter, invitee) do
          :ok ->
            # Wake the invitee's long-polling sync task immediately (Bug 4-29f fix).
            # The invitee subscribed to "user:#{invitee}" in do_incremental_sync before
            # entering the receive loop. Without this broadcast the long-poll sleeps 30 s.
            :pg.get_local_members("user:#{invitee}")
            |> Enum.each(&send(&1, {:new_invite, room_id}))

            %Core.InviteUserResponse{}

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "invite failed: #{inspect(reason)}"
        end
    end
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

        # Fetch events from PostgreSQL via the configurable messages_db_module.
        # fetch_events/4 signature: (room_id, direction, limit, from_token)
        {:ok, events, next_batch, prev_batch} =
          messages_db_module().fetch_events(room_id, direction, limit, from_token)

        core_events = event_maps_to_core_events(events)

        %Core.GetMessagesResponse{
          events: core_events,
          next_batch: next_batch,
          prev_batch: prev_batch
        }
    end
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
      # already uses to build the replaces_state batch; threading it onto the
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
  # degrades to "no replaces_state anywhere" instead of crashing with
  # UndefinedFunctionError. The real Nebu.Matrix.Room.DB always implements
  # fetch_replaces_state/1 (room/db.ex), so production and the
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
  #     overrides it. That module DOES export fetch_replaces_state/1, so
  #     function_exported?/3 alone would return true even in a Repo-less unit
  #     test and crash inside Ecto.Adapters.SQL.query/3 the moment the batch is
  #     non-empty — exactly the gap this check closes.
  defp fetch_replaces_state_batch(_mod, []), do: %{}

  defp fetch_replaces_state_batch(mod, slots) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :fetch_replaces_state, 1) and
         Process.whereis(Nebu.Repo) != nil do
      mod.fetch_replaces_state(slots)
    else
      # Debug (not warning): this is the EXPECTED path for every fast,
      # Repo-less unit test that exercises get_initial_sync/fetch_delta_rooms
      # with a FakeDB (or the real DB module but no Repo started) — logging at
      # warning level here would spam test/dev output on every such /sync
      # call. Mirrors the same hot-path/log-level rationale already
      # established in Nebu.Matrix.Http.build_joined_rooms/1's own
      # Logger.debug for a sibling "identity unavailable" condition. The
      # genuinely actionable failure (a real DB error once Repo IS running)
      # is logged at warning level inside Room.DB.fetch_replaces_state/1
      # itself, not here.
      Logger.debug(
        "fetch_replaces_state_batch: #{inspect(mod)} unavailable (not loaded/exported, or no " <>
          "Repo running) — replaces_state omitted for #{length(slots)} slot(s)"
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
  # consistent with attach_replaces_state_to_state_events/2's own per-room
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
  defp event_maps_to_core_events(raw_events) do
    core_events = Enum.map(raw_events, &event_map_to_core_event/1)

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

    replaces_state_by_id = fetch_replaces_state_batch(messages_db_module(), slots)

    Enum.map(core_events, fn ce ->
      case Map.get(replaces_state_by_id, ce.event_id) do
        nil -> ce
        replaces -> %{ce | replaces_state: replaces}
      end
    end)
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

        case Nebu.Matrix.Room.Server.set_power_levels(room_id, user_id, new_levels) do
          :ok ->
            %Core.SetPowerLevelsResponse{}

          {:error, :forbidden} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.permission_denied(),
              message: "#{user_id} lacks state_default power level"

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "set_power_levels failed: #{inspect(reason)}"
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

        case receipt_db_module().upsert_receipt(room_id, user_id, receipt_type, event_id) do
          :ok ->
            %Core.SendReceiptResponse{}

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "upsert_receipt failed: #{inspect(reason)}"
        end
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

  # ─── InvalidateUserSessions — Story 6.5: Admin deactivation revokes all sessions ─
  # Story 9-22 (AC4): Per-device logout when device_id is set.
  #
  # Two callers:
  #   - Admin deactivation: device_id="" → destroy_session/1 deletes all sync_tokens +
  #     sessions rows for the user and evicts from ETS.
  #   - Matrix POST /logout: device_id="<id>" → destroy_session/2 deletes only the
  #     (user_id, device_id) sync_tokens + sessions rows in a single DB transaction.
  #     ETS is NOT evicted (other devices may still be active).
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
    mod = room_registry_module()

    {caller_id, system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)

    state =
      try do
        mod.get_state(room_id)
      catch
        :exit, {:noproc, _} ->
          # Room GenServer not running — attempt lazy restart from DB (handles Core restart).
          # Mirrors the start_room pattern used in join_room and other write paths.
          case Nebu.Matrix.Room.RoomSupervisor.start_room(room_id) do
            {:error, reason} ->
              Logger.warning("get_room_state lazy restart failed for room #{room_id}: #{inspect(reason)}")

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

                :exit, {:timeout, _} ->
                  raise Nebu.Matrix.Error,
                    status: Nebu.Matrix.Status.unavailable(),
                    message: "room unavailable: #{room_id}"
              end
          end
      end

    # System-role callers (internal gateway fanout) skip the membership check.
    # User-role callers must be room members (Story 7-19 IDOR fix preserved).
    unless system_role == "system" or MapSet.member?(state.members, caller_id) do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        message: "#{caller_id} is not a member of #{room_id}"
    end

    # Build the full state_events list for this room.
    all_state_events = build_state_events(state, room_id)

    # Apply optional event_type / state_key filter (Story 7-19, AC2 + AC3 + AC6).
    # When event_type is empty, return all events (backward compat: /members caller).
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
  #      m.room.member / m.room.power_levels / m.room.create (and anything else) →
  #      403 M_FORBIDDEN. Those have dedicated authorized paths and must NOT be
  #      forgeable through this generic content PUT (no membership forging, no PL
  #      escalation, no create rewrite).
  #   2. POWER LEVEL: sender must be a room member with power_level >= the room's
  #      state_default (mirrors send_event's :change_state check). Non-member → 403.
  #   3. m.space.parent: the parent space (state_key) must exist (else 404) and the
  #      sender must be a member of it (else 403) — story 15.4 security requirement.
  #   4. Server-authoritative top-level fields (sender, type, room_id, event_id,
  #      origin_server_ts) are built server-side by emit_state_event/5 — never from
  #      the client. content_json is the ONLY client-controlled payload (decoded to
  #      a map; malformed → %{}, which is also the m.space.child unlink semantics).

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

  def set_room_state(request, _stream) do
    room_id    = request.room_id
    sender_id  = request.sender_id
    event_type = request.event_type
    state_key  = Map.get(request, :state_key, "") || ""

    # AC2 — allowlist is the security boundary. Reject before touching the room so
    # a forbidden type cannot lazy-start a room or leak existence. m.room.member /
    # m.room.power_levels / m.room.create land here too (not on the allowlist).
    unless event_type in @writable_state_types do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        message: "state event type #{event_type} is not writable through the generic state endpoint"
    end

    # Decode client content (malformed → %{}; empty {} is a valid m.space.child unlink).
    content =
      case Jason.decode(request.content_json) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    # Fetch room state (lazy-start the Room GenServer on :noproc, like get_room_state/2).
    state = fetch_room_state(room_id)

    # AC1 — membership + power-level (state_default) check. Mirrors the :change_state
    # authorization Room.Server applies for state events.
    unless MapSet.member?(state.members, sender_id) do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        message: "#{sender_id} is not a member of #{room_id}"
    end

    unless Nebu.Matrix.Room.PowerLevels.can?(state.power_levels, sender_id, :change_state) do
      raise Nebu.Matrix.Error,
        status: Nebu.Matrix.Status.permission_denied(),
        message: "#{sender_id} lacks the power level to set state in #{room_id}"
    end

    # AC4 — m.space.parent: parent space must exist + sender must be a member of it.
    if event_type == "m.space.parent" do
      check_parent_space_membership(state_key, sender_id)
    end

    # Emit via the existing signed/persisted/fanned-out path. Top-level fields are
    # server-built inside emit_state_event/5 (AC6 — no client-settable sender/type/room_id).
    case emit_state_event(room_id, sender_id, event_type, state_key, content) do
      {:ok, event_id} ->
        # AC5 — m.room.name written through the generic PUT must also update the
        # denormalised rooms.name column so the Admin UI stays in sync. Non-fatal:
        # a denormalisation failure does not roll back the (already-persisted) event.
        if event_type == "m.room.name" do
          name = if is_binary(content["name"]), do: content["name"], else: ""
          case rooms_db_module().update_room_name(room_id, name) do
            :ok -> :ok
            {:error, reason} ->
              Logger.warning("set_room_state: failed to persist rooms.name for #{room_id}: #{inspect(reason)}")
          end
        end

        %Core.SetRoomStateResponse{event_id: event_id}

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "set_room_state failed: #{inspect(reason)}"
    end
  end

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

  # ─── AC: GetInitialSync — full state snapshot for all joined rooms ───────────
  #
  # Flow:
  #   1. Extract user_id from request (trusted — Go Gateway set it).
  #   2. Query rooms_db_module for all room IDs where user is an active member.
  #   3. For each room_id:
  #      a. Get room state via room_registry_module().get_state/1.
  #      b. Build state events (m.room.member for each member + m.room.power_levels).
  #      c. Fetch last ≤20 timeline events from messages_db_module().
  #      d. Reverse events (DB returns newest-first, Matrix expects oldest-first).
  #   4. Generate opaque since_token (same format as Story 4-6).
  #   5. Persist token via pg_store_module().persist_since_token/3.
  #   6. Return %Core.GetInitialSyncResponse{}.

  def get_initial_sync(request, _stream) do
    user_id = request.user_id

    # forget-room-membership-purge: exclude forgotten rooms from every section.
    forgotten = forgotten_room_ids(user_id)

    room_ids =
      case rooms_db_module().get_rooms_for_user(user_id) do
        {:ok, ids} ->
          Enum.reject(ids, &MapSet.member?(forgotten, &1))

        {:error, reason} ->
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.unavailable(),
            message: "database unavailable: #{inspect(reason)}"
      end

    # Fetch all rooms concurrently — wall-clock is bounded by the slowest single
    # room rather than the sum of all rooms. max_concurrency: 5 caps concurrent
    # DB checkouts well below the pool size (attach_thread_aggregations does 2
    # additional queries per room, so 5 rooms = up to 15 concurrent checkouts at
    # peak — safe within a 10-connection pool with reasonable headroom for other
    # requests). on_timeout: :kill_task drops slow rooms gracefully; they re-appear
    # on the next incremental sync.
    sync_rooms =
      Task.async_stream(
        room_ids,
        fn room_id ->
          try do
            state = room_registry_module().get_state(room_id)
            state_events = build_state_events(state, room_id, true)

            {:ok, events, _next_batch, prev_batch} =
              messages_db_module().fetch_events(room_id, "b", 20, "")

            raw_tl_events =
              events
              |> Enum.reverse()
              |> event_maps_to_core_events()

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
          catch
            # Room GenServer not running (e.g. after core restart). Start it on demand —
            # Room.init/1 reloads all state from DB, so this is always safe.
            :exit, {:noproc, _} ->
              _ = Nebu.Matrix.Room.RoomSupervisor.start_room(room_id)
              try do
                state      = room_registry_module().get_state(room_id)
                state_evs  = build_state_events(state, room_id, true)
                {:ok, evs, _next_batch, prev_b} =
                  messages_db_module().fetch_events(room_id, "b", 20, "")
                raw_tl_evs = evs |> Enum.reverse() |> event_maps_to_core_events()

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
        {:ok, rooms} ->
          rooms

        {:exit, reason} ->
          require Logger
          Logger.warning("[get_initial_sync] room fetch timed out (10s) for user #{user_id}: #{inspect(reason)}")
          []
      end)

    # Find the most recent event_id across all rooms for the since_token anchor.
    last_event_id =
      Enum.flat_map(sync_rooms, fn room -> room.timeline_events end)
      |> Enum.max_by(fn ev -> ev.origin_ts end, fn -> nil end)
      |> case do
        nil -> nil
        ev -> ev.event_id
      end

    since_token =
      Base.encode64(
        "#{user_id}:#{last_event_id || ""}:#{System.monotonic_time()}",
        padding: false
      )

    :ok = pg_store_module().persist_since_token(user_id, since_token, last_event_id)

    %Core.GetInitialSyncResponse{
      since_token: since_token,
      rooms: sync_rooms
    }
  end

  # ─── AC: GetSyncDelta — incremental sync with long-polling ─────────────────
  #
  # Flow (revised to prevent missed-event race):
  #   1. Extract user_id, since_token, timeout_ms from request.
  #   2. Clamp timeout_ms to max 25 000 ms (was 30 000; reduced for ALB headroom).
  #   3. Look up last_event_id via pg_store_module().get_since_token(user_id).
  #      - {:error, :not_found} → fallback to get_initial_sync, set fallback_to_initial: true.
  #   4. Get room IDs: rooms_db_module().get_rooms_for_user(user_id).
  #   5. Subscribe to :pg groups for all user rooms BEFORE DB check (race prevention).
  #   6. Check DB for pending events via messages_db_module().fetch_events_since/3.
  #   7. If pending events → unsubscribe, return delta immediately.
  #   8. If no pending events AND timeout_ms > 0 → wait in receive loop.
  #   9. Generate and persist new since_token.
  #  10. Return %Core.GetSyncDeltaResponse{}.

  def get_sync_delta(request, _stream) do
    user_id = request.user_id
    # proto3 string fields are never nil — no need for `|| ""`
    device_id = request.device_id
    # client_since_token is validated against the stored token after lookup (AC2, Story 9-22).
    client_since_token = request.since_token
    timeout_ms = request.timeout_ms |> max(0) |> min(25_000)

    # Step 3: Resolve last_event_id from the since_token.
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
        initial_req = %Core.GetInitialSyncRequest{user_id: user_id}
        initial_resp = get_initial_sync(initial_req, %{http_request_headers: %{}})

        # MAJOR-A fix: persist the freshly-minted token to the per-device row so
        # the next request from this device resolves the correct checkpoint and
        # does not trigger a perpetual full-sync (AC1/AC2 recovery).
        if device_id != "" do
          :ok = pg_store_module().persist_since_token(
            user_id, device_id, initial_resp.since_token, nil
          )
        end

        %Core.GetSyncDeltaResponse{
          since_token: initial_resp.since_token,
          rooms: initial_resp.rooms,
          fallback_to_initial: true
        }

      {:ok, %{since_token: stored_token, last_event_id: last_event_id}} ->
        # AC2: Validate that the client echoes back the token we issued.
        # A mismatch means a stale or replayed token → fall back to full initial sync.
        if client_since_token != stored_token do
          initial_req = %Core.GetInitialSyncRequest{user_id: user_id}
          initial_resp = get_initial_sync(initial_req, %{http_request_headers: %{}})

          # MAJOR-A fix: persist the freshly-minted token to the per-device row so
          # the next request from this device resolves the correct checkpoint and
          # does not trigger a perpetual full-sync (AC2 recovery path).
          if device_id != "" do
            :ok = pg_store_module().persist_since_token(
              user_id, device_id, initial_resp.since_token, nil
            )
          end

          %Core.GetSyncDeltaResponse{
            since_token: initial_resp.since_token,
            rooms: initial_resp.rooms,
            fallback_to_initial: true
          }
        else
          # Run the incremental sync in a short-lived Task so the Task's process
          # joins and leaves :pg groups. When the Task exits, :pg auto-cleans its
          # membership. This ensures the handler process itself never appears in any
          # room :pg group after get_sync_delta/2 returns.
          #
          # Capture all module-level injectable deps before spawning (they are looked
          # up at call time via Application.get_env, so the Task re-evaluates them in
          # its own context automatically — no capture needed).
          task_timeout = timeout_ms + 10_000

          task = Task.async(fn ->
            do_incremental_sync(user_id, device_id, last_event_id, timeout_ms)
          end)

          Task.await(task, task_timeout)
        end
    end
  end

  # Runs the incremental sync logic in a separate (Task) process so that
  # :pg group subscriptions are owned by a process that exits when done.
  # :pg auto-removes dead processes from groups.
  defp do_incremental_sync(user_id, device_id, last_event_id, timeout_ms) do
    # Step 4: Get user's rooms
    room_ids =
      case rooms_db_module().get_rooms_for_user(user_id) do
        {:ok, ids} -> ids
        {:error, _} -> []
      end

    # Also subscribe to rooms where user has a pending invite — so that
    # invite-decline broadcasts wake up this sync task immediately.
    invited_room_ids =
      case db_module_invite().get_pending_invite_rooms_for_user(user_id) do
        {:ok, ids} -> ids
        {:error, _} -> []
      end

    # Also include rooms where the user has ALREADY declined an invite.
    # Race condition fix: if the decline happens just before this sync task starts,
    # get_pending_invite_rooms_for_user returns [] (rejected_at IS NOT NULL).
    # Without declined_room_ids, fetch_delta_rooms never checks the declined room
    # and the :pg broadcast is missed → 30 s long-poll → sync returns too late.
    # fetch_events_since returns [] for old declines (events predate since_ts),
    # so this only triggers an immediate return for genuinely new decline events.
    declined_room_ids =
      case db_module_invite().get_declined_invite_rooms_for_user(user_id) do
        {:ok, ids} -> ids
        {:error, _} -> []
      end

    # GAP-LEAVE-UI: include recently-left rooms so fetch_delta_rooms finds the leave event
    # in the initial DB check. Closes the race window where {new_leave} fires before the
    # sync task subscribes to :pg groups, causing a 30 s long-poll delay.
    left_room_ids =
      case rooms_db_module().get_recently_left_rooms_for_user(user_id) do
        {:ok, ids} -> ids
        {:error, _} -> []
      end

    room_ids = room_ids ++ invited_room_ids ++ declined_room_ids ++ left_room_ids

    # forget-room-membership-purge: drop any forgotten room from the combined set so
    # it never re-surfaces in any section (notably the recently-left → rooms.leave
    # path that previously re-surfaced left rooms indefinitely). Read fresh here so a
    # forget takes effect on the very next incremental sync.
    forgotten = forgotten_room_ids(user_id)
    room_ids = Enum.reject(room_ids, &MapSet.member?(forgotten, &1))

    # Step 5a: Subscribe to user-level :pg group BEFORE DB check.
    # Receives {:new_invite, room_id} when invite_user/2 sends an invitation — this
    # wakes the long-poll immediately instead of sleeping the full 30 s (Bug 4-29f fix).
    :pg.join("user:#{user_id}", self())

    # Step 5b: Subscribe to room-level :pg groups BEFORE DB check (race prevention).
    Enum.each(room_ids, fn room_id ->
      :pg.join("room:#{room_id}", self())
    end)

    # Step 6: Check DB for pending events per room.
    # Pass last_event_id (string) directly — the DB module resolves the ts internally.
    delta_rooms = fetch_delta_rooms(room_ids, last_event_id, user_id)

    leave_all_groups = fn ->
      :pg.leave("user:#{user_id}", self())
      Enum.each(room_ids, fn room_id -> :pg.leave("room:#{room_id}", self()) end)
    end

    result_rooms =
      if delta_rooms != [] do
        # Step 7: Events found — leave :pg groups and return immediately
        leave_all_groups.()
        delta_rooms
      else
        # Step 8: No events — enter long-poll if timeout_ms > 0
        wait_result =
          if timeout_ms > 0 do
            timer_ref = Process.send_after(self(), :sync_long_poll_timeout, timeout_ms)

            receive do
              {:new_event, _event_map} ->
                # Cancel the timer and re-query DB for all pending events
                Process.cancel_timer(timer_ref)
                flush_long_poll_timeout()
                fetch_delta_rooms(room_ids, last_event_id, user_id)

              {:new_invite, _room_id} ->
                # New invitation for this user — cancel timer and return empty delta.
                # buildInviteRooms queries the DB for invite data,
                # so returning [] here is sufficient to unblock the client.
                Process.cancel_timer(timer_ref)
                flush_long_poll_timeout()
                []

              {:new_join, new_room_id} ->
                # User joined a public room — subscribe to it and re-query (mirrors {:new_invite} pattern).
                # GAP-JOIN-PUBLIC: without this, join_room broadcasts are missed and the long-poll sleeps 30 s.
                Process.cancel_timer(timer_ref)
                flush_long_poll_timeout()
                :pg.join("room:#{new_room_id}", self())
                fetch_delta_rooms(Enum.uniq([new_room_id | room_ids]), last_event_id, user_id)

              {:new_leave, recv_room_id} ->
                # User left a room — wake up immediately so Go's buildLeaveRooms can find it via DB query.
                # GAP-LEAVE-UI / GAP-FORGET: without this, leave_room broadcasts to room:#{room_id} only;
                # if the sync task missed that subscription (race), the leave is never delivered within
                # the long-poll window. Returning [] is sufficient — Go queries DB for rooms.leave.
                require Logger
                Logger.debug("[do_incremental_sync] {:new_leave} received for room #{recv_room_id}, waking sync task for #{user_id}")
                Process.cancel_timer(timer_ref)
                flush_long_poll_timeout()
                []

              :sync_long_poll_timeout ->
                []
            end
          else
            []
          end

        # Unsubscribe from all :pg groups before returning (belt-and-suspenders;
        # :pg auto-removes dead processes, but explicit leave is cleaner)
        leave_all_groups.()

        wait_result
      end

    {new_since_token, newest_event_id} = generate_delta_token(user_id, result_rooms, last_event_id)

    # Persist per-device when device_id is set, fallback to legacy /1 key otherwise (Story 9-22).
    if device_id != "" do
      :ok = pg_store_module().persist_since_token(user_id, device_id, new_since_token, newest_event_id)
    else
      :ok = pg_store_module().persist_since_token(user_id, new_since_token, newest_event_id)
    end

    %Core.GetSyncDeltaResponse{
      since_token: new_since_token,
      rooms: result_rooms,
      fallback_to_initial: false
    }
  end

  # Fetch events since last_event_id for each room, build SyncRoom protos.
  # last_event_id is the string event_id — the DB module resolves it to a timestamp.
  # user_id is passed so attach_thread_aggregations can compute current_user_participated.
  defp fetch_delta_rooms(room_ids, last_event_id, user_id) do
    Enum.flat_map(room_ids, fn room_id ->
      case messages_db_module().fetch_events_since(room_id, last_event_id, 20) do
        {:ok, []} ->
          []

        {:ok, events} ->
          try do
            state = room_registry_module().get_state(room_id)
            raw_timeline_events = event_maps_to_core_events(events)
            thread_roots = thread_root_updates(events, room_id, user_id)
            timeline_events = attach_thread_aggregations(raw_timeline_events, room_id, user_id)

            timeline_events = thread_roots ++ timeline_events
            limited = length(events) >= 20
            # When limited, the oldest event's event_id is the backward-pagination
            # cursor (Spec §6.3.3). Client passes this to GET /messages?from=<token>&dir=b.
            prev_batch = if limited, do: List.first(events)["event_id"] || "", else: ""

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
              build_state_events(state, room_id, true)
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

            [sync_room]
          catch
            :exit, {:noproc, _} -> []
          end

        {:error, _} ->
          []
      end
    end)
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

  # Generate a new since_token and find the newest event_id from the delta rooms.
  defp generate_delta_token(user_id, rooms, fallback_event_id) do
    newest_event_id =
      Enum.flat_map(rooms, fn room -> room.timeline_events end)
      |> Enum.max_by(fn ev -> ev.origin_ts end, fn -> nil end)
      |> case do
        nil -> fallback_event_id
        ev -> ev.event_id
      end

    new_token =
      Base.encode64(
        "#{user_id}:#{newest_event_id || ""}:#{System.monotonic_time()}",
        padding: false
      )

    {new_token, newest_event_id}
  end

  # Build state events for a room: m.room.create + one m.room.member per active member
  # + one m.room.power_levels + one m.room.name (if a name has been stored).
  #
  # Bugfix sync-state-events-missing-fields: every Core.SyncRoomStateEvent built here
  # now carries REAL event_id/origin_server_ts (AC1/AC2), not synthesized placeholders —
  # see Nebu.Matrix.Http.build_joined_rooms/1 (http.ex) for where these flow into
  # /sync's rooms.join.*.state.events JSON.
  #
  # Code-review cycle 1 (MAJOR-3): `fetch_replaces_state?` (default `false`)
  # opts IN to the extra batched replaces_state lookup (see
  # attach_replaces_state_to_state_events/2 below) — it must be `true` ONLY
  # at the 3 call sites that actually read `replaces_state` off the result
  # (get_initial_sync/2's two code paths, fetch_delta_rooms/3). The OTHER
  # callers of this function (get_room_state/2 for /members + /initialSync,
  # visible_summary_or_forbid!/2, and room_visibility_summary/2 — the latter
  # invoked PER ROOM, uncapped, inside the space-hierarchy BFS traversal) never
  # read `replaces_state` off their result (those endpoints use a separately
  # deferred, pre-existing synthetic-identity path — see this story's Scope
  # boundary), so they correctly default to `false` and skip the extra query
  # entirely rather than firing it and discarding the result.
  defp build_state_events(state, room_id, fetch_replaces_state? \\ false) do
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
          {%{"creator" => creator_id, "room_version" => "10"}, "", 0}
      end

    create_event = %Core.SyncRoomStateEvent{
      type: "m.room.create",
      state_key: "",
      content: Jason.encode!(create_content),
      sender: creator_id,
      event_id: create_event_id,
      origin_server_ts: create_ts
    }

    # member_identity is captured by Room.Server at the moment it applies a join
    # (handle_call({:join, ...})) and restored from the DB on every restart
    # (do_init/1) — not re-derived via a per-sync DB round trip (AC2, cluster-safety/
    # hot-path concern). Map.get/3 defaults to %{} for any state map that predates
    # this field (e.g. hand-built test state maps for unrelated unit tests).
    member_identity = Map.get(state, :member_identity, %{})

    # Code-review cycle 1 (MINOR-3): content mirrors EXACTLY what
    # emit_membership_event/3 (room/server.ex:557-567) actually persists —
    # `%{"membership" => membership}`, no `displayname` key at all. The previous
    # synthesized `"displayname" => ""` claimed a key the real event never had,
    # now observably inconsistent with GET /rooms/{roomId}/event/{eventId} once
    # member_event_id points at that real persisted event.
    member_events =
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

    if fetch_replaces_state? do
      attach_replaces_state_to_state_events(all_state_events, room_id)
    else
      all_state_events
    end
  end

  # Bugfix unsigned-replaces-state (AC1/AC3/AC5): ONE additional batched query
  # per room (not per state event, not per sync response — "per room" is the
  # Dev Notes' explicitly-sanctioned alternative to "per response"). Enriches
  # every Core.SyncRoomStateEvent built above with its real predecessor
  # event_id, if any.
  #
  # Code-review cycle 1 (MAJOR-3): this is only REACHED from build_state_events/2
  # when its caller opted in via `fetch_replaces_state?: true` — up to 3 real
  # call sites today (get_initial_sync/2's two code paths, fetch_delta_rooms/3),
  # not the single call site this comment used to describe before that gating
  # was added. The other build_state_events/2 callers (get_room_state/2,
  # visible_summary_or_forbid!/2, room_visibility_summary/2) never reach this
  # function at all — see build_state_events/2's own comment for why.
  #
  # m.room.create's own entry is harmlessly included (always resolves to
  # no match, per Matrix invariant — first-ever event at its slot) rather than
  # specially filtered out, per the Dev Notes' "including it is also correct".
  # Entries with event_id == "" (no real persisted identity — legacy rooms
  # pre-dating migration 000035, see Nebu.Matrix.Http.build_joined_rooms/1's
  # own comment) are excluded from the batch — there is no stable anchor to
  # order against for those.
  defp attach_replaces_state_to_state_events(state_events, room_id) do
    slots =
      state_events
      |> Enum.filter(&(&1.event_id != ""))
      |> Enum.map(&{&1.event_id, room_id, &1.type, &1.state_key, &1.origin_server_ts})

    replaces_state_by_id = fetch_replaces_state_batch(messages_db_module(), slots)

    Enum.map(state_events, fn se ->
      case Map.get(replaces_state_by_id, se.event_id) do
        nil -> se
        replaces -> %{se | replaces_state: replaces}
      end
    end)
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
    # F-4 (SEC): Nebu.Matrix.Room.Server.join/2 does not yet check m.room.join_rules or ban state —
    # those subsystems are not implemented in MVP. When ban/join_rule support lands, this call
    # site must be updated to use an :auto_join variant that respects those checks, so that
    # previously-banned users are not re-added to restricted rooms at first login.
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
            case Nebu.Matrix.Room.Server.join(room_id, user_id) do
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
            case Nebu.Matrix.Room.Server.join(space_id, user_id) do
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
          Enum.each(:pg.get_local_members("room:#{room_id}"), &send(&1, {:new_event, signed}))
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
      "content"          => %{"creator" => user_id, "room_version" => "10"},
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

  # ─── Story 7-22: Room Moderation ─────────────────────────────────────────────

  @doc """
  Handles POST /_matrix/client/v3/rooms/{roomId}/kick.

  Kicks `target_id` from the room:
  1. Verifies room exists.
  2. Verifies `caller_id` is a room member.
  3. Checks caller power level ≥ kick threshold (50 by default).
  4. Calls Room GenServer leave/2 to remove target from members.
  5. Returns empty KickUserResponse on success.
  """
  def kick_user(request, stream) do
    room_id   = request.room_id
    {caller_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)
    target_id = request.target_id

    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        state = Nebu.Matrix.Room.Server.get_state(room_id)

        unless MapSet.member?(state.members, caller_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "you are not a member of this room"
        end

        unless Nebu.Matrix.Room.PowerLevels.can?(state.power_levels, caller_id, :kick) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "insufficient power level for kick"
        end

        case Nebu.Matrix.Room.Server.remove_member(room_id, target_id) do
          :ok ->
            # Emit kick as m.room.member leave with sender = caller_id (not target_id).
            reason = if request.reason != "", do: request.reason, else: nil
            content = %{"membership" => "leave"} |> then(fn c ->
              if reason, do: Map.put(c, "reason", reason), else: c
            end)
            kick_event = %{
              "room_id"          => room_id,
              "type"             => "m.room.member",
              "state_key"        => target_id,
              "sender"           => caller_id,
              "content"          => content,
              "origin_server_ts" => Nebu.DB.Helpers.now_ms()
            }
            event_id      = Nebu.Matrix.EventId.generate(kick_event)
            event_with_id = Map.put(kick_event, "event_id", event_id)
            {_pub, priv}  = :persistent_term.get(:nebu_signing_key)
            event_json    = Nebu.Matrix.CanonicalJson.encode!(kick_event)
            signature     = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
            sig_b64       = Base.encode64(signature)
            signed        = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})
            case messages_db_module().insert_event(signed) do
              :ok ->
                Enum.each(:pg.get_local_members("room:#{room_id}"), &send(&1, {:new_event, signed}))
                %Core.KickUserResponse{}
              {:error, reason} ->
                raise Nebu.Matrix.Error,
                  status: Nebu.Matrix.Status.internal(),
                  message: "kick failed: #{inspect(reason)}"
            end

          {:error, :not_member} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.not_found(),
              message: "target user is not a member of this room"

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "kick failed: #{inspect(reason)}"
        end
    end
  end

  @doc """
  Handles POST /_matrix/client/v3/rooms/{roomId}/ban.

  Bans `target_id` from the room:
  1. Verifies room exists.
  2. Verifies `caller_id` is a room member.
  3. Checks caller power level ≥ ban threshold (50 by default).
  4. If target is currently joined, removes them from members first.
  5. Emits a m.room.member ban state event.
  6. Returns empty BanUserResponse on success.
  """
  def ban_user(request, stream) do
    room_id   = request.room_id
    {caller_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)
    target_id = request.target_id

    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        state = Nebu.Matrix.Room.Server.get_state(room_id)

        unless MapSet.member?(state.members, caller_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "you are not a member of this room"
        end

        unless Nebu.Matrix.Room.PowerLevels.can?(state.power_levels, caller_id, :ban) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "insufficient power level for ban"
        end

        # If the target is currently a member, remove them without emitting a leave event
        # (the ban event below is the authoritative membership change).
        if MapSet.member?(state.members, target_id) do
          Nebu.Matrix.Room.Server.remove_member(room_id, target_id)
        end

        reason = if request.reason != "", do: request.reason, else: nil
        ban_content = %{"membership" => "ban"} |> then(fn c ->
          if reason, do: Map.put(c, "reason", reason), else: c
        end)

        # Emit a m.room.member ban state event to signal the ban.
        ban_event = %{
          "room_id"          => room_id,
          "type"             => "m.room.member",
          "state_key"        => target_id,
          "sender"           => caller_id,
          "content"          => ban_content,
          "origin_server_ts" => Nebu.DB.Helpers.now_ms()
        }
        event_id       = Nebu.Matrix.EventId.generate(ban_event)
        event_with_id  = Map.put(ban_event, "event_id", event_id)
        {_pub, priv}   = :persistent_term.get(:nebu_signing_key)
        event_json     = Nebu.Matrix.CanonicalJson.encode!(ban_event)
        signature      = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
        sig_b64        = Base.encode64(signature)
        signed         = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})

        case messages_db_module().insert_event(signed) do
          :ok ->
            Enum.each(:pg.get_local_members("room:#{room_id}"), &send(&1, {:new_event, signed}))
            %Core.BanUserResponse{}

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "ban failed: #{inspect(reason)}"
        end
    end
  end

  @doc """
  Handles POST /_matrix/client/v3/rooms/{roomId}/unban.

  Unbans `target_id` from the room by setting their membership to leave:
  1. Verifies room exists.
  2. Verifies `caller_id` is a room member.
  3. Checks caller power level ≥ ban threshold (50 by default).
  4. Emits a m.room.member leave state event (unban = set to leave).
  5. Returns empty UnbanUserResponse on success.
  """
  def unban_user(request, stream) do
    room_id   = request.room_id
    {caller_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)
    target_id = request.target_id

    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:error, :not_found} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "room not found: #{room_id}"

      {:ok, _pid} ->
        state = Nebu.Matrix.Room.Server.get_state(room_id)

        unless MapSet.member?(state.members, caller_id) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "you are not a member of this room"
        end

        unless Nebu.Matrix.Room.PowerLevels.can?(state.power_levels, caller_id, :ban) do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "insufficient power level for unban"
        end

        # Emit m.room.member leave state event — unban = set membership to leave.
        unban_event = %{
          "room_id"          => room_id,
          "type"             => "m.room.member",
          "state_key"        => target_id,
          "sender"           => caller_id,
          "content"          => %{"membership" => "leave"},
          "origin_server_ts" => Nebu.DB.Helpers.now_ms()
        }
        event_id       = Nebu.Matrix.EventId.generate(unban_event)
        event_with_id  = Map.put(unban_event, "event_id", event_id)
        {_pub, priv}   = :persistent_term.get(:nebu_signing_key)
        event_json     = Nebu.Matrix.CanonicalJson.encode!(unban_event)
        signature      = :crypto.sign(:eddsa, :none, event_json, [priv, :ed25519])
        sig_b64        = Base.encode64(signature)
        signed         = Map.put(event_with_id, "signatures", %{"nebu" => sig_b64})

        case messages_db_module().insert_event(signed) do
          :ok ->
            Enum.each(:pg.get_local_members("room:#{room_id}"), &send(&1, {:new_event, signed}))
            %Core.UnbanUserResponse{}

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "unban failed: #{inspect(reason)}"
        end
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
  # it to any :pg subscribers of the room. Called when an invite is declined via
  # POST /rooms/{roomId}/leave so that:
  #   1. fetch_delta_rooms can detect the decline even across sync-cycle boundaries
  #      (race-proof — event persisted in DB, not just a volatile :pg message).
  #   2. Any sync task subscribed to the room's :pg group wakes up immediately.
  defp emit_decline_event(room_id, user_id) do
    event_map = %{
      "room_id"          => room_id,
      "type"             => "m.room.member",
      "state_key"        => user_id,
      "sender"           => user_id,
      "content"          => %{"membership" => "leave"},
      "origin_server_ts" => Nebu.DB.Helpers.now_ms()
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
        Enum.each(:pg.get_local_members("room:#{room_id}"), &send(&1, {:new_event, signed}))

      {:error, reason} ->
        require Logger
        Logger.warning("emit_decline_event: failed for #{user_id} in #{room_id}: #{inspect(reason)}")
    end
  end

  # ─── UpgradeRoom — Story 9.8: atomic room version upgrade ─────────────────────
  #
  # Sequence (all in one call, no extra GenServer abstraction needed):
  #   1. Verify old room exists and requester has power_level >= 100 (owner).
  #   2. Emit m.room.tombstone in the old room.
  #   3. Create new room, join requester as creator, set creator power levels.
  #   4. Emit m.room.create in new room WITH predecessor (old_room_id + tombstone_event_id).
  #   5. Copy state events from old room (excluding create, tombstone, aliases, member).
  #      Emit m.room.join_rules LAST per Matrix spec.
  #   6. Invite all old members (except requester, who is already joined).
  #   7. Write audit log: room_upgraded.
  #
  # Security: power level check (step 1) is performed BEFORE any state mutation.
  # All events are emitted via the private emit_state_event/5 helper (same signing
  # pattern as create_room/2) to avoid triggering the Room.Server power check a
  # second time after we've already verified power level >= 100.

  def upgrade_room(request, stream) do
    {requester_id, _system_role} = Nebu.Matrix.RequestMetadata.trusted_identity(stream)
    old_room_id  = request.old_room_id
    new_version  = if request.new_version == "" or is_nil(request.new_version),
                     do: "10",
                     else: request.new_version

    # 1. Verify old room exists and requester is owner (power_level >= 100).
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

        requester_level =
          get_in(old_state.power_levels, ["users", requester_id]) || 0

        if requester_level < 100 do
          raise Nebu.Matrix.Error,
            status: Nebu.Matrix.Status.permission_denied(),
            message: "insufficient power level for room upgrade"
        end

        # 2. Create new room and set up creator membership + power levels.
        # MAJOR-3 fix: m.room.create MUST be the first event in any room per Matrix spec.
        # We therefore emit m.room.create BEFORE joining the creator so that the
        # m.room.create event has a lower origin_server_ts than the m.room.member event.
        new_room_id = generate_room_id()

        case Nebu.Matrix.Room.RoomSupervisor.start_room(new_room_id) do
          {:ok, _new_pid} ->
            try do
              # 3. Emit m.room.tombstone in the OLD room (via private helper, bypasses Room.Server
              #    power check — we already confirmed power_level >= 100 above).
              tombstone_content = %{
                "body"             => "This room has been replaced",
                "replacement_room" => new_room_id
              }

              tombstone_event_id =
                case emit_state_event(old_room_id, requester_id, "m.room.tombstone", "", tombstone_content) do
                  {:ok, event_id} -> event_id
                  {:error, reason} ->
                    raise Nebu.Matrix.Error,
                      status: Nebu.Matrix.Status.internal(),
                      message: "Failed to emit tombstone event: #{inspect(reason)}"
                end

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

              default_pl = Nebu.Matrix.Room.Server.default_power_levels()
              creator_pl = put_in(default_pl, ["users", requester_id], 100)

              case Nebu.Matrix.Room.Server.set_power_levels(new_room_id, requester_id, creator_pl) do
                :ok -> :ok
                {:error, reason} ->
                  raise Nebu.Matrix.Error,
                    status: Nebu.Matrix.Status.internal(),
                    message: "Failed to set power levels on new room: #{inspect(reason)}"
              end

              # 5. Copy state events from old room (spec-mandated order).
              copy_state_events(old_room_id, new_room_id, requester_id)

              # 6. Invite all old members (except requester — already joined).
              old_members = MapSet.delete(old_state.members, requester_id)

              Enum.each(old_members, fn member_id ->
                case db_module_invite().insert_invitation(new_room_id, requester_id, member_id) do
                  :ok ->
                    :pg.get_local_members("user:#{member_id}")
                    |> Enum.each(&send(&1, {:new_invite, new_room_id}))

                  {:error, reason} ->
                    Logger.warning(
                      "upgrade_room: invite failed for #{member_id} in #{new_room_id}: #{inspect(reason)}"
                    )
                end
              end)

              # 7. Archive old room (Matrix spec §11.35.1 — no new events after tombstone).
              case admin_db_module().archive_room_atomic(old_room_id) do
                :ok -> :ok
                {:error, :not_found} ->
                  # Idempotent: room row already removed by a concurrent admin operation.
                  :ok
                {:error, reason} ->
                  raise Nebu.Matrix.Error,
                    status: Nebu.Matrix.Status.internal(),
                    message: "Failed to archive old room after upgrade: #{inspect(reason)}"
              end

              # Stop the old room GenServer — no new writes possible after tombstone.
              case Nebu.Matrix.Room.RoomSupervisor.lookup_room(old_room_id) do
                {:ok, old_pid} ->
                  case Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, old_pid) do
                    :ok -> :ok
                    {:error, reason} ->
                      Logger.warning(
                        "upgrade_room: terminate_child for old room #{old_room_id} failed: #{inspect(reason)}"
                      )
                  end
                {:error, :not_found} -> :ok
              end

              # 8. Audit log — success.
              audit_writer_module().log(
                requester_id,
                "room_upgraded",
                "room",
                old_room_id,
                %{"new_room_id" => new_room_id, "new_version" => new_version},
                "success"
              )

              %Core.UpgradeRoomResponse{new_room_id: new_room_id}
            rescue
              e ->
                # Audit log — partial failure (tombstone may already be in old room).
                # Wrap in its own rescue so an audit-writer outage never masks the original error.
                error_msg = if is_exception(e), do: Exception.message(e), else: inspect(e)
                try do
                  audit_writer_module().log(
                    requester_id,
                    "room_upgraded",
                    "room",
                    old_room_id,
                    %{"new_room_id" => new_room_id, "new_version" => new_version, "error" => error_msg},
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
    case search_db_module().search_messages(user_id, search_term, limit, offset, room_filter) do
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
        Logger.error("search_messages failed", user_id: user_id, error: inspect(reason))

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
  @initial_state_forbidden_types ~w(m.room.create m.room.member m.room.power_levels m.room.encryption)

  # Decode and apply createRoom `initial_state` entries (a JSON array of
  # { "type", "state_key", "content" }) as creator-authored state events, in array
  # order. Malformed/empty JSON → no-op. Forbidden / typeless entries are skipped
  # (logged). A single entry failing to persist is non-fatal (logged) — room
  # creation has already succeeded and the spec treats initial_state best-effort
  # relative to the room existing.
  defp apply_initial_state(room_id, creator_id, json) do
    entries =
      case Jason.decode(json || "") do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end

    Enum.each(entries, fn entry ->
      type      = is_map(entry) && entry["type"]
      state_key = (is_map(entry) && entry["state_key"]) || ""
      content   = (is_map(entry) && entry["content"]) || %{}

      cond do
        not is_binary(type) or type == "" ->
          Logger.warning("create_room: skipping initial_state entry without a string type in #{room_id}")

        type in @initial_state_forbidden_types ->
          Logger.warning("create_room: refusing initial_state entry of forbidden type #{type} in #{room_id}")

        not is_map(content) ->
          Logger.warning("create_room: skipping initial_state #{type} with non-object content in #{room_id}")

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
              "creator #{creator_id} is not a member of parent space #{inspect(state_key)} (or it does not exist)"
          )

        true ->
          sk = if is_binary(state_key), do: state_key, else: ""

          case emit_state_event(room_id, creator_id, type, sk, content) do
            {:ok, _event_id} -> :ok
            {:error, reason} ->
              Logger.warning(
                "create_room: failed to write initial_state #{type} for #{room_id}: #{inspect(reason)}"
              )
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
    event_map = %{
      "room_id"          => room_id,
      "type"             => event_type,
      "state_key"        => state_key,
      "sender"           => sender_id,
      "content"          => content,
      "origin_server_ts" => Nebu.DB.Helpers.now_ms()
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
        Enum.each(:pg.get_local_members("room:#{room_id}"), &send(&1, {:new_event, signed}))
        {:ok, event_id}

      {:error, reason} ->
        {:error, reason}
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

    # Emit non-join_rules state events first.
    Enum.each(other_events, fn e ->
      content =
        case Jason.decode(e.content_json) do
          {:ok, map} -> map
          _          -> %{}
        end
      emit_state_event(new_room_id, requester_id, e.type, e.state_key || "", content)
    end)

    # Emit join_rules last (Matrix spec requirement).
    Enum.each(join_rules_events, fn e ->
      content =
        case Jason.decode(e.content_json) do
          {:ok, map} -> map
          _          -> %{}
        end
      emit_state_event(new_room_id, requester_id, e.type, e.state_key || "", content)
    end)
  end

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

  def get_relations(request, _stream) do
    user_id    = request.user_id
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

    # Unknown parent event (scoped to this room) → 404 NOT_FOUND.
    # Room-scoped check prevents cross-room event-existence probing by room members.
    case messages_db_module().event_in_room?(event_id, room_id) do
      false ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.not_found(),
          message: "event not found: #{event_id}"

      true ->
        :ok
    end

    opts = %{
      event_type: event_type,
      dir:        dir
    }

    case messages_db_module().fetch_events_by_relation(room_id, event_id, rel_type, limit, opts) do
      {:ok, events} ->
        core_events = event_maps_to_core_events(events)
        %Core.GetRelationsResponse{events: core_events}

      {:error, reason} ->
        raise Nebu.Matrix.Error,
          status: Nebu.Matrix.Status.internal(),
          message: "fetch_events_by_relation failed: #{inspect(reason)}"
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

        case messages_db_module().fetch_event(event_id, room_id) do
          {:ok, event_map} ->
            [core_event] = event_maps_to_core_events([event_map])
            %Core.GetEventResponse{event: core_event}

          {:error, :not_found} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.not_found(),
              message: "event not found: #{event_id}"

          {:error, reason} ->
            raise Nebu.Matrix.Error,
              status: Nebu.Matrix.Status.internal(),
              message: "fetch_event failed: #{inspect(reason)}"
        end
    end
  end

  # ─── attach_thread_aggregations — Story 9-28 ──────────────────────────────────
  #
  # For each timeline event that has thread children, attach bundled aggregations
  # (unsigned_relations field) so Go can include them in the /sync response.
  # Only m.room.message events can be thread roots — skip state events.
  # N+1 for MVP (small rooms); acceptable until thread lists grow large.

  defp attach_thread_aggregations(events, room_id, user_id) do
    Enum.map(events, fn ev ->
      # Only message events can be thread roots (skip state events).
      if ev.event_type == "m.room.message" do
        with {:ok, [latest | _]} <-
               messages_db_module().fetch_events_by_relation(room_id, ev.event_id, "m.thread", 1, %{}),
             {:ok, count} <- messages_db_module().count_thread_children(room_id, ev.event_id),
             true <- count > 0 do
          current_user_participated =
            latest["sender"] == user_id or ev.sender_id == user_id

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
            case messages_db_module().fetch_event(root_id, room_id) do
              {:ok, root_ev} -> [event_map_to_core_event(root_ev)]
              _ -> []
            end
          end

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(fn ev -> ev.event_id end)
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
