defmodule Nebu.Matrix.SpaceEditAuditTest do
  @moduledoc """
  Story `space-edit-audit` (follow-up `dj`), unit part (no database): the audit rows of `Nebu.Matrix.set_space_state/5`
  (decisions D1 - D5, acceptance criteria 1 - 5, plus the unit-level guards of 7 and 8).

  Seam (the SAME one the Dispatcher uses, `Nebu.Matrix.EventDispatcher.Server.audit_writer_module/0`): `Application.get_env(:compliance, :audit_writer,
  Nebu.Compliance.AuditWriter)`. `Nebu.Matrix.set_space_state/5` must read the audit writer from this key at CALL time (not at compile time) and call
  `writer.log(actor, action, "room", room_id, metadata, "success")` (6 args; a 7th `error_detail` arg is tolerated by the fake).

  The room side is faked exactly like `event_dispatcher/set_room_state_test.exs` (FakeRoomRegistry + FakeDB through the `:event_dispatcher` env keys), so the
  real `Dispatcher.set_room_state/2` authorization and the real `emit_state_event/5` run; only persistence and the audit writer are fakes.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.OAuth.TestSupport, as: T

  @admin "@admin:test.local"
  @space "!space:test.local"
  @child "!child:test.local"
  @signing_key_seed :crypto.strong_rand_bytes(32)

  # ── fakes ────────────────────────────────────────────────────────────────────

  defmodule FakeRoomRegistry do
    @moduledoc false
    def get_state(room_id) do
      case :ets.lookup(:space_edit_audit_reg, {:room, room_id}) do
        [{_, state}] -> state
        [] -> exit({:noproc, {GenServer, :call, [room_id]}})
      end
    end

    # story state-writer-redaction (D8, AC12 (e)): the room-process writer behind the registry seam: the event and (m.room.name, empty state key) rooms.name
    def write_state(room_id, sender, {type, state_key}, content, _opts) do
      alias Nebu.Matrix.SpaceEditAuditTest.FakeDB

      event = %{
        "event_id" => "$fake" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        "room_id" => room_id,
        "type" => type,
        "state_key" => state_key,
        "sender" => sender,
        "content" => content,
        "origin_server_ts" => System.system_time(:millisecond)
      }

      with :ok <- FakeDB.insert_event(event),
           :ok <- if(type == "m.room.name" and state_key == "", do: FakeDB.update_room_name(room_id, if(is_binary(content["name"]), do: content["name"], else: "")), else: :ok) do
        {:ok, event["event_id"]}
      else
        # ONE transaction: a failing write leaves neither the event nor rooms.name behind
        {:error, _reason} ->
          :ets.delete(:space_edit_audit_db, {:event, event["event_id"]})
          {:error, :write_failed}
      end
    end
  end

  defmodule FakeDB do
    @moduledoc false
    def insert_event(event) do
      case :ets.lookup(:space_edit_audit_db, :insert_event_result) do
        [{_, {:error, _} = err}] ->
          err

        _ ->
          :ets.insert(:space_edit_audit_db, {{:event, event["event_id"]}, event})
          :ok
      end
    end

    def update_room_name(room_id, name) do
      :ets.insert(:space_edit_audit_db, {{:room_name, room_id}, name})
      :ok
    end

    def get_room_create_event(_room_id), do: {:error, :not_found}

    # story power-levels-enforcement (fix cycle 1, review I4): the PUT of m.room.power_levels goes to the room-process writer, which
    # never starts a process for a room without a `rooms` row; the space of this fake world has no row (only a fake registry entry)
    # (state-writer-redaction, D10 (a): PUT state of the other types needs a known room; a room of the fake registry is one; a room without an entry is not)
    def get_room_status(room_id) do
      case :ets.lookup(:space_edit_audit_reg, {:room, room_id}) do
        [{_, _state}] -> {:ok, "active"}
        [] -> {:error, :not_found}
      end
    end
  end

  # Records every audit call into the test process; `event_present` says whether the event id of the metadata was ALREADY persisted when the row was written
  # ("the row is written after a SUCCESSFUL write", D2).
  defmodule FakeAuditWriter do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      present =
        case metadata do
          %{"event_id" => eid} -> :ets.member(:space_edit_audit_db, {:event, eid})
          _ -> false
        end

      send(Application.get_env(:compliance, :__space_edit_audit_pid__), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail, present})
      Application.get_env(:compliance, :__space_edit_audit_result__, :ok)
    end
  end

  # ArgumentError, NOT RuntimeError: AuditWriter.do_log already rescues the usual runtime errors itself, so this pins the catch at the call site.
  defmodule RaisingAuditWriter do
    @moduledoc false
    def log(_a, _b, _c, _d, _e, _f, _g \\ nil), do: raise(ArgumentError, "audit writer exploded")
  end

  # An exit of the writer, e.g. a DB pool checkout timeout (`catch :exit`).
  defmodule ExitingAuditWriter do
    @moduledoc false
    def log(_a, _b, _c, _d, _e, _f, _g \\ nil), do: exit(:timeout)
  end

  setup do
    for tab <- [:space_edit_audit_reg, :space_edit_audit_db] do
      if :ets.info(tab) != :undefined, do: :ets.delete(tab)
      :ets.new(tab, [:named_table, :public, :set])
    end

    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519, @signing_key_seed)
    :persistent_term.put(:nebu_signing_key, {pub, priv})

    Application.put_env(:event_dispatcher, :room_registry_module, FakeRoomRegistry)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    prior_server_name = Application.fetch_env(:event_dispatcher, :server_name)
    Application.put_env(:event_dispatcher, :server_name, "test.local")
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter)
    Application.put_env(:compliance, :__space_edit_audit_pid__, self())
    Application.delete_env(:compliance, :__space_edit_audit_result__)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      for k <- [:room_registry_module, :messages_db_module, :rooms_db_module], do: Application.delete_env(:event_dispatcher, k)

      # restore (not delete) the suite-wide server name: a later suite (the createRoom presets HTTP test) derives room ids and
      # the local-domain check of the Admin force-add from it
      case prior_server_name do
        {:ok, value} -> Application.put_env(:event_dispatcher, :server_name, value)
        :error -> Application.delete_env(:event_dispatcher, :server_name)
      end

      for k <- [:audit_writer, :__space_edit_audit_pid__, :__space_edit_audit_result__], do: Application.delete_env(:compliance, k)
      for tab <- [:space_edit_audit_reg, :space_edit_audit_db], do: if(:ets.info(tab) != :undefined, do: :ets.delete(tab))
    end)

    register_room(@space, [@admin, "@bob:test.local"], pl_with(%{@admin => 100}))
    :ok
  end

  defp register_room(room_id, members, power_levels),
    do: :ets.insert(:space_edit_audit_reg, {{:room, room_id}, %{members: MapSet.new(members), power_levels: power_levels}})

  defp pl_with(user_levels), do: Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.put("users", user_levels)

  defp emitted(event_id), do: :ets.lookup(:space_edit_audit_db, {:event, event_id}) |> Enum.map(&elem(&1, 1)) |> List.first()

  # The audit call happens SYNCHRONOUSLY in the caller process, so after `set_space_state/5` returned the message is already in the mailbox (or never will be):
  # assert_received / refute_received are deterministic and pin "synchronously after the event" (no timing windows).
  # Exactly one audit call, nothing more.
  defp assert_one_audit do
    assert_received {:audit, _, _, _, _, _, _, _, _} = msg
    refute_received {:audit, _, _, _, _, _, _, _, _}
    msg
  end

  defp refute_any_audit, do: refute_received({:audit, _, _, _, _, _, _, _, _})

  # ── AC1: m.room.name -> space_name_changed ──────────────────────────────────

  describe "AC1 - set_space_state/5 with m.room.name" do
    test "writes exactly one space_name_changed row: actor = sender, target room = the space, metadata name + event_id, outcome success, AFTER the event is persisted" do
      assert {:ok, event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.name", "", %{"name" => "Engineering"})

      assert {:audit, @admin, "space_name_changed", "room", @space, metadata, "success", _detail, event_present} = assert_one_audit()
      assert metadata == %{"name" => "Engineering", "event_id" => event_id}
      assert event_present, "the row is written AFTER the successful write, so the event is already persisted (D2)"
      assert emitted(event_id)["content"] == %{"name" => "Engineering"}
    end
  end

  # ── AC2: topic / child added / child removed ────────────────────────────────

  describe "AC2 - the other three edits" do
    test "m.room.topic -> one space_topic_changed row with metadata topic + event_id" do
      assert {:ok, event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{"topic" => "All things build"})

      assert {:audit, @admin, "space_topic_changed", "room", @space, metadata, "success", _, true} = assert_one_audit()
      assert metadata == %{"topic" => "All things build", "event_id" => event_id}
    end

    test "m.space.child with content -> one space_child_added row with metadata child_room_id (the state key) + event_id" do
      assert {:ok, event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.space.child", @child, %{"via" => ["test.local"]})

      assert {:audit, @admin, "space_child_added", "room", @space, metadata, "success", _, true} = assert_one_audit()
      assert metadata == %{"child_room_id" => @child, "event_id" => event_id}
    end

    test "m.space.child with an EMPTY content map (the unlink) -> one space_child_removed row, never space_child_added" do
      assert {:ok, event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.space.child", @child, %{})

      assert {:audit, @admin, "space_child_removed", "room", @space, metadata, "success", _, true} = assert_one_audit()
      assert metadata == %{"child_room_id" => @child, "event_id" => event_id}
    end

    test "any other allowed event type through this function (m.room.avatar) succeeds and writes NO audit row (D2: only the four edits are audited)" do
      assert {:ok, _event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.avatar", "", %{"url" => "mxc://test.local/abc"})
      refute_any_audit()
    end
  end

  # ── AC3: a failed write writes no row ───────────────────────────────────────

  describe "AC3 - a refused or failed state write writes NO audit row" do
    test "the sender is not a member of the space: {:error, _}, no row" do
      assert {:error, _} = Nebu.Matrix.set_space_state(@space, "@stranger:test.local", "m.room.name", "", %{"name" => "X"})
      refute_any_audit()
    end

    test "the sender is a member without the state_default power level: {:error, _}, no row, for all four edits" do
      for {type, key, content} <- [{"m.room.name", "", %{"name" => "X"}}, {"m.room.topic", "", %{"topic" => "X"}}, {"m.space.child", @child, %{"via" => ["a"]}}, {"m.space.child", @child, %{}}] do
        assert {:error, _} = Nebu.Matrix.set_space_state(@space, "@bob:test.local", type, key, content), "#{type}"
      end

      refute_any_audit()
    end

    # story power-levels-enforcement (AC16 re-pin): m.room.power_levels left the forbidden list (its own route, the room-process
    # writer); m.room.create takes its place as the second forbidden type
    test "a forbidden event type (m.room.create, m.room.member): {:error, _}, no row" do
      assert {:error, _} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.create", "", %{"creator" => @admin})
      assert {:error, _} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.member", "@x:test.local", %{"membership" => "join"})
      refute_any_audit()
    end

    # story power-levels-enforcement (fix cycle 1, review I4; relabelled in fix cycle 2, review MINOR-1): in THIS fake world the space
    # has no rooms row, so the room-process writer refuses m.room.power_levels (403) before anything could be audited. The property
    # "a COMMITTED power-level change through set_space_state/5 writes no space_* row" is pinned on a real room in
    # power_levels_fix_cycle1_test.exs.
    test "m.room.power_levels through set_space_state/5 for a space without a rooms row is refused: {:error, _}, no audit row" do
      assert {:error, _} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.power_levels", "", %{"users" => %{@admin => 100}})
      refute_any_audit()
    end

    test "the event cannot be persisted (insert_event returns {:error, _}): {:error, _}, no row" do
      :ets.insert(:space_edit_audit_db, {:insert_event_result, {:error, :db_down}})
      assert {:error, _} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.name", "", %{"name" => "X"})
      refute_any_audit()
    end
  end

  # ── AC4: a failing audit write changes nothing for the caller ───────────────

  describe "AC4 - a failing audit write does not change the result and does not raise" do
    test "{:error, :audit_write_failed} from the writer: the call still returns {:ok, event_id}, the event stays persisted" do
      Application.put_env(:compliance, :__space_edit_audit_result__, {:error, :audit_write_failed})

      assert {:ok, event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.name", "", %{"name" => "Engineering"})
      assert_one_audit()
      assert emitted(event_id)
    end

    test "{:error, :audit_unknown_action} from the writer: the call still returns {:ok, event_id}" do
      Application.put_env(:compliance, :__space_edit_audit_result__, {:error, :audit_unknown_action})

      assert {:ok, _event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.space.child", @child, %{"via" => ["a"]})
      assert_one_audit()
    end

    test "a writer that RAISES (ArgumentError): {:ok, event_id}, no exception; the log has action + room id, never the topic" do
      Application.put_env(:compliance, :audit_writer, RaisingAuditWriter)

      log =
        capture_log(fn ->
          send(self(), {:result, Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{"topic" => "Secret Topic 4711"})})
        end)

      assert_received {:result, {:ok, event_id}}
      assert is_binary(event_id)
      assert emitted(event_id)
      assert log =~ "space_topic_changed"
      assert log =~ @space
      refute log =~ "Secret Topic 4711", "No Sensitive Data in Logs: neither name nor topic is logged"
    end

    test "a writer that EXITS (exit(:timeout), e.g. a pool checkout timeout) does not break the edit either: {:ok, event_id}, no exit to the caller" do
      Application.put_env(:compliance, :audit_writer, ExitingAuditWriter)

      capture_log(fn ->
        send(self(), {:result, Nebu.Matrix.set_space_state(@space, @admin, "m.room.name", "", %{"name" => "N"})})
      end)

      assert_received {:result, {:ok, event_id}}
      assert emitted(event_id)
    end

    # Story create-room-input-validation (D5c): a non-null, non-string name (42, ...) is now refused by set_room_state/2
    # (400 M_BAD_JSON) BEFORE anything is persisted or audited, so the "malformed content" shapes that still reach the audit
    # metadata building are the ones without a name: `{}` and `{"name": null}`.
    test "m.room.name without a name ({} and null) does not change the result {:ok, event_id} and crashes nothing in the audit metadata building" do
      capture_log(fn ->
        send(self(), {:result, Nebu.Matrix.set_space_state(@space, @admin, "m.room.name", "", %{})})
        send(self(), {:result, Nebu.Matrix.set_space_state(@space, @admin, "m.room.name", "", %{"name" => nil})})
      end)

      assert_received {:result, {:ok, e1}}
      assert_received {:result, {:ok, e2}}
      assert emitted(e1) && emitted(e2)

      # the row is still written (the edit stays visible and linked to its event), with a null name
      assert_received {:audit, _, "space_name_changed", _, _, %{"name" => nil, "event_id" => ^e1}, "success", _, _}
      assert_received {:audit, _, "space_name_changed", _, _, %{"name" => nil, "event_id" => ^e2}, "success", _, _}
    end

    # Story create-room-presets-power-levels-topic (D5, AC8 / AC16): `m.room.topic` has a content rule now on EVERY writer
    # (non-string `topic` = 400 M_BAD_JSON), so the case that used to pin "a non-string topic does not crash the audit metadata
    # building" ({"topic": 42} -> ok) asserts the REFUSAL: `{:error, _}`, nothing persisted, no audit row. The nil guard of the
    # audit metadata (audit_slice/1 -> nil) stays reachable through the topic values the rule still accepts: `null` and an absent
    # `topic` (second test).
    test "m.room.topic with a non-string topic ({\"topic\": 42}) is refused: {:error, _}, no event, no audit row" do
      capture_log(fn ->
        send(self(), {:result, Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{"topic" => 42})})
      end)

      assert_received {:result, {:error, _}}
      assert :ets.match(:space_edit_audit_db, {{:event, :_}, :"$1"}) == []
      refute_any_audit()
    end

    test "m.room.topic with a null topic and with no topic ({}) does not crash the audit metadata building: {:ok, event_id}, row with a null topic" do
      capture_log(fn ->
        send(self(), {:result, Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{"topic" => nil})})
        send(self(), {:result, Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{})})
      end)

      assert_received {:result, {:ok, e1}}
      assert_received {:result, {:ok, e2}}
      assert emitted(e1) && emitted(e2)
      assert_received {:audit, _, "space_topic_changed", _, _, %{"topic" => nil, "event_id" => ^e1}, "success", _, _}
      assert_received {:audit, _, "space_topic_changed", _, _, %{"topic" => nil, "event_id" => ^e2}, "success", _, _}
    end
  end

  # ── AC5: truncation to 256 characters ───────────────────────────────────────

  describe "AC5 - long values are truncated to 256 characters in the metadata only" do
    # Story create-room-input-validation (D5c): names are capped at 255 code points on every writer, so this stress case moved to the topic.
    # Story create-room-presets-power-levels-topic (D5, AC16): the topic is capped at 1024 code points on every writer as well, so the
    # 100001 code point case is refused (next test) and this one uses the largest topic that is still accepted: one grapheme of 1024 code
    # points ("a" + 1023 combining marks = 2047 bytes, MORE than the 1024 byte audit cap, so the truncation is still exercised).
    test "one grapheme of 1024 code points (2047 bytes): the metadata value is capped at 1024 bytes and stays valid UTF-8, the event content keeps all of it" do
      huge = "a" <> String.duplicate("\u0301", 1023)
      assert String.length(huge) == 1, "one grapheme"
      assert length(String.to_charlist(huge)) == 1024 and byte_size(huge) > 1024

      assert {:ok, event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{"topic" => huge})

      assert {:audit, _, "space_topic_changed", _, _, %{"topic" => topic}, "success", _, _} = assert_one_audit()
      assert byte_size(topic) <= 1024
      assert String.valid?(topic)
      assert String.starts_with?(topic, "a")
      assert emitted(event_id)["content"]["topic"] == huge
    end

    test "a topic of 1025 code points is refused by the topic cap: {:error, _}, no event, no audit row" do
      assert {:error, _} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{"topic" => String.duplicate("t", 1025)})

      assert :ets.match(:space_edit_audit_db, {{:event, :_}, :"$1"}) == []
      refute_any_audit()
    end

    # Story create-room-input-validation (D5c): a name of 300 characters is no longer writable (cap 255): the edit is refused, nothing
    # is persisted and no audit row is written. (The truncation of a long TOPIC is the next test.)
    test "a 300 character name is refused by the name cap: {:error, _}, no event, no audit row" do
      long = String.duplicate("a", 300)
      assert {:error, _} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.name", "", %{"name" => long})

      assert :ets.match(:space_edit_audit_db, {{:event, :_}, :"$1"}) == []
      refute_any_audit()
    end

    test "a 255 character name is stored whole in the metadata (the cap itself)" do
      name255 = String.duplicate("a", 255)
      assert {:ok, event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.name", "", %{"name" => name255})

      assert {:audit, _, "space_name_changed", _, _, %{"name" => ^name255}, "success", _, _} = assert_one_audit()
      assert emitted(event_id)["content"]["name"] == name255
    end

    test "a 300 character topic is truncated the same way (multibyte characters count as characters, not bytes)" do
      long = String.duplicate("ü", 300)
      assert {:ok, event_id} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{"topic" => long})

      assert {:audit, _, "space_topic_changed", _, _, %{"topic" => topic}, "success", _, _} = assert_one_audit()
      assert String.length(topic) == 256
      assert topic == String.slice(long, 0, 256)
      assert emitted(event_id)["content"]["topic"] == long
    end

    # (moved from the name to the topic by story create-room-input-validation: a name of 256 / 257 characters is refused by the cap)
    test "a value of exactly 256 characters is stored whole (boundary), 257 is cut to 256" do
      exact = String.duplicate("b", 256)
      assert {:ok, _} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{"topic" => exact})
      assert {:audit, _, _, _, _, %{"topic" => ^exact}, _, _, _} = assert_one_audit()

      assert {:ok, _} = Nebu.Matrix.set_space_state(@space, @admin, "m.room.topic", "", %{"topic" => exact <> "c"})
      assert {:audit, _, _, _, _, %{"topic" => ^exact}, _, _, _} = assert_one_audit()
    end
  end

  # ── AC8 (unit guard): the client path writes no space audit row ─────────────

  describe "AC8 (unit guard) - the generic client path Dispatcher.set_room_state/2 writes no admin audit row" do
    test "set_room_state/2 with m.room.name, m.room.topic and m.space.child (with content and unlink) emits events but calls the audit writer NEVER" do
      for {type, key, content} <- [{"m.room.name", "", %{"name" => "Client edit"}}, {"m.room.topic", "", %{"topic" => "Client edit"}}, {"m.space.child", @child, %{"via" => ["a"]}}, {"m.space.child", @child, %{}}] do
        req = %Core.SetRoomStateRequest{room_id: @space, sender_id: @admin, event_type: type, state_key: key, content_json: Jason.encode!(content)}
        assert %Core.SetRoomStateResponse{event_id: eid} = Server.set_room_state(req, %{http_request_headers: %{}})
        assert emitted(eid), type
      end

      refute_any_audit()
    end
  end

  # ── AC7 (unit guard): the controller seam stays working ─────────────────────

  describe "AC7 (unit guard) - the :admin_spaces_state_writer seam of the controller stays" do
    @endpoint Nebu.Admin.Endpoint
    @secret_key_base String.duplicate("nebu-space-edit-audit-key-base", 3)

    test "POST /admin/spaces/:id with the seam installed calls the seam twice (name, then topic) and redirects" do
      test_pid = self()
      Application.put_env(:nebu_http, :admin_csrf_bypass, true)

      Application.put_env(:nebu_http, :admin_spaces_state_writer, fn room, actor, type, key, content ->
        send(test_pid, {:seam, room, actor, type, key, content})
        {:ok, "$seam-event"}
      end)

      on_exit(fn -> for k <- [:admin_csrf_bypass, :admin_spaces_state_writer], do: Application.delete_env(:nebu_http, k) end)

      params = %{"name" => "Seam Space", "topic" => "Seam Topic"}

      conn =
        %{conn(:post, "/admin/spaces/" <> URI.encode(@space, &URI.char_unreserved?/1)) | secret_key_base: @secret_key_base}
        |> @endpoint.admin_session([])
        |> fetch_session()
        |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => @admin})
        |> Map.put(:body_params, params)
        |> Map.put(:params, params)
        |> T.put_strict_fetch_headers()
        |> then(fn c -> @endpoint.call(c, @endpoint.init([])) end)

      assert conn.status in [302, 303]
      assert_received {:seam, @space, @admin, "m.room.name", "", %{"name" => "Seam Space"}}
      assert_received {:seam, @space, @admin, "m.room.topic", "", %{"topic" => "Seam Topic"}}
      # (no `refute_any_audit()` here: the seam replaces Nebu.Matrix.set_space_state/5 entirely, so a missing audit call would prove nothing; the audit rows of the real path are in
      # space_edit_audit_integration_test.exs)
    end
  end
end
