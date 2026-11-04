defmodule Nebu.Admin.ConfigSessionLifetimeDbTest do
  @moduledoc """
  Story `session-lifetime-setting`, scenarios 2, 3 and 6 against the REAL database (integration; the runtime role `nebu_app` under FORCE RLS, the REAL
  `Nebu.Compliance.AuditWriter`, no seam but the audit writer module of the failure test): the save of the key `matrix_session_ttl_seconds` and its audit
  row happen in ONE transaction, the second save UPDATEs the existing row (the migration 000056 allowlist: without it that save fails with an RLS error), a
  refused value writes nothing, a failing audit writer leaves the stored value as it was.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L

  @page "/admin/config"
  @post "/admin/config/session-lifetime"
  @field "matrix_session_ttl_seconds"

  defmodule FailingAudit do
    @moduledoc false
    def log(_actor, _action, _type, _id, _metadata, _outcome, _detail \\ nil), do: {:error, :audit_write_failed}
  end

  setup do
    L.real_seams!()
    T.put_env_scoped(:admin_csrf_bypass, true)
    T.clear_oauth_config()
    L.clear_env_ttl!()
    L.delete_row!()
    L.clear_audit_rows!()

    on_exit(fn ->
      L.clear_audit_rows!()
    end)

    :ok
  end

  defp post(value, opts \\ []), do: S.post(@post, %{@field => value}, @page, Keyword.merge([ago: 10], opts))

  test "the page of the real database shows the saved value" do
    L.set_row!("7200")
    conn = S.get(@page, ago: 30)
    assert conn.status == 200
    doc = S.doc(conn)
    assert Floki.attribute(Floki.find(doc, "input#session-lifetime-input"), "value") == ["7200"]
    assert S.norm(hd(Floki.find(doc, "#session-lifetime-current"))) =~ "2 hours"
  end

  test "scenario 6: 8 hours saved, 2 hours entered: the row is 7200 and exactly ONE audit row holds the admin, the setting and the two numbers" do
    L.set_row!("28800")
    conn = post("7200")
    assert conn.status in [302, 303]
    assert L.row_value() == "7200"

    assert [row] = L.audit_rows()
    assert row["actor_user_id"] == "@admin:test.local"
    assert row["action"] == "session_lifetime_changed"
    assert row["target_type"] == "server_config"
    assert row["target_id"] == "matrix_session_ttl_seconds"
    assert row["outcome"] == "success"
    assert row["metadata"] == %{"before_seconds" => 28_800, "after_seconds" => 7200}
  end

  test "nothing saved yet: the first save INSERTs the row (old number = the 8 hour default), the second UPDATEs it (the RLS allowlist of migration 000056)" do
    assert L.row_value() == nil

    assert post("7200").status in [302, 303]
    assert L.row_value() == "7200"

    assert post("10800").status in [302, 303], "the UPDATE of the existing row must not fail with an RLS error"
    assert L.row_value() == "10800"

    assert post("3600").status in [302, 303]
    assert L.row_value() == "3600"

    rows = L.audit_rows()
    assert Enum.map(rows, & &1["metadata"]) == [
             %{"before_seconds" => 28_800, "after_seconds" => 7200},
             %{"before_seconds" => 7200, "after_seconds" => 10_800},
             %{"before_seconds" => 10_800, "after_seconds" => 3600}
           ]
  end

  test "'no change' means the SAVED value: with nothing saved the default (28800) entered is persisted and audited" do
    assert L.row_value() == nil
    assert post("28800").status in [302, 303]
    assert L.row_value() == "28800"
    assert [row] = L.audit_rows()
    assert row["metadata"] == %{"before_seconds" => 28_800, "after_seconds" => 28_800}
  end

  test "an update really changes the row (a policy that silently turns the UPDATE into a no-op would leave the old value)" do
    L.set_row!("7200")
    assert T.sql!("UPDATE server_config SET value = '3600' WHERE key = $1", [@field]).num_rows == 1
  end

  test "scenario 3: a refused value (100 days, text, blank) changes nothing and audits nothing; the stored value is unchanged" do
    L.set_row!("7200")

    for raw <- ["8640000", "3599", "abc", "", "7200.5"] do
      conn = post(raw)
      assert conn.status == 200, inspect(raw)
      assert L.row_value() == "7200", inspect(raw)
      assert L.audit_rows() == [], inspect(raw)
    end
  end

  test "scenario 3 with nothing stored: a refused value stores nothing at all" do
    assert post("8640000").status == 200
    assert L.row_value() == nil
    assert L.audit_rows() == []
  end

  test "the same value again is no change: no write, no audit row" do
    L.set_row!("7200")
    assert post("7200").status in [302, 303]
    assert L.audit_rows() == []
    assert L.row_value() == "7200"
  end

  test "an audit writer that fails leaves the stored value as it was and writes no row (one transaction); the mandatory audit applies to a shorter and a longer lifetime" do
    T.put_env_scoped(:audit_writer, FailingAudit, :compliance)
    L.set_row!("28800")

    for value <- ["7200", "86400"] do
      capture_log(fn -> send(self(), {:conn, post(value)}) end)
      assert_received {:conn, conn}
      assert conn.status in [302, 303]
      assert L.row_value() == "28800", "refused: the old value stays (#{value})"
    end

    assert L.audit_rows() == []
  end

  test "an audit writer that fails with nothing stored does not create the row" do
    T.put_env_scoped(:audit_writer, FailingAudit, :compliance)
    capture_log(fn -> send(self(), {:conn, post("7200")}) end)
    assert_received {:conn, _conn}
    assert L.row_value() == nil
  end

  test "without a fresh sign-in nothing is written and nothing is audited" do
    L.set_row!("28800")
    conn = S.post(@post, %{@field => "7200"})
    assert conn.status in [302, 303]
    assert L.row_value() == "28800"
    assert L.audit_rows() == []
  end

  test "the log of a save carries no raw submitted value of a refused save" do
    log = capture_log(fn -> send(self(), {:conn, post("canary-db-lt-5521")}) end)
    assert_received {:conn, conn}
    assert conn.status == 200
    refute log =~ "canary-db-lt-5521", log
  end
end
