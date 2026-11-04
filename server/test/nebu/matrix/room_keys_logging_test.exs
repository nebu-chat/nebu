defmodule Nebu.Matrix.RoomKeysLoggingTest do
  @moduledoc """
  Acceptance tests (REAL database) of the "No Sensitive Data in Logs" law for story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011): the session blobs
  (`session_data`) and `auth_data` of a key backup are opaque, client-encrypted USER CONTENT and must never reach a log line, at ANY level.

  `Nebu.Web.Plugs.RequestLogger` captures (redacted) request and response bodies at `:debug`; the account-data and room-tag routes opt out entirely (their bodies are never captured, not even
  redacted). The `room_keys` routes must do the same: this is pinned by running every route with CANARY strings in the blobs under a `:debug` Logger and asserting that no canary appears in
  the captured output (request line present = the logger did run, so the check is not vacuous). The Ecto query logger is off by configuration (bound parameters would carry the blobs); the
  handler's own failure logs carry the error KIND only (a failing write answers a generic 500 and logs no row data and no database message).

  (Phoenix `filter_parameters` only applies to the Phoenix admin endpoint; the Matrix routes are plain `Plug.Router` routes, so the request logger is the only capture path to pin.)
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.RoomKeysTestSupport, as: RK

  @moduletag :integration

  @room "!logroom:test.local"
  @algo RK.algorithm()

  setup do
    RK.disable_rate_limit()
    {:ok, u: RK.user!(), canary: "CANARY-" <> Nebu.OAuth.TestSupport.rand(8)}
  end

  defp logged(fun), do: RK.with_log_level(:debug, fn -> capture_log([level: :debug], fun) end)

  describe "no blob is ever logged" do
    test "every room_keys route with canaries in auth_data and session_data, captured at :debug", %{u: u, canary: c} do
      log =
        logged(fn ->
          v = RK.create!(u, %{"public_key" => "pk-#{c}-ad1", "signatures" => %{"@x:test.local" => %{"ed25519:A" => "sig-#{c}-ad1"}}})
          assert RK.put_version(u.at, v, %{"algorithm" => @algo, "auth_data" => %{"public_key" => "pk-#{c}-ad2"}}).status == 200

          k = fn tag -> RK.kbd(1, 0, false, %{"ciphertext" => "ct-#{c}-#{tag}", "ephemeral" => "eph-#{c}-#{tag}", "mac" => "mac-#{c}-#{tag}"}) end
          assert RK.put_rooms(u.at, v, %{@room => %{"s1" => k.("rooms")}}).status == 200
          assert RK.put_room(u.at, v, @room, %{"s2" => k.("room")}).status == 200
          assert RK.put_session(u.at, v, @room, "s3", k.("session")).status == 200

          assert RK.get_version(u.at).status == 200
          assert RK.get_version(u.at, v).status == 200
          assert RK.get_keys(u.at, v).status == 200
          assert RK.get_keys(u.at, v, @room).status == 200
          assert RK.get_keys(u.at, v, @room, "s1").status == 200

          assert RK.delete_keys(u.at, v, @room, "s1").status == 200
          assert RK.delete_keys(u.at, v, @room).status == 200
          assert RK.delete_keys(u.at, v).status == 200
          assert RK.delete_version(u.at, v).status == 200
        end)

      assert log =~ "room_keys", "precondition: the request logger ran for these routes"
      refute log =~ c, "a blob reached a log line"
    end

    test "refused requests (400, 403, 404, 413) with canaries in the body log no blob either", %{u: u, canary: c} do
      v = RK.create!(u)
      older = v
      _current = RK.create!(u)

      log =
        logged(fn ->
          # 413: oversize session_data and oversize auth_data
          big = %{"c" => c, "pad" => String.duplicate("x", 9_000)}
          assert RK.put_session(u.at, RK.info!(u.at)["version"], @room, "big", RK.kbd(1, 0, false, big)).status == 413
          assert RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => %{"c" => c, "pad" => String.duplicate("x", 17_000)}}).status == 413
          # 400: invalid members next to blobs
          assert RK.post_version(u.at, %{"algorithm" => "nope", "auth_data" => %{"c" => c}}).status == 400
          assert RK.put_session(u.at, RK.info!(u.at)["version"], @room, "bad", RK.kbd(-1, 0, false, %{"c" => c})).status == 400
          assert RK.req(:put, RK.keys_path(nil, @room), u.at, %{"sessions" => %{"s" => %{"session_data" => %{"c" => c}}}}).status == 400
          # 400 malformed JSON carrying the canary
          assert RK.req(:post, RK.version_path(), u.at, {:raw, ~s({"auth_data": {"c": "#{c}"} oops)}).status == 400
          # 403 wrong version, 404 unknown version
          assert RK.put_session(u.at, older, @room, "s", RK.kbd(1, 0, false, %{"c" => c})).status == 403
          assert RK.put_version(u.at, "424242", %{"algorithm" => @algo, "auth_data" => %{"c" => c}}).status == 404
        end)

      assert log =~ "room_keys"
      refute log =~ c
    end

    test "a user's blobs are not logged when ANOTHER user reads or writes the same version number", %{u: u, canary: c} do
      v = RK.create!(u, RK.auth_data(c))
      assert RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false, %{"c" => c})).status == 200
      other = RK.user!()

      log =
        logged(fn ->
          RK.get_keys(other.at, v)
          RK.get_version(other.at, v)
          RK.put_session(other.at, v, @room, "s", RK.kbd(1, 0, false, %{"c" => c}))
        end)

      refute log =~ c
    end

    # cycle 1 (Kassandra LOW 5): the room and session ids of the PATH are client-chosen content as well; the request log prints the route template, which must replace them
    test "client-chosen room and session ids of the path (a non-sigil room id, any session id) never reach the log, on every route and at every level", %{u: u, canary: c} do
      v = RK.create!(u)
      room = "plainroom-#{c}"
      sid = "client-session-#{c}"

      log =
        logged(fn ->
          assert RK.put_session(u.at, v, room, sid, RK.kbd(1, 0, false)).status == 200
          assert RK.put_room(u.at, v, room, %{"other-#{c}" => RK.kbd(1, 0, false)}).status == 200
          assert RK.get_keys(u.at, v, room, sid).status == 200
          assert RK.get_keys(u.at, v, room).status == 200
          assert RK.get_keys(u.at, v, room, "missing-#{c}").status == 404
          assert RK.delete_keys(u.at, v, room, sid).status == 200
          assert RK.delete_keys(u.at, v, room).status == 200
          # a refused one: a wrong version (the version is a query parameter, no secret: it is not part of the template)
          assert RK.put_session(u.at, "424242", room, sid, RK.kbd(1, 0, false)).status == 403
        end)

      assert log =~ "room_keys", "precondition: the request logger ran"
      refute log =~ c, "a client-chosen id of the path reached a log line"
    end
  end

  describe "a failing database write: generic 500, no row data and no database message" do
    test "a blocked UPDATE of a session row (replace): 500 M_UNKNOWN, nothing changed, the log has no canary and no database message", %{u: u, canary: c} do
      v = RK.create!(u)
      old = RK.kbd(10, 0, false, %{"c" => "OLD-#{c}"})
      assert {1, etag} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", old))
      # UPDATE and DELETE are both refused, so the replace fails whichever mechanism the implementation uses (in-place update or delete + insert)
      E.block!(RK.sessions_table(), "UPDATE", u.uid)
      E.block!(RK.sessions_table(), "DELETE", u.uid)

      log =
        logged(fn ->
          send(self(), {:resp, RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, true, %{"c" => "NEW-#{c}"}))})
        end)

      assert_received {:resp, resp}
      assert resp.status == 500, "got #{resp.status} #{resp.resp_body}"
      body = RK.json(resp)
      assert body["errcode"] == "M_UNKNOWN"
      refute resp.resp_body =~ c
      refute resp.resp_body =~ "forced failure", "no database message in the answer"
      refute log =~ c
      refute log =~ "forced failure", "the failure is logged by its kind only, never the database message"

      assert RK.info!(u.at, v)["etag"] == etag and RK.info!(u.at, v)["count"] === 1
      assert RK.sessions!(u.at, v)[{@room, "s"}] == old, "the failed write was rolled back"
    end

    test "a batch of a NEW and a REPLACING session while the replace fails: 500, the new one is not stored either", %{u: u, canary: c} do
      v = RK.create!(u)
      old = RK.kbd(10, 0, false, %{"c" => "OLD-#{c}"})
      assert {1, etag} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", old))
      E.block!(RK.sessions_table(), "UPDATE", u.uid)
      E.block!(RK.sessions_table(), "DELETE", u.uid)

      log =
        logged(fn ->
          batch = %{"fresh" => RK.kbd(1, 0, false, %{"c" => "FRESH-#{c}"}), "s" => RK.kbd(1, 0, true, %{"c" => "NEW-#{c}"})}
          send(self(), {:resp, RK.put_room(u.at, v, @room, batch)})
        end)

      assert_received {:resp, resp}
      assert resp.status == 500 and RK.json(resp)["errcode"] == "M_UNKNOWN", "got #{resp.status} #{resp.resp_body}"
      refute resp.resp_body =~ c
      refute log =~ c
      assert Map.keys(RK.sessions!(u.at, v)) == [{@room, "s"}], "the new session of the failed batch was stored"
      assert RK.sessions!(u.at, v)[{@room, "s"}] == old
      assert RK.info!(u.at, v)["etag"] == etag and RK.info!(u.at, v)["count"] === 1
    end

    # a trigger whose error message QUOTES the blob: Postgres errors do quote row values (constraint details, trigger messages); the server must not pass that on
    defp quoting_insert_fault!(table, column, uid) do
      name = "atdd_rk_ins_" <> Nebu.OAuth.TestSupport.rand(5)

      Nebu.OAuth.TestSupport.privileged_sql!(
        "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.user_id = '#{uid}' THEN RAISE EXCEPTION 'quoted row: %', NEW.#{column}; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
      )

      Nebu.OAuth.TestSupport.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()")

      ExUnit.Callbacks.on_exit(fn ->
        Nebu.OAuth.TestSupport.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
        Nebu.OAuth.TestSupport.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
      end)
    end

    test "a failing INSERT whose database error quotes session_data: 500, no canary in answer or log, nothing stored", %{u: u, canary: c} do
      v = RK.create!(u)
      quoting_insert_fault!(RK.sessions_table(), "session_data", u.uid)

      log = logged(fn -> send(self(), {:resp, RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false, %{"ciphertext" => "INS-#{c}"}))}) end)

      assert_received {:resp, resp}
      assert resp.status == 500 and RK.json(resp)["errcode"] == "M_UNKNOWN", "got #{resp.status} #{resp.resp_body}"
      refute resp.resp_body =~ c
      refute resp.resp_body =~ "quoted row"
      refute log =~ c
      refute log =~ "quoted row", "the failure is logged by its kind only"
      assert RK.rows(RK.sessions_table(), u.uid) == 0
      assert RK.info!(u.at, v)["count"] === 0
    end

    test "a failing INSERT of a version whose database error quotes auth_data: 500, no canary, no version", %{u: u, canary: c} do
      quoting_insert_fault!(RK.versions_table(), "auth_data", u.uid)

      log = logged(fn -> send(self(), {:resp, RK.post_version(u.at, %{"algorithm" => @algo, "auth_data" => %{"public_key" => "PK-#{c}"}})}) end)

      assert_received {:resp, resp}
      assert resp.status == 500 and RK.json(resp)["errcode"] == "M_UNKNOWN", "got #{resp.status} #{resp.resp_body}"
      refute resp.resp_body =~ c
      refute resp.resp_body =~ "quoted row"
      refute log =~ c
      refute log =~ "quoted row"
      assert RK.rows(RK.versions_table(), u.uid) == 0
      assert RK.get_version(u.at).status == 404
    end

    test "a blocked DELETE of the session rows: DELETE /version answers 500, the version is NOT deleted (one transaction), nothing is logged of the blobs", %{u: u, canary: c} do
      v = RK.create!(u, RK.auth_data("keep-" <> c))
      assert {1, _} = RK.count_etag!(RK.put_session(u.at, v, @room, "s", RK.kbd(1, 0, false, %{"c" => c})))
      remove = E.block!(RK.sessions_table(), "DELETE", u.uid)

      log = logged(fn -> send(self(), {:resp, RK.delete_version(u.at, v)}) end)
      assert_received {:resp, resp}
      assert resp.status == 500 and RK.json(resp)["errcode"] == "M_UNKNOWN", "got #{resp.status} #{resp.resp_body}"
      refute resp.resp_body =~ "forced failure"
      refute log =~ c
      refute log =~ "forced failure"

      remove.()
      assert RK.info!(u.at, v)["auth_data"] == RK.auth_data("keep-" <> c), "the version survived the failed delete"
      assert RK.info!(u.at, v)["count"] === 1
    end
  end
end
