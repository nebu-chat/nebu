defmodule Nebu.Matrix.EventDispatcher.CreateRoomInputValidationTest do
  @moduledoc """
  Story `create-room-input-validation` (epic oauth-broker, follow-ups `ed`, `ee`, `eg`, `ei`), unit part (no PostgreSQL):
  `Server.create_room/2` validates what the client sends BEFORE any room exists (D7), honours `room_version` / `room_alias_name`
  (D1 - D3), validates `m.room.canonical_alias` entries of `initial_state` (D4), caps the name and the content depth (D5) and
  logs nothing client-supplied (D5e). The HTTP side is `create_room_input_validation_http_test.exs`.

  Style as the siblings `create_room_canonical_alias_test.exs` / `create_room_initial_state_test.exs`: `Server.create_room/2` is driven
  directly with an ETS FakeDB (`:room_manager`, `:messages_db_module`, `:rooms_db_module`) and a FakeAliasDB (`:alias_db_module`).

  Conventions of this file:

    * Every rejection is asserted through `Nebu.Matrix.Http.call_core/1` = the public `{:error, {http_status, errcode, message}}` mapping of D6,
      so the tests do not depend on HOW the core carries the errcode (field vs. status). The one exception is the D6 test below, which
      pins the `errcode` field of `Nebu.Matrix.Error` itself.
    * Requests are built with `struct/2`, never with a `%Core.CreateRoomRequest{room_version: ...}` literal: the fields `room_version` /
      `room_alias_name` do not exist yet, a literal would abort the compilation of the whole file; `struct/2` makes only the test fail.
    * `validate_create_room_request/1` is reached with `apply/3` for the same reason.
    * `async: false` - Horde, `:pg`, `Application.put_env` and the `:NebuTxnDedup` ETS table are process-global.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.Http

  @ets :create_room_input_validation_test_db
  @server "test.local"
  @creator "@alice:test.local"

  # ─── FakeDB — ETS-backed Room DB (no Repo), with per-test failure switches ───
  defmodule FakeDB do
    @ets :create_room_input_validation_test_db

    def load_members(room_id) do
      case :ets.lookup(@ets, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members = :ets.match(@ets, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(@ets, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(@ets, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(@ets, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(@ets, {:member, room_id, user_id})
      :ok
    end

    # `{:fail_insert, type}` -> the reason makes persisting that event type fail.
    def insert_event(%{"type" => type} = event) when is_binary(type) do
      case :ets.lookup(@ets, {:fail_insert, type}) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          # monotonic insertion sequence: origin_server_ts is only millisecond-granular and ties between rapidly emitted events
          seq = :ets.update_counter(@ets, :event_seq, {2, 1}, {:event_seq, 0})
          :ets.insert(@ets, {{:event, event["event_id"]}, Map.put(event, "__seq", seq)})
          :ok
      end
    end

    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(@ets, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def update_room_name(room_id, name) do
      case :ets.lookup(@ets, :fail_update_room_name) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          :ets.insert(@ets, {{:room_name, room_id}, name})
          :ok
      end
    end

    def update_room_type(room_id, room_type) do
      case :ets.lookup(@ets, :fail_update_room_type) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          :ets.insert(@ets, {{:room_type, room_id}, room_type})
          :ok
      end
    end

    # the real delete_room/1 also deletes the aliases of the room: mirrored here
    def delete_room(room_id) do
      :ets.insert(@ets, {{:deleted_room, room_id}, true})
      :ets.delete(@ets, {:room, room_id})
      :ets.match_delete(@ets, {{:member, room_id, :_}, :_})
      :ets.match_delete(@ets, {{:alias, :_}, room_id})
      :ok
    end

    def get_room_create_event(room_id) do
      :ets.match(@ets, {{:event, :_}, :"$1"})
      |> Enum.map(fn [e] -> e end)
      |> Enum.find(&(&1["room_id"] == room_id and &1["type"] == "m.room.create"))
      |> case do
        nil -> {:error, :not_found}
        create -> {:ok, create["content"]}
      end
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
  end

  # ─── FakeAliasDB — the room_aliases store (PK on `alias`), with override switches ───
  defmodule FakeAliasDB do
    @ets :create_room_input_validation_test_db

    def insert_room_alias(alias_str, room_id, _created_at) do
      :ets.insert(@ets, {{:alias_insert_call, make_ref()}, alias_str})

      case :ets.lookup(@ets, :alias_insert_override) do
        [{_, result}] ->
          result

        [] ->
          case :ets.lookup(@ets, {:alias, alias_str}) do
            [] ->
              :ets.insert(@ets, {{:alias, alias_str}, room_id})
              :ok

            _existing ->
              {:error, :conflict}
          end
      end
    end

    def lookup_alias(alias_str) do
      :ets.insert(@ets, {{:alias_lookup_call, make_ref()}, alias_str})

      case :ets.lookup(@ets, :alias_lookup_override) do
        [{_, result}] ->
          result

        [] ->
          case :ets.lookup(@ets, {:alias, alias_str}) do
            [{_, room_id}] -> {:ok, room_id}
            [] -> {:error, :not_found}
          end
      end
    end
  end

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  # The user-store seam raising a RuntimeError whose MESSAGE carries the marker (outer rescue of create_room/2).
  defmodule RaisingUserStore do
    def upsert_user(_user_id, _role), do: raise("user store down " <> Application.fetch_env!(:event_dispatcher, :__ivt_marker__))
  end

  # The user-store seam failing with a FunctionClauseError: the top stack frame then carries the ARGUMENT LIST (the creator id).
  defmodule ClauseErrorUserStore do
    def upsert_user("never-matches", "never-matches"), do: {:ok, "never-matches"}
  end

  setup do
    if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    :ets.new(@ets, [:named_table, :public, :set])

    # snapshot the env keys this suite overrides (config/runtime.exs sets some of them: server_name, audit_writer, db_module)
    # and restore them afterwards instead of deleting them
    snapshot =
      for {app, key} <- [
            {:room_manager, :db_module},
            {:event_dispatcher, :messages_db_module},
            {:event_dispatcher, :rooms_db_module},
            {:event_dispatcher, :alias_db_module},
            {:event_dispatcher, :user_store_module},
            {:event_dispatcher, :server_name},
            {:event_dispatcher, :__ivt_marker__},
            {:compliance, :audit_writer}
          ],
          do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :alias_db_module, FakeAliasDB)
    Application.put_env(:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore)
    Application.put_env(:event_dispatcher, :server_name, @server)
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined, do: :ets.delete_all_objects(:NebuTxnDedup)

    on_exit(fn ->
      for {app, key, previous} <- snapshot do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
      if :ets.whereis(:NebuTxnDedup) != :undefined, do: :ets.delete_all_objects(:NebuTxnDedup)
    end)

    :ok
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp stream, do: %{http_request_headers: %{}}
  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  defp alias_for(localpart), do: "#" <> localpart <> ":" <> @server

  defp track_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} ->
        on_exit(fn -> if Process.alive?(pid), do: (try do GenServer.stop(pid, :normal, 5_000) catch :exit, _ -> :ok end) end)

      _ ->
        :ok
    end
  end

  # Built with struct/2 on purpose (see moduledoc): unknown keys are ignored, so a missing field fails only the test.
  defp req(attrs), do: struct(Core.CreateRoomRequest, Keyword.merge([creator_id: @creator], attrs))

  # `{:ok, response}` | `{:error, {http_status, errcode, message}}` (the D6 mapping); a created room is tracked for cleanup.
  defp create(attrs) do
    result = Http.call_core(fn -> Server.create_room(req(attrs), stream()) end)

    case result do
      {:ok, resp} -> track_room(resp.room_id)
      _ -> :ok
    end

    result
  end

  defp create_ok(attrs, label \\ "create") do
    case create(attrs) do
      {:ok, resp} -> resp
      other -> flunk("#{label}: expected the room to be created, got #{inspect(other)}")
    end
  end

  # A request that must be answered `400 <errcode>` and must leave NOTHING behind: no room, not even a created-then-cleaned-up one.
  defp assert_rejected(attrs, errcode, label) do
    before = room_snapshot()

    case create(attrs) do
      {:error, {400, ^errcode, message}} ->
        assert is_binary(message) and message != "", "#{label}: a fixed, non-empty message"
        assert room_snapshot() == before, "#{label}: the request must be rejected BEFORE a room is created (no new room, no create-then-cleanup)"
        message

      {:ok, resp} ->
        flunk("#{label}: expected 400 #{errcode}, but the room #{resp.room_id} was created")

      other ->
        flunk("#{label}: expected 400 #{errcode}, got #{inspect(other)}")
    end
  end

  defp room_snapshot,
    do: {Enum.sort(:ets.match(@ets, {{:room, :"$1"}, :_})), Enum.sort(:ets.match(@ets, {{:deleted_room, :"$1"}, true}))}

  defp assert_no_room(label) do
    assert :ets.match(@ets, {{:room, :"$1"}, :_}) == [], "#{label}: no room may exist"

    assert :ets.match(@ets, {{:deleted_room, :"$1"}, true}) == [],
           "#{label}: the request must be rejected BEFORE a room is created (no create-then-cleanup)"
  end

  defp deleted_rooms, do: :ets.match(@ets, {{:deleted_room, :"$1"}, true}) |> List.flatten()
  defp alias_insert_calls, do: :ets.match(@ets, {{:alias_insert_call, :_}, :"$1"}) |> List.flatten()
  defp alias_lookup_calls, do: :ets.match(@ets, {{:alias_lookup_call, :_}, :"$1"}) |> List.flatten()

  defp events(room_id) do
    :ets.match(@ets, {{:event, :_}, :"$1"})
    |> Enum.map(fn [ev] -> ev end)
    |> Enum.filter(&(&1["room_id"] == room_id))
  end

  defp state_events(room_id, type, state_key \\ ""),
    do: events(room_id) |> Enum.filter(&(&1["type"] == type and &1["state_key"] == state_key))

  defp canonical_events(room_id), do: events(room_id) |> Enum.filter(&(&1["type"] == "m.room.canonical_alias"))

  defp seq_of(room_id, type, state_key \\ "") do
    [ev] = state_events(room_id, type, state_key)
    ev["__seq"]
  end

  defp registered_aliases, do: :ets.match(@ets, {{:alias, :"$1"}, :"$2"}) |> Enum.map(fn [a, r] -> {a, r} end)
  defp room_name(room_id), do: (case :ets.lookup(@ets, {:room_name, room_id}) do [{_, n}] -> n; [] -> :unset end)

  defp initial_state(entries), do: Jason.encode!(entries)
  defp entry(type, content, key \\ ""), do: %{"type" => type, "state_key" => key, "content" => content}

  # a content that nests `levels` maps (the content object itself is level 1)
  defp nested(1), do: %{}
  defp nested(levels), do: Enum.reduce(2..levels, %{}, fn _, acc -> %{"a" => acc} end)

  # maps and lists alternating, the outermost level is a map
  defp nested_mixed(levels) do
    leaf = if rem(levels, 2) == 1, do: %{}, else: []

    Enum.reduce((levels - 1)..1//-1, leaf, fn l, acc -> if rem(l, 2) == 1, do: %{"a" => acc}, else: [acc] end)
  end

  # a localpart so that "#" <> localpart <> ":" <> server is exactly `total` BYTES, with `multibyte` times the 2-byte "ä" inside
  defp localpart_for_total_bytes(total, multibyte) do
    random = rand()
    mb = String.duplicate("ä", multibyte)
    pad = total - 2 - byte_size(@server) - byte_size(random) - byte_size(mb)
    lp = random <> mb <> String.duplicate("a", pad)
    assert byte_size(alias_for(lp)) == total
    lp
  end

  defp pg_error(marker) do
    %Postgrex.Error{
      message: "simulated 22P05 #{marker}",
      postgres: %{
        code: :untranslatable_character,
        pg_code: "22P05",
        severity: "ERROR",
        message: "unsupported Unicode escape sequence",
        where: "JSON data, line 1: {\"name\": \"#{marker}\"...}"
      }
    }
  end

  # ─── D6: Nebu.Matrix.Error errcode + Http.map_error ──────────────────────────

  describe "D6 - Error errcode and Http.map_error" do
    test "an invalid_argument error with an errcode is a 400 with that errcode and the fixed message" do
      for errcode <- ~w(M_UNSUPPORTED_ROOM_VERSION M_ROOM_IN_USE M_BAD_ALIAS M_BAD_JSON M_INVALID_PARAM) do
        error = struct(Nebu.Matrix.Error, status: Nebu.Matrix.Status.invalid_argument(), errcode: errcode, message: "fixed text")
        assert {:error, {400, ^errcode, "fixed text"}} = Http.call_core(fn -> raise error end)
      end
    end

    test "an error without an errcode maps exactly as before" do
      assert {:error, {400, "M_INVALID_PARAM", "some message"}} =
               Http.call_core(fn -> raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.invalid_argument(), message: "some message" end)

      assert {:error, {403, "M_FORBIDDEN", _}} =
               Http.call_core(fn -> raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.permission_denied(), message: "x" end)

      assert {:error, {500, "M_UNKNOWN", _}} =
               Http.call_core(fn -> raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.internal(), message: "x" end)
    end
  end

  # ─── D7: validate_create_room_request/1 ─────────────────────────────────────

  describe "D7 - validate_create_room_request/1" do
    test "it is exported, accepts a valid request and rejects an invalid one" do
      Code.ensure_loaded(Server)
      assert function_exported?(Server, :validate_create_room_request, 1), "D7: Server.validate_create_room_request/1 (@doc false def)"

      valid = req(name: "Valid #{rand()}", room_version: "10", room_alias_name: "ok-#{rand()}")
      invalid = req(room_version: "11")

      outcome = fn request ->
        try do
          apply(Server, :validate_create_room_request, [request])
        rescue
          e in Nebu.Matrix.Error -> {:raised, e}
        end
      end

      assert outcome.(valid) == :ok, "a valid request passes as :ok"

      assert match?({:error, _}, outcome.(invalid)) or match?({:raised, %Nebu.Matrix.Error{}}, outcome.(invalid)),
             "an invalid request is rejected (as {:error, _} or as a raised Nebu.Matrix.Error)"
    end
  end

  # ─── AC2: room_version (core) ────────────────────────────────────────────────

  describe "AC2 - room_version" do
    test "absent, nil and \"10\" create a v10 room; creation_content room_version stays overwritten" do
      for {label, attrs} <- [
            absent: [],
            nil: [room_version: nil],
            ten: [room_version: "10"],
            creation_content: [creation_content_json: Jason.encode!(%{"room_version" => "9"})]
          ] do
        resp = create_ok(attrs, "room_version #{label}")
        assert [create] = state_events(resp.room_id, "m.room.create")
        assert create["content"]["room_version"] == "10", "#{label}: the resolved version, not the requested / creation_content one"
      end
    end

    test "an unsupported version string is 400 M_UNSUPPORTED_ROOM_VERSION, no room" do
      for version <- ["11", "1", "9", "12", "", "foo", "10.0", " 10", "010"] do
        assert_rejected([room_version: version], "M_UNSUPPORTED_ROOM_VERSION", "room_version #{inspect(version)}")
      end
    end

    test "a non-string room_version is 400 M_BAD_JSON, no room" do
      for version <- [10, true, false, ["10"], %{}, 10.0] do
        assert_rejected([room_version: version], "M_BAD_JSON", "room_version #{inspect(version)}")
      end
    end

    test "the client-facing message is fixed text: the requested version string is never echoed" do
      marker = "zzver" <> rand()
      message = assert_rejected([room_version: marker], "M_UNSUPPORTED_ROOM_VERSION", "marker version")
      refute message =~ marker
    end
  end

  # ─── AC6: room_alias_name syntax (core) ──────────────────────────────────────

  describe "AC6 - room_alias_name syntax" do
    test "grammar and Nebu policy violations are 400 M_INVALID_PARAM" do
      too_long = localpart_for_total_bytes(255, 0) <> "a"

      for {label, localpart} <- [
            empty: "",
            colon: "a:b",
            space: "a b",
            tab: "a\tb",
            newline: "a\nb",
            nbsp: "a\u00A0b",
            em_space: "a\u2003b",
            ideographic_space: "a\u3000b",
            nul: "a\u0000b",
            c0: "a\u0007b",
            del: "a\u007fb",
            # Nebu policy (Kassandra L-1): Unicode Cc (C1 controls) and Cf (format: zero-width, bidi, BOM) are refused too
            c1_nel: "a\u0085b",
            c1_low: "a\u0080b",
            c1_high: "a\u009Fb",
            zero_width_space: "a\u200Bb",
            left_to_right_mark: "a\u200Eb",
            right_to_left_override: "a\u202Eb",
            bidi_isolate: "a\u2066b",
            byte_order_mark: "a\uFEFFb",
            over_255_bytes: too_long,
            invalid_utf8: <<"ab", 0xFF, 0xFE, "cd">>
          ] do
        assert_rejected([room_alias_name: localpart], "M_INVALID_PARAM", "room_alias_name #{label}")
      end
    end

    test "a non-string room_alias_name (5, true, false, {}, [\"x\"], 1.5) is 400 M_BAD_JSON and nothing is created" do
      for value <- [5, true, false, %{}, ["x"], 1.5] do
        assert_rejected([room_alias_name: value], "M_BAD_JSON", "room_alias_name #{inspect(value)}")
      end
    end

    test "bytes, not code points, are counted: 255 accepted, 256 rejected" do
      ascii_255 = localpart_for_total_bytes(255, 0)
      multibyte_255 = localpart_for_total_bytes(255, 10)
      multibyte_256 = localpart_for_total_bytes(256, 10)

      assert String.length(multibyte_256) < 255, "the over-long alias has fewer than 255 code points: only the byte count rejects it"

      for {label, localpart} <- [ascii_255: ascii_255, multibyte_255: multibyte_255] do
        resp = create_ok([room_alias_name: localpart], label)
        assert {alias_for(localpart), resp.room_id} in registered_aliases(), "#{label}: registered verbatim"
      end

      assert_rejected([room_alias_name: multibyte_256], "M_INVALID_PARAM", "256 bytes with multibyte")
    end

    test "everything else is accepted verbatim, not slugified or lowercased: Räume, a/b, a#b, MixedCase" do
      for localpart <- ["Räume-" <> rand(), "a/b-" <> rand(), "a#b-" <> rand(), "MixedCase-" <> rand()] do
        resp = create_ok([room_alias_name: localpart, name: "Verbatim"], "verbatim #{localpart}")

        assert {alias_for(localpart), resp.room_id} in registered_aliases()
        assert [canonical] = canonical_events(resp.room_id)
        assert canonical["content"] == %{"alias" => alias_for(localpart)}
      end
    end

    test "the client-facing message is fixed text: the rejected alias localpart is never echoed" do
      marker = "zzalias" <> rand()
      message = assert_rejected([room_alias_name: marker <> " with space"], "M_INVALID_PARAM", "marker alias")
      refute message =~ marker
    end
  end

  # ─── AC4 / AC5 / D2 / D3: the explicit alias flow ────────────────────────────

  describe "AC4 - explicit room_alias_name" do
    test "name + room_alias_name: one canonical_alias event with the explicit alias, no derived alias" do
      localpart = "my-room-" <> rand()
      resp = create_ok([name: "Something Else", room_alias_name: localpart])

      assert registered_aliases() == [{alias_for(localpart), resp.room_id}], "only the explicit alias is registered (no #something-else...)"
      assert [canonical] = canonical_events(resp.room_id)
      assert canonical["state_key"] == ""
      assert canonical["sender"] == @creator
      assert canonical["content"] == %{"alias" => alias_for(localpart)}
      assert room_name(resp.room_id) == "Something Else", "the name does not touch the alias, and still sets rooms.name"
      assert length(alias_insert_calls()) == 1, "exactly one registration attempt (no -2 fallback, no derived alias)"
    end

    test "emit order: power_levels < canonical_alias < initial_state entries < m.room.name" do
      localpart = "ordered-" <> rand()

      resp =
        create_ok(
          room_alias_name: localpart,
          name: "Ordered Public Room",
          initial_state_json:
            initial_state([
              entry("m.room.join_rules", %{"join_rule" => "public"}),
              entry("m.room.history_visibility", %{"history_visibility" => "shared"}),
              entry("m.room.guest_access", %{"guest_access" => "forbidden"})
            ])
        )

      seqs =
        Enum.map(
          ["m.room.create", "m.room.power_levels", "m.room.canonical_alias", "m.room.join_rules", "m.room.history_visibility", "m.room.guest_access", "m.room.name"],
          &seq_of(resp.room_id, &1)
        )

      assert seqs == Enum.sort(seqs),
             "create < power_levels < canonical_alias < join_rules < history_visibility < guest_access < name, got #{inspect(seqs)}"
    end

    test "the alias is emitted before the initial_state entries, also without a name" do
      localpart = "noname-" <> rand()

      resp =
        create_ok(
          room_alias_name: localpart,
          initial_state_json: initial_state([entry("m.room.topic", %{"topic" => "t"})])
        )

      assert seq_of(resp.room_id, "m.room.power_levels") < seq_of(resp.room_id, "m.room.canonical_alias")
      assert seq_of(resp.room_id, "m.room.canonical_alias") < seq_of(resp.room_id, "m.room.topic")
    end
  end

  describe "AC7 - without room_alias_name the name-derived alias behaves as before" do
    test "nil and absent room_alias_name keep the derived alias; a nameless room has none" do
      for attrs <- [[], [room_alias_name: nil]] do
        name = "Derived Name " <> rand()
        resp = create_ok([name: name] ++ attrs)

        expected = "#" <> String.replace(String.downcase(name), " ", "-") <> ":" <> @server
        assert [canonical] = canonical_events(resp.room_id)
        assert canonical["content"] == %{"alias" => expected}
        assert seq_of(resp.room_id, "m.room.name") < canonical["__seq"], "the derived alias comes last (Nebu behaviour, D3)"

        nameless = create_ok(attrs)
        assert canonical_events(nameless.room_id) == []
      end
    end
  end

  describe "AC5 - an alias that is taken is 400 M_ROOM_IN_USE" do
    test "a taken alias (pre-check): 400 M_ROOM_IN_USE, no room created, the first mapping unchanged" do
      localpart = "taken-" <> rand()
      :ets.insert(@ets, {{:alias, alias_for(localpart)}, "!first:test.local"})

      message = assert_rejected([room_alias_name: localpart, name: "Second"], "M_ROOM_IN_USE", "taken alias")
      refute message =~ localpart, "the message is fixed text"

      assert registered_aliases() == [{alias_for(localpart), "!first:test.local"}]
      assert alias_for(localpart) in alias_lookup_calls(), "the pre-check is a lookup_alias/1"
      assert alias_insert_calls() == [], "the pre-check answers; no insert is even attempted"
    end

    test "race: lookup free but PK conflict is M_ROOM_IN_USE, orphan deleted, no suffix fallback" do
      localpart = "race-" <> rand()
      :ets.insert(@ets, {:alias_lookup_override, {:error, :not_found}})
      :ets.insert(@ets, {:alias_insert_override, {:error, :conflict}})

      assert {:error, {400, "M_ROOM_IN_USE", _}} = create(room_alias_name: localpart, name: "Lost race")

      assert [room_id] = deleted_rooms(), "the half-created room is cleaned up"
      assert canonical_events(room_id) == []
      assert alias_insert_calls() == [alias_for(localpart)], "exactly one attempt: an explicit alias has no -2 / -3 suffix fallback"
    end

    test "a non-conflict insert error is a 500 (not a 400) and the room is deleted" do
      :ets.insert(@ets, {:alias_insert_override, {:error, :simulated_db_down}})

      assert {:error, {500, _errcode, _}} = create(room_alias_name: "boom-" <> rand(), name: "Insert fails")
      assert [room_id] = deleted_rooms()
      assert canonical_events(room_id) == []
    end

    test "a store error in the pre-check lookup is a 500 and happens before any room exists" do
      :ets.insert(@ets, {:alias_lookup_override, {:error, :simulated_db_down}})

      assert {:error, {500, _errcode, _}} = create(room_alias_name: "lookup-fails-" <> rand())
      assert_no_room("lookup error")
    end

    test "a failing explicit canonical_alias emit is a 500 and the room is deleted" do
      :ets.insert(@ets, {{:fail_insert, "m.room.canonical_alias"}, :simulated_db_down})

      assert {:error, {500, _errcode, _}} = create(room_alias_name: "emit-fails-" <> rand(), name: "Emit fails")
      assert [room_id] = deleted_rooms()
      assert canonical_events(room_id) == []
    end
  end

  # ─── AC8 / D4: canonical_alias entries in initial_state (core) ───────────────

  describe "AC8 - canonical_alias in initial_state" do
    defp canonical_entry(content, key \\ ""), do: initial_state([entry("m.room.canonical_alias", content, key)])

    test "an entry naming the own alias is accepted and is the latest state" do
      for content_fun <- [
            fn own -> %{"alias" => own} end,
            fn own -> %{"alt_aliases" => [own]} end,
            fn own -> %{"alias" => own, "alt_aliases" => [own]} end,
            fn own -> %{"alias" => "", "alt_aliases" => [own]} end,
            fn _own -> %{"alias" => nil} end,
            fn _own -> %{"alias" => ""} end
          ] do
        localpart = "x-" <> rand()
        content = content_fun.(alias_for(localpart))

        resp = create_ok([room_alias_name: localpart, initial_state_json: canonical_entry(content)], inspect(content))

        assert {alias_for(localpart), resp.room_id} in registered_aliases(), "the explicit alias is registered for the room"
        latest = canonical_events(resp.room_id) |> Enum.max_by(& &1["__seq"])
        assert latest["content"] == content, "the entry is applied after the explicit alias event (spec order) and wins"
      end
    end

    test "an alias that is not the one of room_alias_name is M_BAD_ALIAS" do
      localpart = "x-" <> rand()
      other_localpart = "other-" <> rand()
      :ets.insert(@ets, {{:alias, alias_for(other_localpart)}, "!someone-elses:test.local"})

      for {label, content, key} <- [
            {:unregistered, %{"alias" => alias_for("unregistered-" <> rand())}, ""},
            {:registered_elsewhere, %{"alias" => alias_for(other_localpart)}, ""},
            {:alt_aliases, %{"alt_aliases" => [alias_for(localpart), alias_for(other_localpart)]}, ""},
            {:foreign_server, %{"alias" => "#x:other.example"}, ""},
            {:other_state_key, %{"alias" => alias_for(other_localpart)}, "some-key"}
          ] do
        assert_rejected(
          [room_alias_name: localpart, initial_state_json: canonical_entry(content, key)],
          "M_BAD_ALIAS",
          "initial_state alias #{label}"
        )
      end
    end

    test "bad syntax or wrong types are M_INVALID_PARAM, never M_INVALID_ROOM_STATE" do
      localpart = "x-" <> rand()

      for {label, content} <- [
            not_an_alias: %{"alias" => "not-an-alias"},
            no_local: %{"alias" => "#nolocal"},
            empty_local: %{"alias" => "#:server"},
            empty_domain: %{"alias" => "#a:"},
            alias_number: %{"alias" => 5},
            alias_list: %{"alias" => ["#a:b"]},
            alt_not_a_list: %{"alt_aliases" => "x"},
            alt_number_entry: %{"alt_aliases" => [5]},
            alt_bad_syntax: %{"alt_aliases" => [alias_for(localpart), "not-an-alias"]},
            nul: %{"alias" => "#a\u0000b:" <> @server},
            over_255_bytes: %{"alias" => "#" <> String.duplicate("a", 256) <> ":" <> @server}
          ] do
        assert_rejected(
          [room_alias_name: localpart, initial_state_json: canonical_entry(content)],
          "M_INVALID_PARAM",
          "initial_state alias #{label}"
        )
      end
    end

    test "without room_alias_name only alias-less entries pass" do
      name = "Entry Without Alias " <> rand()

      for content <- [%{}, %{"alias" => ""}, %{"alias" => nil}, %{"alt_aliases" => []}] do
        resp = create_ok([name: name, initial_state_json: canonical_entry(content)], inspect(content))

        latest = canonical_events(resp.room_id) |> Enum.max_by(& &1["__seq"])
        assert latest["content"]["alias"] =~ ~r/^#entry-without-alias-/, "the derived alias is emitted last and wins (sibling D4)"
      end

      assert_rejected([name: "Valid Alias Not Mine", initial_state_json: canonical_entry(%{"alias" => alias_for("nobody-" <> rand())})], "M_BAD_ALIAS", "alias without room_alias_name")
      assert_rejected([initial_state_json: canonical_entry(%{"alt_aliases" => ["#a:" <> @server]})], "M_BAD_ALIAS", "alt alias without room_alias_name")
      assert_rejected([initial_state_json: canonical_entry(%{"alias" => "not-an-alias"})], "M_INVALID_PARAM", "bad syntax without room_alias_name")
    end

    test "the message of the rejection is fixed text: the offending alias is never echoed" do
      marker = "zzentry" <> rand()

      message = assert_rejected([initial_state_json: canonical_entry(%{"alias" => "#" <> marker <> ":" <> @server})], "M_BAD_ALIAS", "marker entry")
      refute message =~ marker

      message = assert_rejected([initial_state_json: canonical_entry(%{"alias" => marker})], "M_INVALID_PARAM", "marker syntax")
      refute message =~ marker
    end
  end

  # ─── AC11 (core part) / D5b, D5c: the name ───────────────────────────────────

  describe "AC11 - the top-level name" do
    test "a non-string or NUL name is M_BAD_JSON, no room" do
      for {label, name} <- [number: 42, boolean: true, object: %{}, list: ["x"], float: 1.5, nul: "a\u0000b"] do
        assert_rejected([name: name], "M_BAD_JSON", "name #{label}")
      end
    end

    test "256 code points are M_INVALID_PARAM, 255 are accepted" do
      assert_rejected([name: String.duplicate("a", 256)], "M_INVALID_PARAM", "256 ASCII")
      assert_rejected([name: String.duplicate("ä", 256)], "M_INVALID_PARAM", "256 multibyte")

      ascii = String.duplicate("n", 255)
      assert room_name(create_ok(name: ascii).room_id) == ascii

      multibyte = String.duplicate("ä", 255)
      assert byte_size(multibyte) == 510, "the cap counts code points, not bytes"
      assert room_name(create_ok(name: multibyte).room_id) == multibyte
    end

    test "nil and \"\" are a nameless room (200, no m.room.name event, rooms.name untouched)" do
      for name <- [nil, ""] do
        resp = create_ok(name: name)
        assert state_events(resp.room_id, "m.room.name") == []
        assert room_name(resp.room_id) == :unset
      end
    end
  end

  describe "AC11 - m.room.name in initial_state" do
    defp name_entry(content), do: initial_state([entry("m.room.name", content)])

    test "256 code points are M_INVALID_PARAM, 255 sync rooms.name" do
      assert_rejected([initial_state_json: name_entry(%{"name" => String.duplicate("a", 256)})], "M_INVALID_PARAM", "initial_state name 256")
      assert_rejected([initial_state_json: name_entry(%{"name" => String.duplicate("ä", 256)})], "M_INVALID_PARAM", "initial_state name 256 multibyte")

      name = String.duplicate("e", 255)
      resp = create_ok(initial_state_json: name_entry(%{"name" => name}))
      assert room_name(resp.room_id) == name
    end

    test "a non-string, non-null name is M_BAD_JSON, no room" do
      for {label, value} <- [number: 42, boolean: true, object: %{}, list: []] do
        assert_rejected([initial_state_json: name_entry(%{"name" => value})], "M_BAD_JSON", "initial_state name #{label}")
      end
    end

    test "empty name, {} and null name stay valid" do
      for content <- [%{"name" => ""}, %{}, %{"name" => nil}] do
        resp = create_ok([initial_state_json: name_entry(content)], inspect(content))
        assert [_] = state_events(resp.room_id, "m.room.name")
      end
    end
  end

  # ─── D7: the order of the checks (first failure wins) ────────────────────────

  describe "D7 - order of the checks" do
    test "each earlier failure wins over every later one" do
      taken = "d7-taken-" <> rand()
      :ets.insert(@ets, {{:alias, alias_for(taken)}, "!first:test.local"})

      for {label, attrs, errcode} <- [
            {"name type beats room_version", [name: 42, room_version: "11"], "M_BAD_JSON"},
            {"name NUL beats room_version", [name: "a\u0000b", room_version: "11"], "M_BAD_JSON"},
            {"name length beats room_version", [name: String.duplicate("a", 256), room_version: "11"], "M_INVALID_PARAM"},
            {"room_version beats a bad alias", [room_version: "11", room_alias_name: "a:b"], "M_UNSUPPORTED_ROOM_VERSION"},
            {"room_version type beats a bad alias", [room_version: 11, room_alias_name: "a:b"], "M_BAD_JSON"},
            {"a valid but TAKEN alias loses against an unsupported room_version", [room_version: "11", room_alias_name: taken], "M_UNSUPPORTED_ROOM_VERSION"},
            {"alias type beats an initial_state alias", [room_alias_name: 5, initial_state_json: canonical_entry(%{"alias" => "#other:" <> @server})], "M_BAD_JSON"},
            {"alias syntax beats an initial_state alias", [room_alias_name: "a:b", initial_state_json: canonical_entry(%{"alias" => "#other:" <> @server})], "M_INVALID_PARAM"},
            {"an initial_state alias beats the taken-check", [room_alias_name: taken, initial_state_json: canonical_entry(%{"alias" => "#other:" <> @server})], "M_BAD_ALIAS"},
            {"top-level name NUL beats an initial_state name length", [name: "a\u0000b", initial_state_json: initial_state([entry("m.room.name", %{"name" => String.duplicate("a", 256)})])], "M_BAD_JSON"},
            {"an initial_state name length beats room_version", [room_version: "11", initial_state_json: initial_state([entry("m.room.name", %{"name" => String.duplicate("a", 256)})])], "M_INVALID_PARAM"},
            {"the taken alias alone", [room_alias_name: taken], "M_ROOM_IN_USE"}
          ] do
        assert_rejected(attrs, errcode, label)
      end

      assert alias_insert_calls() == [], "none of these reached a write"
    end

    test "a taken alias with room_version absent or 10 is M_ROOM_IN_USE" do
      taken = "d7-taken-" <> rand()
      :ets.insert(@ets, {{:alias, alias_for(taken)}, "!first:test.local"})
      assert_rejected([room_alias_name: taken, room_version: nil], "M_ROOM_IN_USE", "taken, no version")
      assert_rejected([room_alias_name: taken, room_version: "10"], "M_ROOM_IN_USE", "taken, version 10")
    end
  end

  # ─── AC10: depth cap in validate_initial_state/1 ─────────────────────────────

  describe "AC10 - validate_initial_state/1 depth cap 32" do
    defp content_entry(content), do: [%{"type" => "m.test.depth", "content" => content}]

    test "32 levels are ok, 33 are malformed (maps and lists)" do
      assert :ok == Server.validate_initial_state(content_entry(nested(32)))
      assert {:error, :malformed} == Server.validate_initial_state(content_entry(nested(33)))

      assert :ok == Server.validate_initial_state(content_entry(nested_mixed(32)))
      assert {:error, :malformed} == Server.validate_initial_state(content_entry(nested_mixed(33)))
    end

    test "a 5000-level content is malformed (today :ok): the depth is capped before the content is walked" do
      assert {:error, :malformed} == Server.validate_initial_state(content_entry(nested(5000)))
      assert {:error, :malformed} == Server.validate_initial_state(content_entry(nested_mixed(5000)))
    end

    test "the depth of every entry is checked, not only the first" do
      assert {:error, :malformed} ==
               Server.validate_initial_state([
                 %{"type" => "m.test.depth", "content" => %{}},
                 %{"type" => "m.test.depth", "state_key" => "2", "content" => nested(33)}
               ])
    end
  end

  # ─── AC11 last sentence: the Admin path ──────────────────────────────────────

  describe "AC11 - Admin path create_room/2" do
    test "256 code points is {:error, _} and no room, 255 is ok" do
      assert {:error, _} = Nebu.Matrix.create_room(@creator, name: String.duplicate("a", 256))
      assert_no_room("admin 256")

      assert {:ok, room_id} = Nebu.Matrix.create_room(@creator, name: String.duplicate("a", 255))
      track_room(room_id)
    end

    test "create_space/2 is covered too: a 256 code point name is {:error, _} and no room, 255 is ok" do
      assert {:error, _} = Nebu.Matrix.create_space(@creator, String.duplicate("a", 256))
      assert_no_room("create_space 256")

      assert {:ok, room_id} = Nebu.Matrix.create_space(@creator, String.duplicate("a", 255))
      track_room(room_id)
    end

    test "the Admin path keeps the derived alias" do
      assert {:ok, room_id} = Nebu.Matrix.create_room(@creator, name: "Admin Room " <> rand())
      track_room(room_id)
      assert [canonical] = canonical_events(room_id)
      assert canonical["content"]["alias"] =~ ~r/^#admin-room-/
    end
  end

  # ─── AC12: value-free logs ───────────────────────────────────────────────────

  describe "AC12 - value-free failure logs" do
    defp capture_create(attrs) do
      ref = make_ref()
      log = capture_log(fn -> send(self(), {ref, create(attrs)}) end)
      assert_received {^ref, result}
      {log, result}
    end

    defp assert_value_free(log, room_id, marker) do
      assert log =~ room_id, "the log names the room id"
      assert log =~ "postgres 22P05", "the log names the error class"
      refute String.downcase(log) =~ String.downcase(marker), "the log must not contain the client value / the database error text"
    end

    test "m.room.create write failure" do
      marker = "mkcreate" <> rand()
      :ets.insert(@ets, {{:fail_insert, "m.room.create"}, pg_error(marker)})

      {log, {:ok, resp}} = capture_create(name: "Plain Name", creation_content_json: Jason.encode!(%{"x" => marker}))
      assert_value_free(log, resp.room_id, marker)
    end

    test "m.room.name write failure (the name is the marker)" do
      marker = "mkname" <> rand()
      :ets.insert(@ets, {{:fail_insert, "m.room.name"}, pg_error(marker)})

      {log, {:ok, resp}} = capture_create(name: marker)
      assert_value_free(log, resp.room_id, marker)
    end

    test "rooms.name write failure of the top-level name" do
      marker = "mkrooms" <> rand()
      :ets.insert(@ets, {:fail_update_room_name, pg_error(marker)})

      {log, {:ok, resp}} = capture_create(name: marker)
      assert_value_free(log, resp.room_id, marker)
    end

    test "rooms.name write failure of an initial_state name" do
      marker = "mkistate" <> rand()
      :ets.insert(@ets, {:fail_update_room_name, pg_error(marker)})

      {log, {:ok, resp}} = capture_create(initial_state_json: initial_state([entry("m.room.name", %{"name" => marker})]))
      assert_value_free(log, resp.room_id, marker)
    end

    test "rooms.room_type write failure" do
      marker = "mktype" <> rand()
      :ets.insert(@ets, {:fail_update_room_type, pg_error(marker)})

      {log, {:ok, resp}} = capture_create(name: "Space #{rand()}", room_type: "m.space")
      assert_value_free(log, resp.room_id, marker)
    end

    test "derived-alias registration failure" do
      marker = "mkderive" <> rand()
      :ets.insert(@ets, {:alias_insert_override, {:error, pg_error(marker)}})

      {log, {:ok, resp}} = capture_create(name: marker)
      assert_value_free(log, resp.room_id, marker)
    end

    test "derived-alias emit failure" do
      marker = "mkemit" <> rand()
      :ets.insert(@ets, {{:fail_insert, "m.room.canonical_alias"}, pg_error(marker)})

      {log, {:ok, resp}} = capture_create(name: marker)
      assert_value_free(log, resp.room_id, marker)
    end

    test "explicit-alias registration failure: 500, room deleted" do
      marker = "mkexplicit" <> rand()
      :ets.insert(@ets, {:alias_insert_override, {:error, pg_error(marker)}})

      {log, result} = capture_create(room_alias_name: marker, name: "Explicit")
      assert {:error, {500, _, _}} = result
      assert [room_id] = deleted_rooms()
      assert_value_free(log, room_id, marker)
    end

    test "explicit-alias emit failure: 500, room deleted" do
      marker = "mkexpemit" <> rand()
      :ets.insert(@ets, {{:fail_insert, "m.room.canonical_alias"}, pg_error(marker)})

      {log, result} = capture_create(room_alias_name: marker, name: "Explicit")
      assert {:error, {500, _, _}} = result
      assert [room_id] = deleted_rooms()
      assert_value_free(log, room_id, marker)
    end

    test "outer rescue logs the exception module and a stacktrace, not the message" do
      marker = "mkrescue" <> rand()
      Application.put_env(:event_dispatcher, :__ivt_marker__, marker)
      Application.put_env(:event_dispatcher, :user_store_module, RaisingUserStore)

      {log, result} = capture_create(name: "Outer Rescue")
      assert {:error, {500, _, _}} = result
      assert [room_id] = deleted_rooms()

      assert log =~ room_id
      assert log =~ "RuntimeError", "the exception module is logged"
      assert log =~ "upsert_user/2", "a stacktrace is logged"
      refute log =~ marker, "the exception MESSAGE is client / DB text and must not be logged"
    end

    test "outer rescue prints no stack frame arguments" do
      marker = "mkargs" <> rand()
      Application.put_env(:event_dispatcher, :user_store_module, ClauseErrorUserStore)

      {log, result} = capture_create(creator_id: "@#{marker}:test.local", name: "Outer Rescue Args")
      assert {:error, {500, _, _}} = result
      assert log =~ "FunctionClauseError"
      assert log =~ "upsert_user/2", "the frame is there, with its arity instead of the arguments"
      refute log =~ marker, "no argument of a stack frame may be printed"
    end
  end

  # ─── review cycle 1 ──────────────────────────────────────────────────────────

  describe "cycle 1 - M1: initial_state entries are applied with strictly increasing origin_server_ts" do
    test "an initial_state canonical_alias entry is strictly later than the explicit alias event, without waiting" do
      for _ <- 1..20 do
        localpart = "ts-" <> rand()
        own = alias_for(localpart)
        content = %{"alias" => "", "alt_aliases" => [own]}

        resp = create_ok(room_alias_name: localpart, initial_state_json: initial_state([entry("m.room.canonical_alias", content)]))

        [alias_event, entry_event] = canonical_events(resp.room_id) |> Enum.sort_by(& &1["__seq"])
        assert alias_event["content"] == %{"alias" => own}
        assert entry_event["content"] == content
        assert entry_event["origin_server_ts"] > alias_event["origin_server_ts"], "the entry must win by origin_server_ts, not by luck"
        assert entry_event["event_id"] != alias_event["event_id"]
      end
    end

    test "two initial_state entries of the same (type, state_key) get strictly increasing timestamps (the later one wins)" do
      resp =
        create_ok(
          initial_state_json:
            initial_state([entry("m.room.topic", %{"topic" => "first"}), entry("m.room.topic", %{"topic" => "second"})])
        )

      [first, second] = state_events(resp.room_id, "m.room.topic") |> Enum.sort_by(& &1["__seq"])
      assert first["content"]["topic"] == "first"
      assert second["origin_server_ts"] > first["origin_server_ts"]
    end
  end

  describe "cycle 1 - M3: the alias set of a canonical_alias entry is capped at 64" do
    test "65 distinct aliases are M_INVALID_PARAM (initial_state path), 64 are accepted" do
      localpart = "cap-" <> rand()
      own = alias_for(localpart)
      many = fn n -> [own | for(i <- 1..(n - 1)//1, do: alias_for("filler-#{i}-" <> rand()))] end

      assert_rejected(
        [room_alias_name: localpart, initial_state_json: initial_state([entry("m.room.canonical_alias", %{"alt_aliases" => many.(65)})])],
        "M_INVALID_PARAM",
        "65 aliases"
      )

      # duplicates count once: 65 entries of one alias are a set of one
      resp =
        create_ok(
          room_alias_name: localpart,
          initial_state_json: initial_state([entry("m.room.canonical_alias", %{"alt_aliases" => List.duplicate(own, 65)})])
        )

      assert {own, resp.room_id} in registered_aliases()
    end
  end

  describe "cycle 1 - L-2: creation_content is bounded like initial_state content" do
    test "33 levels and a NUL (key or value) are M_BAD_JSON, no room; 32 levels are accepted" do
      for {label, content} <- [
            too_deep: nested(33),
            nul_value: %{"x" => "a\u0000b"},
            nul_key: %{"a\u0000b" => "x"},
            nul_nested: %{"x" => [%{"y" => "\u0000"}]}
          ] do
        assert_rejected([name: "Creation content #{label}", creation_content_json: Jason.encode!(content)], "M_BAD_JSON", "creation_content #{label}")
      end

      resp = create_ok(creation_content_json: Jason.encode!(nested(32)))
      assert [create] = state_events(resp.room_id, "m.room.create")
      assert create["content"]["room_version"] == "10"
    end
  end

  describe "cycle 1 - M5: strip_stacktrace_args/1" do
    test "every frame shape loses its argument list, keeps the arity" do
      loc = [file: ~c"x.ex", line: 1]
      fun = fn _ -> :ok end

      stripped =
        Server.strip_stacktrace_args([
          {Mod, :f, ["secret", "args"], loc},
          {Mod, :g, 3, loc},
          {fun, ["secret"], loc},
          {fun, 2, loc},
          {Mod, :h, 1}
        ])

      assert stripped == [{Mod, :f, 2, loc}, {Mod, :g, 3, loc}, {fun, 1, loc}, {fun, 2, loc}, {Mod, :h, 1}]
      refute inspect(stripped) =~ "secret"
    end
  end

  defmodule SpyAuditWriter do
    def log(actor, action, target_type, target_id, metadata, outcome, _detail \\ nil) do
      :ets.insert(:create_room_input_validation_test_db, {{:audit, make_ref()}, {actor, action, target_type, target_id, metadata, outcome}})
      :ok
    end
  end

  describe "cycle 1 - L-4: the room_created audit row carries the explicit alias" do
    defp audits(action),
      do: :ets.match(@ets, {{:audit, :_}, {:_, action, :_, :"$1", :"$2", :_}})

    test "an explicit alias is in the metadata, a create without one has no alias key" do
      Application.put_env(:compliance, :audit_writer, SpyAuditWriter)
      localpart = "audit-" <> rand()

      with_alias = create_ok(room_alias_name: localpart, name: "Audited")
      without_alias = create_ok(name: "Not audited alias")

      assert [metadata] = for [target, md] <- audits("room_created"), target == with_alias.room_id, do: md
      assert metadata["alias"] == alias_for(localpart)
      assert is_boolean(metadata["is_direct"])

      assert [metadata] = for [target, md] <- audits("room_created"), target == without_alias.room_id, do: md
      refute Map.has_key?(metadata, "alias")
    end
  end

  describe "cycle 1 - I-5: the client-supplied event type in a log line is quoted and bounded" do
    test "a type with a line break cannot forge a log line and a long type is truncated" do
      # story event-size-limit (DELIBERATE re-pin, finding of the ATDD step; old -> new): the type used to be 29 + 400 bytes, which the new step 5g refuses
      # (`413`, an initial_state type above 255 bytes) before the write path this test needs is reached. The type is 29 + 200 = 229 bytes now (within the limit);
      # the intent is unchanged: a line break cannot forge a log line, and a type longer than the 80 printable characters of `log_type/1` is truncated.
      forged = "m.test.x\n[error] forged line " <> String.duplicate("z", 200)
      :ets.insert(@ets, {{:fail_insert, forged}, :simulated_db_down})

      ref = make_ref()
      log = capture_log(fn -> send(self(), {ref, create(initial_state_json: initial_state([entry(forged, %{})]))}) end)
      assert_received {^ref, {:error, {500, _, _}}}

      refute log =~ "\n[error] forged line", "the type must not start a new log line"
      refute log =~ String.duplicate("z", 60), "the type is truncated to the 80 printable characters of log_type/1 (29 are the prefix: at most 51 z remain)"
      assert log =~ "m.test.x"
    end
  end
end
