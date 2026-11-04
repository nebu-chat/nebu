defmodule Nebu.Matrix.DeviceKeyDirectoryLoggingTest do
  @moduledoc """
  Acceptance tests (REAL database) of the "No Sensitive Data in Logs" law for story `device-key-directory` (REQ-2026-013, decision D14): key material (one-time keys, fallback keys, device
  keys, signatures), tokens (access tokens and the sync tokens of `from` / `to`) and the claim bodies must never reach a log line, at ANY level, on ANY path:

    * every happy path (upload, claim of a one-time key, of a fallback key, changes, sync with `device_lists`) with CANARY strings in the key material under a `:debug` Logger (the request
      lines are present, so the check is not vacuous);
    * every refused path (400 with a canary body, 401, 429, a 400 for a malformed token that carries a canary);
    * a failing statement whose database message QUOTES the row (a trigger raising `'quoted row: %'`): the answer is generic (500), neither the answer nor the log carries the canary, and
      nothing is half done (the key is still claimable after the fault is gone).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.DeviceKeyDirectoryTestSupport, as: DK
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    w = DK.world!()
    {:ok, w: w, canary: "CANARY-" <> T.rand(8)}
  end

  defp logged(fun), do: TD.with_log_level(:debug, fn -> capture_log([level: :debug], fun) end)

  defp refute_leaks(log, values) do
    for v <- values, do: refute(log =~ v, "the log contains #{String.slice(v, 0, 30)}...: #{String.slice(log, 0, 400)}")
  end

  # a fault whose database message QUOTES the row
  defp quoting_fault!(table, event) do
    name = "atdd_dk_fault_" <> T.rand(5)
    row = if event == "DELETE", do: "OLD", else: "NEW"
    T.privileged_sql!("CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'quoted row: %', row_to_json(#{row})::text; END $$ LANGUAGE plpgsql")
    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  describe "happy paths at :debug" do
    test "upload, claim (one-time and fallback key), changes and sync never log key material, tokens or the claimed key ids", %{w: w, canary: c} do
      otk = %{"key" => "otk-#{c}", "signatures" => %{"@x:test.local" => %{"ed25519:D" => "sig-#{c}"}}}
      fb = %{"key" => "fbk-#{c}", "fallback" => true, "signatures" => %{"@x:test.local" => %{"ed25519:D" => "fsig-#{c}"}}}
      keys = DK.device_keys(w.bob1, c)

      log =
        logged(fn ->
          from = DK.token(w.alice)
          DK.upload!(w.bob1, %{"device_keys" => keys, "one_time_keys" => %{"signed_curve25519:ID#{c}" => otk}, "fallback_keys" => %{"signed_curve25519:FB#{c}" => fb}})
          assert DK.claim_one!(w.alice, w.bob1) |> Map.values() == [otk]
          assert DK.claim_one!(w.alice, w.bob1) |> Map.values() == [fb]
          to = DK.token(w.alice)
          assert DK.changes!(w.alice, from, to)["changed"] == [w.bob1.uid]
          assert is_map(DK.sync(w.alice, to)["device_lists"])
          DK.sync(w.bob1)
        end)

      assert log =~ "keys/claim" or log =~ "claim", "the request lines are there (the check is not vacuous): #{String.slice(log, 0, 300)}"
      refute_leaks(log, ["otk-#{c}", "fbk-#{c}", "sig-#{c}", "fsig-#{c}", "ID#{c}", "FB#{c}", "curve-#{c}", "ed-#{c}", "devsig-#{c}", w.alice.at, w.bob1.at])
    end

    test "the sync tokens of `from` and `to` (and their positions) are not logged", %{w: w} do
      from = DK.token(w.alice)
      to = DK.token(w.alice)
      log = logged(fn -> DK.changes!(w.alice, from, to) end)
      assert log =~ "changes"
      refute_leaks(log, [from, to, hd(String.split(from, ".")), hd(String.split(to, "."))])
    end
  end

  describe "refused paths at :debug" do
    test "a 400 for a body that carries a canary in the algorithm, the user id and the device id logs none of them", %{w: w, canary: c} do
      log =
        logged(fn ->
          TD.assert_error(TD.req(:post, DK.claim_path(), w.alice.at, %{"one_time_keys" => %{"@u-#{c}:test.local" => %{"DEV-#{c}" => %{"alg-#{c}" => 1}}}}), 400, "M_BAD_JSON")
          TD.assert_error(TD.req(:post, DK.claim_path(), w.alice.at, {:raw, ~s({"one_time_keys": "#{c})}), 400, "M_NOT_JSON")
          DK.claim!(w.alice, %{"@u-#{c}:test.local" => %{"DEV-#{c}" => "alg-#{c}"}})
        end)

      assert log =~ "claim"
      refute_leaks(log, [c, w.alice.at])
    end

    test "a 400 for a malformed sync token with a canary, a 401 with a canary body and a 429 log none of it", %{w: w, canary: c} do
      TD.enable_rate_limit()

      log =
        logged(fn ->
          TD.assert_error(DK.changes_raw(w.alice, "?from=!!!#{c}&to=#{c}"), 400, "M_INVALID_PARAM")
          TD.assert_error(TD.req(:post, DK.claim_path(), "junk-#{c}", %{"one_time_keys" => %{"@u-#{c}:test.local" => %{"D-#{c}" => "a-#{c}"}}}), 401, "M_UNKNOWN_TOKEN")
          for _ <- 1..12, do: DK.claim(w.alice, %{"@gone-#{c}:test.local" => %{"D-#{c}" => "a-#{c}"}})
        end)

      assert log =~ "claim" or log =~ "changes"
      refute_leaks(log, [c, w.alice.at])
    end
  end

  describe "a failing statement whose database message quotes the row" do
    test "a claim whose UPDATE fails answers a generic 500, leaks nothing to the answer or the log, and is not half done", %{w: w, canary: c} do
      otk = %{"key" => "otk-#{c}", "signatures" => %{"@x:test.local" => %{"ed25519:D" => "sig-#{c}"}}}
      DK.upload!(w.bob1, %{"one_time_keys" => %{"signed_curve25519:ID#{c}" => otk}, "fallback_keys" => %{"signed_curve25519:FB#{c}" => %{"key" => "fbk-#{c}", "fallback" => true}}})
      remove = quoting_fault!("device_one_time_keys", "UPDATE")
      holder = self()

      log =
        logged(fn ->
          conn = DK.claim(w.alice, DK.target(w.bob1))
          send(holder, {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 500
      body = TD.json(conn)
      assert body["errcode"] == "M_UNKNOWN" and is_binary(body["error"])
      refute_leaks(conn.resp_body, [c, "quoted row", "otk-"])
      refute_leaks(log, [c, "otk-#{c}", "sig-#{c}", "quoted row"])
      remove.()
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1, "nothing was half done: the key is unclaimed"
      assert DK.fallback_row(w.bob1.uid, w.bob1.dev) == ["FB#{c}", false], "and the fallback key was not marked used"
      assert DK.claim_one!(w.alice, w.bob1) |> Map.values() == [otk]
    end
  end
end
