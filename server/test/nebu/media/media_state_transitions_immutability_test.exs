defmodule Nebu.Media.StateTransitionsImmutabilityTest do
  @moduledoc """
  Real-Postgres integration tests for the `media_state_transitions` append-only
  guarantee (ADR-031 §1, `MEDIA.1-INT-007`).

  Requires a live `Nebu.Repo` connection — run via
  `make test-integration` / `mix test --include integration` against a
  migrated database (`NEBU_DB_URL` must be set; see
  `server/test/nebu/admin/search_users_db_test.exs` for the same no-Sandbox
  convention this file follows: real connection, unique per-run ids, manual
  `on_exit` cleanup, `async: false`).

  RED by design: `media_state_transitions` (table, ENUM types, trigger) does
  not exist until migration `000022_media_state_machine_foundation` lands.
  Every test here fails with a `Postgrex.Error` (undefined_table /
  undefined_column) until that migration is applied to the test database.

  ## Dual-role discovery (CI-gate fix, not a design decision)

  This project's docker-compose deployment ALWAYS runs migrations as the
  `nebu_migrate` role (`server/Dockerfile`'s ENTRYPOINT + `docker-compose.yml`'s
  `NEBU_DB_URL_MIGRATE`) — including on a genuinely fresh volume — so
  `media_state_transitions` is owned by `nebu_migrate`, while every OTHER
  integration test (this file included, via `Nebu.Repo`) connects as
  `nebu_app`. This is the exact same fact `server/test/nebu/admin/war_room_manager_test.exs`
  already documents for `operational_logs`/`war_room_sessions`.

  That means `nebu_app` is never the table owner here, so this migration's own
  `REVOKE UPDATE, DELETE ... FROM nebu_app` (AC8, the *secondary* RLS/REVOKE
  layer) blocks `nebu_app`'s raw UPDATE/DELETE with `insufficient_privilege`
  (42501) BEFORE the trigger ever gets a chance to fire — the grant-check
  happens ahead of trigger execution. To actually observe the *primary*
  guarantee (AC7: the `BEFORE UPDATE OR DELETE` trigger raising SQLSTATE 23001
  for EVERY role, "including the table owner") we open a second, short-lived
  connection using the `nebu_migrate` role directly — the real table owner in
  this environment, which still holds full DML rights (never revoked) and so
  reaches the trigger. `nebu_migrate`'s dev password is the same hardcoded
  dev-only credential already used by `docker-compose.yml` /
  `dev/postgres/init/01-roles.sql` (never used in production, see that file's
  own "DEV ONLY" header).
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Repo

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "mst_immut_#{@run_id}_#{suffix}"

  # Opens a short-lived connection as `nebu_migrate` — the actual table owner
  # in this project's dual-role docker-compose deployment (see moduledoc).
  # Parses host/port/database out of NEBU_DB_URL (same env var Nebu.Repo
  # itself is configured from, per config/runtime.exs) the same way
  # Nebu.Release.parse_url/1 does, swapping only the credentials to the
  # migration role's dev-only password.
  #
  # Forward-looking note (code-review MINOR): `nebu_migrate` is documented as
  # LEGACY in `dev/postgres/init/01-roles.sql` ("no longer required for fresh
  # deployments... will eventually be removed"). If it is ever removed, this
  # helper (and the tests that need to reach the trigger as the true table
  # owner) must be updated to whatever role owns `media_state_transitions` at
  # that point — today that is still `nebu_migrate` because
  # `docker-compose.yml`'s `NEBU_DB_URL_MIGRATE` unconditionally runs ALL
  # migrations (including this one) as that role.
  defp migrate_role_conn! do
    url =
      System.get_env("NEBU_DB_URL") ||
        raise "NEBU_DB_URL is not set — this test requires a live PostgreSQL connection"

    uri = URI.parse(url)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: uri.host || "localhost",
        port: uri.port || 5432,
        database: String.trim_leading(uri.path || "", "/"),
        username: "nebu_migrate",
        password: "nebu_migrate_dev_pw"
      )

    conn
  end

  defp insert_media_file!(media_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted)
      VALUES ($1, 'test.local', 'application/octet-stream', 0, 'aeskeyhex', 'noncehex',
              '@tester:test.local', $2, false)
      """,
      [media_id, System.system_time(:millisecond)]
    )
  end

  defp insert_transition!(media_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_state_transitions (media_id, from_state, to_state, actor_type)
      VALUES ($1, NULL, 'reserved', 'system')
      RETURNING id
      """,
      [media_id]
    )
  end

  # code-review MINOR fix: cleanup must run as the table owner (nebu_migrate)
  # WITH the append-only trigger disabled. Via Nebu.Repo (nebu_app) the
  # DELETE on media_state_transitions is rejected by this migration's own
  # REVOKE (42501) — silently, since the original version used the non-bang
  # `query/3` — so transition rows were never actually removed, and the
  # follow-up `media_files` DELETE then failed on the FK too. `nebu_migrate`
  # is the table owner but the append-only trigger fires for every role
  # including the owner (that is the whole point of ADR-031), so plain
  # DELETEs as the owner still hit SQLSTATE 23001. `SET session_replication_role`
  # would sidestep the trigger but requires actual Postgres superuser, which
  # `nebu_migrate` is not (see dev/postgres/init/01-roles.sql). Table owners
  # CAN `ALTER TABLE ... DISABLE/ENABLE TRIGGER` their own tables without
  # superuser, so that's used instead — strictly test-teardown only, wrapped
  # so the trigger is always re-enabled even if a DELETE errors.
  defp cleanup!(media_id) do
    conn = migrate_role_conn!()

    try do
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions DISABLE TRIGGER media_state_transitions_no_mutate",
        []
      )

      Postgrex.query(conn, "DELETE FROM media_state_transitions WHERE media_id = $1", [media_id])
      Postgrex.query(conn, "DELETE FROM media_files WHERE media_id = $1", [media_id])
    after
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions ENABLE TRIGGER media_state_transitions_no_mutate",
        []
      )
    end
  end

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    :ok
  end

  test "seeded media_state_transitions row can be inserted (append path works)" do
    mid = media_id("insert")
    insert_media_file!(mid)
    on_exit(fn -> cleanup!(mid) end)

    assert %Postgrex.Result{rows: [[id]]} = insert_transition!(mid)
    assert is_integer(id)
  end

  test "a raw UPDATE on media_state_transitions raises a Postgres error with SQLSTATE 23001" do
    mid = media_id("update")
    insert_media_file!(mid)
    on_exit(fn -> cleanup!(mid) end)

    %Postgrex.Result{rows: [[id]]} = insert_transition!(mid)

    # Via the table owner (nebu_migrate — see moduledoc) so the trigger, not
    # the secondary REVOKE, is what raises here.
    conn = migrate_role_conn!()

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Postgrex.query(
               conn,
               "UPDATE media_state_transitions SET to_state = 'released' WHERE id = $1",
               [id]
             )
  end

  test "a raw DELETE on media_state_transitions raises the same SQLSTATE 23001 error" do
    mid = media_id("delete")
    insert_media_file!(mid)
    on_exit(fn -> cleanup!(mid) end)

    %Postgrex.Result{rows: [[id]]} = insert_transition!(mid)

    # Via the table owner (nebu_migrate — see moduledoc) so the trigger, not
    # the secondary REVOKE, is what raises here.
    conn = migrate_role_conn!()

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Postgrex.query(
               conn,
               "DELETE FROM media_state_transitions WHERE id = $1",
               [id]
             )
  end

  test "a raw UPDATE via the granted-then-revoked nebu_app role is blocked by REVOKE (AC8)" do
    mid = media_id("revoke")
    insert_media_file!(mid)
    on_exit(fn -> cleanup!(mid) end)

    %Postgrex.Result{rows: [[id]]} = insert_transition!(mid)

    # Via Nebu.Repo (nebu_app — the runtime role every other integration test
    # uses). nebu_app is GRANTed then immediately REVOKEd UPDATE/DELETE on
    # this table (AC8), so it never reaches the trigger at all: Postgres
    # rejects the statement at the privilege-check stage.
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE media_state_transitions SET to_state = 'released' WHERE id = $1",
               [id]
             )
  end

  test "the row is unchanged after the failed UPDATE/DELETE attempts" do
    mid = media_id("unchanged")
    insert_media_file!(mid)
    on_exit(fn -> cleanup!(mid) end)

    %Postgrex.Result{rows: [[id]]} = insert_transition!(mid)

    # Both mutation attempts are expected to fail (proved by the two tests
    # above); here we don't assert on their result, only that the row survives
    # unchanged afterward.
    _ =
      Ecto.Adapters.SQL.query(
        Repo,
        "UPDATE media_state_transitions SET to_state = 'released' WHERE id = $1",
        [id]
      )

    _ =
      Ecto.Adapters.SQL.query(
        Repo,
        "DELETE FROM media_state_transitions WHERE id = $1",
        [id]
      )

    assert {:ok,
            %Postgrex.Result{
              rows: [[^id, ^mid, from_state, to_state, actor_type, actor_id, metadata]]
            }} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               SELECT id, media_id, from_state, to_state, actor_type, actor_id, metadata
               FROM media_state_transitions
               WHERE id = $1
               """,
               [id]
             )

    assert from_state == nil
    assert to_state == "reserved"
    assert actor_type == "system"
    assert actor_id == nil
    assert metadata == nil
  end

  test "the trigger fires even when the connecting role is the table owner (single-role dev/CI)" do
    mid = media_id("owner_role")
    insert_media_file!(mid)
    on_exit(fn -> cleanup!(mid) end)

    %Postgrex.Result{rows: [[id]]} = insert_transition!(mid)

    # Connect as nebu_migrate — the actual table owner in this project's
    # docker-compose deployment (see moduledoc) — rather than via Nebu.Repo
    # (nebu_app), which is never the owner here.
    conn = migrate_role_conn!()

    %Postgrex.Result{rows: [[current_role]]} = Postgrex.query!(conn, "SELECT current_user", [])

    %Postgrex.Result{rows: [[owner]]} =
      Postgrex.query!(
        conn,
        "SELECT tableowner FROM pg_tables WHERE tablename = 'media_state_transitions'",
        []
      )

    assert current_role == owner,
           "this test's premise (ADR-031) is that the connecting role IS the table owner " <>
             "— got connecting role #{inspect(current_role)}, owner #{inspect(owner)}"

    assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
             Postgrex.query(
               conn,
               "UPDATE media_state_transitions SET to_state = 'released' WHERE id = $1",
               [id]
             )
  end
end
