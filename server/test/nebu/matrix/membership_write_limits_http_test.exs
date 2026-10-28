defmodule Nebu.Matrix.MembershipWriteLimitsHttpTest do
  @moduledoc """
  Integration tests for story `rate-limits-join-invite-create-room` (epic oauth-broker, follow-up `ey`): over HTTP against the real
  supervision tree + PostgreSQL (`Nebu.Web.Router`, users and sessions as in `create_room_invites_http_test.exs`, random users,
  `:server_name` pinned). Acceptance criteria AC3 (the three per-user tiers), AC5 (the pending-invitation caps), AC6 (`/sync` has no hidden
  invite cap) and AC12 (the Oracle gate tests).

  ## What this file pins

    * The tiers (D1, D2): `POST /createRoom` (`create_room`, 10 / min, burst 20, PLUS `n` units of the `invite` tier for `n` DISTINCT string
      entries of a list of at most 50 invitees, ONE all-or-nothing charge), `POST /rooms/{id}/invite` (`invite`, 20 / min, burst 50, one
      unit), `POST /join/{idOrAlias}` (`join`, 12 / min, burst 30, one unit, an idempotent re-join included). The charge comes FIRST in
      the route head (before the body checks, the room lookup and the already-invited no-op). A refused request is the standard `429`
      envelope with `Retry-After` and `retry_after_ms`, and writes NOTHING.
    * The caps (D6, D7): 500 pending invitations per inviter, 100 per invitee, 10 per (inviter, invitee) pair, `403 M_FORBIDDEN` with fixed
      texts, decided on the real DB, all-or-nothing for createRoom, not disabled by `:rate_limit_disabled`.
    * `/sync` lists every pending invitation (D10: no per-response cap).

  ## Conventions (as the sibling suites)

    * The clock of the limiter is FROZEN (`T.reset_rate_limits/0`, constant 1 000 000): a test user has exactly `burst` tokens for the
      whole test. To advance it the suite re-puts `:rate_limit_clock_fn` with a later constant (restored by `T.restore_rate_limits/0`).
      Buckets are seeded / read through the ETS rows themselves (`{{tier, user_id}, tokens, last_ms}`, the key shape of the story's D1) so
      that an empty bucket costs one insert, not 20 requests; the "20 pass, the 21st is refused" test uses real requests.
    * `m.room.member` events carry millisecond timestamps and the latest membership is read by that timestamp: membership changes of the
      SAME user in one test are separated by `tick/0`.
    * Every refused request leaves NO room, row, event, audit row or wake-up behind (`footprint/2`, per creator and per invitee, never a
      global count: `async: false` and random ids).
    * The caps are lowered per test through `Application.put_env(:nebu, :invite_max_pending_per_inviter | _per_invitee | _per_pair, n)`
      (snapshot / restore with `fetch_env`).
    * No fixed sleeps: waits are bounded loops or `assert_receive` / `refute_receive` with a timeout; the long-poll check measures a real
      `timeout=500` poll that nothing wakes.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @create "/_matrix/client/v3/createRoom"
  @table :nebu_http_rate_limit_buckets
  @cap_keys [:invite_max_pending_per_inviter, :invite_max_pending_per_invitee, :invite_max_pending_per_pair]

  @inviter_cap_text "You have too many pending invitations: wait until some of them are accepted or declined"
  @pair_cap_text "You have too many pending invitations to this user"
  @invitee_cap_text "The invited user has too many pending invitations"

  # A thin delegating `invite_db_module` (test-only): every InviteDB function is the real one, only the count read can be made to fail
  # (Application env :atdd_mwl_count_fault: `reason` -> {:error, reason}, :raise -> raises). The failure is real-DB-free but everything
  # else (rows, events, existence reads) stays on the real database, so "nothing was written" is checked against real tables.
  defmodule FaultyCountsInviteDB do
    alias Nebu.Matrix.Room.InviteDB

    for {name, arity} <- InviteDB.__info__(:functions), name != :pending_invite_counts do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(InviteDB, unquote(name), unquote(args))
    end

    def pending_invite_counts(inviter, invitees, limit) do
      fun = String.to_atom("pending_invite_counts")

      case Application.get_env(:nebu, :atdd_mwl_count_fault) do
        :raise -> raise "atdd: the count read raised"
        nil -> apply(InviteDB, fun, [inviter, invitees, limit])
        reason -> {:error, reason}
      end
    end
  end

  setup do
    # the tiers must be ENABLED here: a disable switch exported into the test environment would turn every 429 test into a failure
    assert System.get_env("NEBU_RATE_LIMIT_DISABLED") != "true",
           "this suite requires the limiter ENABLED: NEBU_RATE_LIMIT_DISABLED must not be \"true\" in the test harness"

    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())

    caps = for key <- @cap_keys, do: {key, Application.fetch_env(:nebu, key)}

    on_exit(fn ->
      T.restore_rate_limits()

      for {key, previous} <- caps do
        case previous do
          {:ok, value} -> Application.put_env(:nebu, key, value)
          :error -> Application.delete_env(:nebu, key)
        end
      end
    end)

    {:ok, a: user!("MWLA"), b: user!("MWLB"), c: user!("MWLC")}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp user!(device_prefix) do
    uid = T.provision_user!()
    %{uid: uid, at: T.legacy_session!(uid, device_prefix <> String.upcase(T.rand(3))).at}
  end

  defp enc(room_id), do: URI.encode_www_form(room_id)
  defp path(room, suffix), do: "/_matrix/client/v3/rooms/#{enc(room)}/#{suffix}"
  defp put_cap(key, value), do: Application.put_env(:nebu, key, value)

  defp tick do
    start = System.system_time(:millisecond)
    :ok = wait_until(fn -> System.system_time(:millisecond) > start end, 50)
  end

  defp wait_until(fun, attempts) do
    cond do
      fun.() -> :ok
      attempts <= 0 -> :timeout
      true -> (Process.sleep(1); wait_until(fun, attempts - 1))
    end
  end

  defp create(user, body), do: T.matrix_request(:post, @create, user.at, body: body)

  defp make_room(user, body \\ %{}) do
    conn = create(user, body)
    assert conn.status == 200, "createRoom #{inspect(body)}: #{conn.status} #{conn.resp_body}"
    T.json(conn)["room_id"]
  end

  defp public_room(user), do: make_room(user, %{"preset" => "public_chat"})

  # a request with a RAW body (not necessarily JSON) through the real router
  defp raw_post(user, request_path, raw) do
    Plug.Test.conn(:post, request_path, raw)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> user.at)
    |> Map.put(:remote_ip, T.unique_ip())
    |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
  end

  defp join(user, room), do: T.matrix_request(:post, "/_matrix/client/v3/join/#{enc(room)}", user.at)
  defp leave(user, room), do: T.matrix_request(:post, path(room, "leave"), user.at)
  defp invite(owner, room, target), do: T.matrix_request(:post, path(room, "invite"), owner.at, body: %{"user_id" => uid_of(target)})
  defp uid_of(%{uid: uid}), do: uid
  defp uid_of(uid) when is_binary(uid), do: uid

  defp invite!(owner, room, target) do
    c = invite(owner, room, target)
    assert c.status == 200, "invite: #{c.status} #{c.resp_body}"
  end

  defp join!(user, room) do
    tick()
    c = join(user, room)
    assert c.status == 200, "join: #{c.status} #{c.resp_body}"
  end

  defp leave!(user, room) do
    tick()
    c = leave(user, room)
    assert c.status == 200, "leave: #{c.status} #{c.resp_body}"
  end

  defp send_message(user, room, body) do
    T.matrix_request(:put, path(room, "send/m.room.message/#{T.rand(6)}"), user.at, body: %{"msgtype" => "m.text", "body" => body})
  end

  defp put_account_data(user, type, body), do: T.matrix_request(:put, "/_matrix/client/v3/user/#{enc(user.uid)}/account_data/#{type}", user.at, body: body)

  defp sync(user, since \\ nil) do
    suffix = if since, do: "?since=#{URI.encode_www_form(since)}&timeout=0", else: "?timeout=0"
    conn = T.matrix_request(:get, "/_matrix/client/v3/sync" <> suffix, user.at)
    assert conn.status == 200, "sync: #{conn.status} #{conn.resp_body}"
    T.json(conn)
  end

  defp invite_rooms(user, since \\ nil), do: get_in(sync(user, since), ["rooms", "invite"]) || %{}

  defp ban(room, caller, target) do
    req = %Core.BanUserRequest{room_id: room, target_id: target.uid, reason: ""}
    assert %Core.BanUserResponse{} = Nebu.Matrix.EventDispatcher.Server.ban_user(req, Nebu.Matrix.Http.stream(caller.uid))
  end

  defp content_of(c) when is_map(c), do: c

  defp content_of(c) when is_binary(c) do
    case Jason.decode!(c) do
      decoded when is_binary(decoded) -> content_of(decoded)
      decoded -> decoded
    end
  end

  defp member_events(room_id, uid) do
    T.sql!("SELECT content FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND state_key = $2 ORDER BY origin_server_ts, event_id", [room_id, uid]).rows
    |> Enum.map(fn [content] -> content_of(content) end)
  end

  defp invite_events(room_id, uid), do: Enum.filter(member_events(room_id, uid), &(&1["membership"] == "invite"))
  defp member?(room_id, uid), do: T.sql!("SELECT count(*) FROM room_members WHERE room_id = $1 AND user_id = $2 AND left_at IS NULL", [room_id, uid]).rows == [[1]]

  # :pending | :accepted | :rejected | :none for the row of (room, invitee)
  defp invitation_state(room_id, uid) do
    case T.sql!("SELECT accepted_at, rejected_at FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [room_id, uid]).rows do
      [] -> :none
      [[nil, nil]] -> :pending
      [[_accepted, nil]] -> :accepted
      [[nil, _rejected]] -> :rejected
    end
  end

  defp pending_rows(inviter_uid), do: T.sql!("SELECT count(*) FROM room_invitations WHERE inviter_id = $1 AND accepted_at IS NULL AND rejected_at IS NULL", [inviter_uid]).rows |> hd() |> hd()

  # What a creator (and the invitees) have in the database: events he sent (a cleaned-up room leaves none), his room memberships, the
  # invitation rows he issued or that name one of the invitees, and the audit rows he wrote. A refused request must not change it.
  defp footprint(uid, invitees \\ []) do
    {T.sql!("SELECT count(*) FROM events WHERE sender = $1", [uid]).rows,
     T.sql!("SELECT count(*) FROM room_members WHERE user_id = $1", [uid]).rows,
     T.sql!("SELECT count(*) FROM room_invitations WHERE inviter_id = $1 OR invitee_id = ANY($2)", [uid, invitees]).rows,
     T.sql!("SELECT count(*) FROM audit_log WHERE actor_user_id = $1", [uid]).rows,
     T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.member' AND state_key = ANY($1)", [invitees]).rows,
     # an ORPHAN room (a created-then-half-deleted one) leaves a `rooms` row without events of the creator: the suite is async: false
     T.sql!("SELECT count(*) FROM rooms").rows}
  end

  # ── the limiter buckets (ETS rows of the plug / take_all: {{tier, user_id}, tokens, last_ms}) ──

  defp now, do: Application.get_env(:nebu_http, :rate_limit_clock_fn).()

  defp advance(ms) do
    later = now() + ms
    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> later end)
  end

  # the table is created lazily and dies with its creator when that was a test process: make sure it exists before a seed
  defp seed(tier, user, tokens) do
    Nebu.Web.Plugs.RateLimit.init_table()
    :ets.insert(@table, {{tier, user.uid}, tokens * 1.0, now()})
  end

  defp tokens(tier, user) do
    with true <- :ets.whereis(@table) != :undefined,
         [{_key, tokens, _last}] <- :ets.lookup(@table, {tier, user.uid}) do
      tokens
    else
      _ -> nil
    end
  end

  # the full burst while no row exists yet
  defp tokens(tier, user, burst), do: tokens(tier, user) || burst * 1.0

  # a 429: exact envelope, Retry-After an integer >= 1, retry_after_ms == Retry-After * 1000; returns the Retry-After seconds
  defp assert_429(conn, label) do
    assert conn.status == 429, "#{label}: expected 429, got #{conn.status} #{conn.resp_body}"
    body = T.json(conn)

    assert Enum.sort(Map.keys(body)) == ["errcode", "error", "retry_after_ms"], "#{label}: #{conn.resp_body}"
    assert body["errcode"] == "M_LIMIT_EXCEEDED"
    assert body["error"] == "Rate limit exceeded"

    ms = body["retry_after_ms"]
    assert is_integer(ms) and ms > 0 and rem(ms, 1000) == 0, "#{label}: retry_after_ms is a positive multiple of 1000, got #{inspect(ms)}"

    assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || ""), "#{label}: Retry-After must be an integer"
    assert secs >= 1
    assert ms == secs * 1000, "#{label}: body (#{ms}) and header (#{secs}) agree"
    assert (T.header(conn, "content-type") || "") =~ "application/json"
    secs
  end

  # a cap refusal: 403 and EXACTLY {"errcode": "M_FORBIDDEN", "error": text}, never M_LIMIT_EXCEEDED
  defp assert_cap_403(conn, text, label) do
    assert conn.status == 403, "#{label}: expected 403, got #{conn.status} #{conn.resp_body}"
    assert T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => text}, "#{label}: #{conn.resp_body}"
    assert (T.header(conn, "content-type") || "") =~ "application/json"
    refute T.json(conn)["errcode"] == "M_LIMIT_EXCEEDED"
    conn
  end

  # ── statement capture (telemetry of the repo, only the calling process) ──

  def handle_query(_event, _measurements, %{query: query}, %{pid: pid}) do
    if self() == pid, do: send(pid, {:statement, query})
    :ok
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  defp capture_statements(fun) do
    id = "mwl-http-#{T.rand(6)}"
    :ok = :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self()})

    try do
      result = fun.()
      {result, drain_statements([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_statements(acc) do
    receive do
      {:statement, query} -> drain_statements([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # the pending-count read of D8 (the only statement that counts room_invitations rows)
  defp count_statements(statements), do: Enum.filter(statements, &(&1 =~ ~r/room_invitations/i and &1 =~ ~r/count/i))

  # a long-poll of the user, timed; returns {elapsed_ms, conn}
  defp long_poll(user, since, timeout_ms) do
    started = System.monotonic_time(:millisecond)
    conn = T.matrix_request(:get, "/_matrix/client/v3/sync?since=#{URI.encode_www_form(since)}&timeout=#{timeout_ms}", user.at)
    {System.monotonic_time(:millisecond) - started, conn}
  end

  defp subscribed?(uid), do: :pg.get_members("user:#{uid}") != []

  # ═══ AC3 (a), (b), (c): createRoom ═══════════════════════════════════════════════

  describe "AC3 (a) - POST /createRoom is limited per user (20 pass, the 21st is the exact 429 envelope)" do
    test "20 requests of A pass, the 21st is 429 and creates NO room; B, /sync, a message and account data of A are unaffected (independent tiers)", %{a: a, b: b} do
      rooms = for _ <- 1..20, do: make_room(a)

      before = footprint(a.uid)
      secs = assert_429(create(a, %{}), "21st createRoom")
      assert secs >= 1
      assert footprint(a.uid) == before, "the refused createRoom created nothing"

      assert create(b, %{}).status == 200, "user B has its own bucket"

      assert T.matrix_request(:get, "/_matrix/client/v3/sync?timeout=0", a.at).status == 200, "no shared IP bucket: /sync still works"
      assert send_message(a, hd(rooms), "still here").status == 200
      assert put_account_data(a, "org.example.atdd", %{"k" => "v"}).status == 200
    end

    test "advancing the frozen clock by one refill interval (6 s at 10 / min) gives A exactly ONE more create", %{a: a} do
      for _ <- 1..20, do: make_room(a)
      assert_429(create(a, %{}), "21st")

      # 6 000 ms is exactly one token; a hair more keeps the float arithmetic of the refill out of the assertion
      advance(6_100)
      assert create(a, %{}).status == 200, "one token has refilled"
      assert_429(create(a, %{}), "the second create after one refill interval")
    end
  end

  describe "AC3 (c) - the charge comes BEFORE the validation" do
    test "with A's create bucket empty a body that is not JSON answers 429, not M_NOT_JSON; the same body with a token left is the 400", %{a: a} do
      seed("create_room", a, 0)

      assert_429(raw_post(a, @create, "not json"), "empty bucket + not json")

      seed("create_room", a, 5)
      bad = raw_post(a, @create, "not json")
      assert bad.status == 400 and T.json(bad)["errcode"] == "M_NOT_JSON", "positive control: the validation is what answers when a token is left"
    end
  end

  # ═══ AC3 (d): the per-invitee charge ══════════════════════════════════════════════

  describe "AC3 (d) - createRoom is charged per invitee, all or nothing" do
    test "A creates a room with 50 provisioned invitees (200, 50 rows); A's next POST /invite is 429 and writes no row and no event", %{a: a, c: c} do
      invitees = for _ <- 1..50, do: T.provision_user!()
      room = make_room(a, %{"invite" => invitees, "preset" => "private_chat"})
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1", [room]).rows == [[50]]

      before = footprint(a.uid, [c.uid])
      assert_429(invite(a, room, c), "invite after 50 invitees")
      assert footprint(a.uid, [c.uid]) == before
      assert invitation_state(room, c.uid) == :none
      assert invite_events(room, c.uid) == []
    end

    test "C spent 30 invite units (30 invites, 200): a createRoom with 21 invitees is 429, creates NOTHING and leaves C's create bucket FULL (20 plain creates still pass)", %{a: a, c: c} do
      # the room is A's (public, invite level 0): C spends invite units without spending a create token
      room = public_room(a)
      join!(c, room)
      for _ <- 1..30, do: invite!(c, room, T.provision_user!())
      invitees = for _ <- 1..21, do: T.provision_user!()

      before = footprint(c.uid, invitees)
      assert_429(create(c, %{"invite" => invitees}), "21 invitees with 20 invite units left")
      assert footprint(c.uid, invitees) == before, "no room, no row, no event, no audit row"

      assert tokens("create_room", c, 20) == 20.0, "the refused request consumed nothing from the create bucket"
      for _ <- 1..20, do: make_room(c)
      assert_429(create(c, %{}), "21st plain create")
    end

    test "C spent 30 invite units: a createRoom with exactly 20 invitees passes (200) and empties the invite bucket", %{a: a, c: c} do
      room = public_room(a)
      join!(c, room)
      for _ <- 1..30, do: invite!(c, room, T.provision_user!())
      invitees = for _ <- 1..20, do: T.provision_user!()

      new_room = make_room(c, %{"invite" => invitees})
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1", [new_room]).rows == [[20]]
      assert_in_delta tokens("invite", c, 50), 0.0, 1.0e-6
      assert_429(invite(c, room, T.provision_user!()), "invite with an empty invite bucket")
    end
  end

  describe "AC3 (e) - what a createRoom invite list is charged" do
    test "51 entries are 400 M_INVALID_PARAM and NO invite unit is charged (a createRoom with 50 invitees still passes afterwards)", %{a: a} do
      too_many = for n <- 1..51, do: "@over#{n}-#{T.rand(3)}:#{T.server_name()}"
      conn = create(a, %{"invite" => too_many})
      assert conn.status == 400 and T.json(conn)["errcode"] == "M_INVALID_PARAM", conn.resp_body

      assert tokens("invite", a, 50) == 50.0, "a list of 51 entries drains nothing from the invite bucket"

      invitees = for _ <- 1..50, do: T.provision_user!()
      assert make_room(a, %{"invite" => invitees}) |> is_binary()
      assert_in_delta tokens("invite", a, 50), 0.0, 1.0e-6, "positive control: the 50 invitees ARE charged (the bucket exists and is now empty)"
    end

    test "a NON-list invite (string, object, number) is 400 and charges NO invite unit (n = 0), only the create unit", %{a: a, b: b} do
      for {label, value} <- [string: b.uid, object: %{"x" => 1}, number: 5] do
        before_create = tokens("create_room", a, 20)
        conn = create(a, %{"invite" => value})
        assert conn.status == 400 and T.json(conn)["errcode"] == "M_BAD_JSON", "#{label}: #{conn.resp_body}"
        assert tokens("invite", a, 50) == 50.0, "#{label}: a non-list charges no invite unit"
        assert tokens("create_room", a) == before_create - 1, "#{label}: the create unit IS charged"
      end

      # positive control: a list of one id charges one invite unit
      assert make_room(a, %{"invite" => [b.uid]}) |> is_binary()
      assert tokens("invite", a) == 49.0
    end

    test "50 duplicates of one id are ONE unit; a list of 3 malformed ids is 400 and 3 units; a list with non-string entries counts only its string entries", %{a: a, b: b} do
      assert make_room(a, %{"invite" => List.duplicate(b.uid, 50)}) |> is_binary()
      assert tokens("invite", a) == 49.0, "50 duplicates = 1 unit"

      conn = create(a, %{"invite" => ["x", "y", "z"]})
      assert conn.status == 400 and T.json(conn)["errcode"] == "M_INVALID_PARAM", conn.resp_body
      assert tokens("invite", a) == 46.0, "3 distinct malformed strings = 3 units (the charge comes before the validation)"

      conn = create(a, %{"invite" => [1, nil, "q"]})
      assert conn.status == 400 and T.json(conn)["errcode"] == "M_BAD_JSON", conn.resp_body
      assert tokens("invite", a) == 45.0, "only the one distinct STRING entry is charged"

      # a request without invitees touches the invite bucket not at all
      before = tokens("invite", a)
      assert make_room(a) |> is_binary()
      assert tokens("invite", a) == before
    end
  end

  # ═══ AC3 (f), (g), (h): join, invite, disabled ═════════════════════════════════════

  describe "AC3 (f) - POST /join is limited per user (30 pass, the 31st is 429 and joins nothing)" do
    test "30 joins pass, the 31st is 429 and joins nothing (no member row, no join event, no room_joined audit row); an idempotent re-join is charged", %{a: a, b: b, c: c} do
      # 31 public rooms by two creators (a creator has 20 creates)
      rooms = for(_ <- 1..16, do: public_room(b)) ++ for(_ <- 1..15, do: public_room(c))
      {first30, [last]} = Enum.split(rooms, 30)

      for room <- first30, do: assert(join(a, room).status == 200)

      before_events = member_events(last, a.uid)
      before_audit = T.sql!("SELECT count(*) FROM audit_log WHERE actor_user_id = $1 AND action = 'room_joined'", [a.uid]).rows

      assert_429(join(a, last), "31st join")

      refute member?(last, a.uid)
      assert T.sql!("SELECT count(*) FROM room_members WHERE room_id = $1 AND user_id = $2", [last, a.uid]).rows == [[0]]
      assert member_events(last, a.uid) == before_events
      assert T.sql!("SELECT count(*) FROM audit_log WHERE actor_user_id = $1 AND action = 'room_joined'", [a.uid]).rows == before_audit

      # an idempotent re-join of a room A is in is charged too: the bucket is empty, so it is 429 as well
      assert_429(join(a, hd(first30)), "re-join of a joined room with an empty bucket")

      # positive control: one refill interval (5 s at 12 / min) and the 31st join works
      advance(5_100)
      assert join(a, last).status == 200
      assert member?(last, a.uid)
    end
  end

  describe "AC3 (g) - POST /invite is charged before the room checks" do
    test "an empty invite bucket answers 429 for an UNKNOWN room id (not 404); with a token left the same request is the 404", %{a: a, b: b} do
      unknown = "!nosuch#{T.rand(5)}:#{T.server_name()}"
      seed("invite", a, 0)
      assert_429(invite(a, unknown, b), "unknown room, empty bucket")

      seed("invite", a, 5)
      conn = invite(a, unknown, b)
      assert conn.status == 404, "positive control: with a token left the room check answers (#{conn.status} #{conn.resp_body})"
    end
  end

  describe "AC3 (f2) - POST /join is charged before the room lookup" do
    test "an empty join bucket answers 429 for an UNKNOWN room id (not 404); with a token left the same request is the 404", %{a: a} do
      unknown = "!nosuch#{T.rand(5)}:#{T.server_name()}"
      seed("join", a, 0)
      assert_429(join(a, unknown), "unknown room, empty join bucket")

      seed("join", a, 5)
      conn = join(a, unknown)
      assert conn.status == 404, "positive control: with a token left the room lookup answers (#{conn.status} #{conn.resp_body})"
    end
  end

  describe "AC3 (g2) - POST /invite is charged before the body validation" do
    test "an empty invite bucket answers 429 for a body that is not JSON (not M_NOT_JSON); with a token left the same body is the 400", %{a: a} do
      room = make_room(a)
      seed("invite", a, 0)
      assert_429(raw_post(a, path(room, "invite"), "not json"), "empty bucket + not json")

      seed("invite", a, 5)
      bad = raw_post(a, path(room, "invite"), "not json")
      assert bad.status == 400 and T.json(bad)["errcode"] == "M_NOT_JSON", "positive control: the validation answers when a token is left (#{bad.resp_body})"
    end
  end

  describe "AC3 (h) - :rate_limit_disabled disables the three tiers" do
    test "60 creates, 120 invites (one real, 119 already-invited no-ops) and 60 joins of ONE user all pass", %{a: a, b: b, c: c} do
      room = make_room(a)
      pub = public_room(c)

      # positive control: with the limiter ON and the three buckets empty every one of the three requests is a 429
      for tier <- ["create_room", "invite", "join"], do: seed(tier, a, 0)
      assert_429(create(a, %{}), "create, limiter on")
      assert_429(invite(a, room, b), "invite, limiter on")
      assert_429(join(a, pub), "join, limiter on")

      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      for _ <- 1..60, do: make_room(a)
      for _ <- 1..120, do: invite!(a, room, b)
      for _ <- 1..60, do: assert(join(a, pub).status == 200)

      # a disabled limiter does not even touch the buckets (they stay as seeded)
      for tier <- ["create_room", "invite", "join"], do: assert(tokens(tier, a) == 0.0, "#{tier} bucket untouched")
    end
  end

  # ═══ AC5: the caps ═══════════════════════════════════════════════════════════════

  describe "AC5 (a) - the per-pair cap" do
    test "pair cap 3: A invites B into 3 rooms, the 4th POST /invite is the exact 403 and writes no row, no event and wakes nobody; B declines one, A can invite again; C can still invite B", %{a: a, b: b, c: c} do
      put_cap(:invite_max_pending_per_pair, 3)
      rooms = for _ <- 1..4, do: make_room(a)
      {first3, [fourth]} = Enum.split(rooms, 3)
      for room <- first3, do: invite!(a, room, b)

      since = sync(b)["next_batch"]
      poll = Task.async(fn -> long_poll(b, since, 500) end)
      assert wait_until(fn -> subscribed?(b.uid) end, 2_000) == :ok, "B's long-poll is subscribed before the refused invite"

      assert_cap_403(invite(a, fourth, b), @pair_cap_text, "4th invitation of the pair")
      assert invitation_state(fourth, b.uid) == :none
      assert invite_events(fourth, b.uid) == []

      {elapsed, polled} = Task.await(poll, 10_000)
      assert polled.status == 200
      assert elapsed >= 450, "nobody woke B's long-poll (it ran #{elapsed} ms of 500)"
      refute Map.has_key?(get_in(T.json(polled), ["rooms", "invite"]) || %{}, fourth)

      # B declines one: the pair has room again
      leave!(b, hd(first3))
      assert invitation_state(hd(first3), b.uid) == :rejected
      invite!(a, fourth, b)
      assert invitation_state(fourth, b.uid) == :pending

      # another inviter is unaffected by A's pair (positive control of the pair scope)
      other_room = make_room(c)
      invite!(c, other_room, b)
    end

    test "the positive control of the wake-up: an allowed invitation wakes the invitee's long-poll before its timeout", %{a: a, b: b} do
      room = make_room(a)
      since = sync(b)["next_batch"]

      poll = Task.async(fn -> long_poll(b, since, 5_000) end)
      assert wait_until(fn -> subscribed?(b.uid) end, 2_000) == :ok

      invite!(a, room, b)
      {elapsed, polled} = Task.await(poll, 10_000)

      assert elapsed < 4_000, "the invitation woke the long-poll (#{elapsed} ms)"
      assert Map.has_key?(get_in(T.json(polled), ["rooms", "invite"]) || %{}, room)
    end
  end

  describe "AC5 (b) - the re-arm and the exemptions of do_invite!" do
    test "at the pair cap: a re-invite after a decline is 403 (a re-arm adds a row); the already-invited no-op is 200 {}; a row-only pending invitation is 200 and gets its event", %{a: a, b: b} do
      put_cap(:invite_max_pending_per_pair, 2)
      [r1, r2, r3, r4] = for _ <- 1..4, do: make_room(a)

      invite!(a, r1, b)
      invite!(a, r2, b)
      leave!(b, r1)
      assert invitation_state(r1, b.uid) == :rejected
      invite!(a, r3, b)
      # pending: r2, r3 = 2 = the cap

      # (1) re-arm of the declined row: adds a pending row -> counted -> refused
      tick()
      assert_cap_403(invite(a, r1, b), @pair_cap_text, "re-invite after a decline at the cap")
      assert invitation_state(r1, b.uid) == :rejected, "the refused re-arm did not touch the row"

      # (2) already invited (pending row AND latest membership invite): the no-op answers 200 {} and writes nothing
      events_before = member_events(r2, b.uid)
      conn = invite(a, r2, b)
      assert conn.status == 200 and conn.resp_body == "{}", "#{conn.status} #{conn.resp_body}"
      assert member_events(r2, b.uid) == events_before

      # (3) a row-only (legacy / upgrade) pending invitation: pending_before is true, no new row, the invite event is written
      assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(r4, a.uid, b.uid)
      assert invite_events(r4, b.uid) == []
      conn = invite(a, r4, b)
      assert conn.status == 200 and conn.resp_body == "{}", "#{conn.status} #{conn.resp_body}"
      assert [%{"membership" => "invite"}] = invite_events(r4, b.uid)
    end
  end

  describe "AC5 (c) - the per-inviter cap on createRoom (all or nothing)" do
    test "inviter cap 5: a createRoom with 6 invitees is the exact 403 and creates NOTHING (no room, row, event, audit row, wake-up); 5 invitees pass and wake every invitee", %{a: a} do
      put_cap(:invite_max_pending_per_inviter, 5)
      invitees = for _ <- 1..6, do: T.provision_user!()
      # the test process listens on every invitee's group (it leaves them when it exits)
      for uid <- invitees, do: :pg.join("user:#{uid}", self())

      before = footprint(a.uid, invitees)
      assert_cap_403(create(a, %{"invite" => invitees}), @inviter_cap_text, "6 invitees with an inviter cap of 5")
      assert footprint(a.uid, invitees) == before, "nothing was created"
      refute_receive {:new_invite, _}, 150

      room = make_room(a, %{"invite" => Enum.take(invitees, 5)})
      assert pending_rows(a.uid) == 5
      for _uid <- 1..5, do: assert_receive({:new_invite, ^room}, 1_000)
    end

    test "the inviter cap counts rows over ALL rooms and by the current inviter: 3 pending + a createRoom of 3 invitees is refused, of 2 is fine (k = the de-duplicated count)", %{a: a} do
      put_cap(:invite_max_pending_per_inviter, 5)
      room = make_room(a)
      for _ <- 1..3, do: invite!(a, room, T.provision_user!())

      three = for _ <- 1..3, do: T.provision_user!()
      assert_cap_403(create(a, %{"invite" => three}), @inviter_cap_text, "3 pending + 3 > 5")

      # duplicates are one invitee each: [x, x, x, y] is k = 2, 3 + 2 <= 5
      [x, y] = Enum.take(three, 2)
      assert make_room(a, %{"invite" => [x, x, x, y]}) |> is_binary()
      assert pending_rows(a.uid) == 5
    end
  end

  describe "AC5 (d) - the per-invitee cap" do
    test "invitee cap 2: D and E invite B; F's createRoom with [G, B] is the exact 403 and creates nothing (G gets no row either); F's POST /invite of B is the same 403", %{b: b} do
      put_cap(:invite_max_pending_per_invitee, 2)
      d = user!("MWLD")
      e = user!("MWLE")
      f = user!("MWLF")
      g = T.provision_user!()

      invite!(d, make_room(d), b)
      invite!(e, make_room(e), b)

      before = footprint(f.uid, [g, b.uid])
      assert_cap_403(create(f, %{"invite" => [g, b.uid]}), @invitee_cap_text, "createRoom [G, B] with B at the cap")
      assert footprint(f.uid, [g, b.uid]) == before
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE invitee_id = $1", [g]).rows == [[0]]

      room = make_room(f)
      assert_cap_403(invite(f, room, b), @invitee_cap_text, "POST /invite of B at the cap")
      assert invitation_state(room, b.uid) == :none

      # positive control: the invitee cap is the invitee's, not the inviter's: F can invite G
      invite!(f, room, g)
    end

    test "first failure wins: the inviter cap, then the invitees in LIST order, the pair before the invitee total", %{b: b} do
      d = user!("MWLD")
      e = user!("MWLE")
      f = user!("MWLF")
      x = user!("MWLX")
      z = user!("MWLZ")

      # B: two pending invitations (from D and E) = at the invitee cap 2; X: one pending from F = at the pair cap 1 of (F, X);
      # Z: one pending from D and one from F = at the invitee cap AND the pair cap of (F, Z)
      put_cap(:invite_max_pending_per_invitee, 2)
      put_cap(:invite_max_pending_per_pair, 1)
      invite!(d, make_room(d), b)
      invite!(e, make_room(e), b)
      invite!(f, make_room(f), x)
      invite!(d, make_room(d), z)
      invite!(f, make_room(f), z)

      # list order: [X (pair), B (invitee total)] -> the pair text; [B, X] -> the invitee text
      assert_cap_403(create(f, %{"invite" => [x.uid, b.uid]}), @pair_cap_text, "[X, B]")
      assert_cap_403(create(f, %{"invite" => [b.uid, x.uid]}), @invitee_cap_text, "[B, X]")

      # Z violates BOTH for F: the pair is checked before the invitee total
      assert_cap_403(create(f, %{"invite" => [z.uid]}), @pair_cap_text, "Z violates pair and total: the pair wins")
      assert_cap_403(invite(f, make_room(f), z), @pair_cap_text, "POST /invite: the pair wins as well")

      # the inviter cap comes first: F holds 2 pending (X, Z) = the inviter cap 2, and [X] also violates the pair
      put_cap(:invite_max_pending_per_inviter, 2)
      assert_cap_403(create(f, %{"invite" => [x.uid]}), @inviter_cap_text, "inviter before pair")
    end
  end

  describe "AC5 (e) - the order of the checks" do
    test "createRoom: unknown invitee 404 (existence before caps), taken alias M_ROOM_IN_USE, malformed list 400: the count read is never issued; a valid request reads once", %{a: a, b: b} do
      put_cap(:invite_max_pending_per_invitee, 1)
      d = user!("MWLD")
      invite!(d, make_room(d), b)

      alias_localpart = "mwl-" <> T.rand(4)
      make_room(d, %{"room_alias_name" => alias_localpart})

      ghost = "@ghost-#{T.rand(4)}:#{T.server_name()}"

      {results, statements} =
        capture_statements(fn ->
          [
            create(a, %{"invite" => [b.uid, ghost]}),
            create(a, %{"invite" => [b.uid], "room_alias_name" => alias_localpart}),
            create(a, %{"invite" => ["bob"]})
          ]
        end)

      [unknown, taken, malformed] = results
      assert unknown.status == 404 and T.json(unknown)["errcode"] == "M_NOT_FOUND", unknown.resp_body
      assert taken.status == 400 and T.json(taken)["errcode"] == "M_ROOM_IN_USE", taken.resp_body
      assert malformed.status == 400 and T.json(malformed)["errcode"] == "M_INVALID_PARAM", malformed.resp_body
      assert count_statements(statements) == [], "the count read is not issued for a request that failed an earlier check"

      # positive control (the matcher sees the count read of this implementation, the cap really is the next check)
      {capped, statements} = capture_statements(fn -> create(a, %{"invite" => [b.uid]}) end)
      assert_cap_403(capped, @invitee_cap_text, "the same invitee without the earlier failures")
      assert length(count_statements(statements)) == 1, "exactly ONE count read per createRoom, got #{inspect(statements)}"
    end

    test "POST /invite of a MEMBER at the pair cap is 'already in this room' (the member check comes before the caps)", %{a: a, b: b} do
      put_cap(:invite_max_pending_per_pair, 1)
      room = public_room(a)
      invite!(a, make_room(a), b)
      # the (A, B) pair now holds its one pending invitation: any further ADDED row would be refused

      join!(b, room)
      conn = invite(a, room, b)
      assert conn.status == 403 and T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => "The invited user is already in this room"}, conn.resp_body

      # positive control: the pair cap IS live (a NEW invitation of the same pair is refused by it)
      assert_cap_403(invite(a, make_room(a), b), @pair_cap_text, "a new invitation of the pair")
    end

    test "POST /invite of a BANNED user at the pair cap is exactly the ban text (the ban check comes before the caps)", %{a: a, b: b} do
      put_cap(:invite_max_pending_per_pair, 1)
      room = make_room(a)
      invite!(a, make_room(a), b)

      tick()
      ban(room, a, b)
      conn = invite(a, room, b)
      assert conn.status == 403 and T.json(conn) == %{"errcode" => "M_FORBIDDEN", "error" => "The invited user is banned from this room"}, conn.resp_body

      # positive control: the pair cap IS live (a NEW invitation of the same pair is refused by it)
      assert_cap_403(invite(a, make_room(a), b), @pair_cap_text, "a new invitation of the pair")
    end
  end

  describe "AC5 (f) - not capped, but counted: Admin force-add and upgrade_room" do
    test "Admin force-add and upgrade_room of B at B's invitee cap succeed (upgrade writes the row-only invitation) and neither issues the count read", %{a: a, b: b} do
      put_cap(:invite_max_pending_per_invitee, 2)
      d = user!("MWLD")
      e = user!("MWLE")
      invite!(d, make_room(d), b)
      invite!(e, make_room(e), b)

      # positive control: a client invitation of B IS refused now (the cap is active, the matcher sees the count read)
      target_room = make_room(a)
      {capped, statements} = capture_statements(fn -> invite(a, target_room, b) end)
      assert_cap_403(capped, @invitee_cap_text, "client invite at the cap")
      assert length(count_statements(statements)) == 1

      # Admin force-add
      room = make_room(a)
      {added, statements} = capture_statements(fn -> Nebu.Matrix.EventDispatcher.Server.admin_add_room_member(room, b.uid, a.uid) end)
      assert {:ok, ^room} = added
      assert member?(room, b.uid)
      assert count_statements(statements) == [], "the Admin force-add is not capped, and does not read the counts"

      # upgrade_room: B is a member of the old room (public room, B joined); the new room gets a row-only invitation for B
      public = public_room(a)
      join!(b, public)

      {upgraded, statements} =
        capture_statements(fn -> T.matrix_request(:post, path(public, "upgrade"), a.at, body: %{"new_version" => "10"}) end)

      assert upgraded.status == 200, "#{upgraded.status} #{upgraded.resp_body}"
      new_room = T.json(upgraded)["replacement_room"]
      assert invitation_state(new_room, b.uid) == :pending, "the row-only invitation of the upgrade was written"
      assert count_statements(statements) == [], "upgrade_room is not capped, and does not read the counts"
    end

    test "rows of the uncapped writers count towards the caps of later client invitations: after an upgrade the per-invitee total of B includes the upgrade row", %{a: a, b: b} do
      put_cap(:invite_max_pending_per_invitee, 1)
      public = public_room(a)
      join!(b, public)

      upgraded = T.matrix_request(:post, path(public, "upgrade"), a.at, body: %{"new_version" => "10"})
      assert upgraded.status == 200, upgraded.resp_body
      assert invitation_state(T.json(upgraded)["replacement_room"], b.uid) == :pending

      d = user!("MWLD")
      assert_cap_403(invite(d, make_room(d), b), @invitee_cap_text, "a client invitation after the upgrade row")
    end
  end

  describe "AC5 (g) - the caps are NOT disabled by :rate_limit_disabled" do
    test "with the limiter disabled the pair cap still refuses (the tiers are rate limits, the caps are state limits)", %{a: a, b: b} do
      put_cap(:invite_max_pending_per_pair, 1)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      invite!(a, make_room(a), b)
      assert_cap_403(invite(a, make_room(a), b), @pair_cap_text, "second invitation of the pair, limiter disabled")
    end
  end

  describe "AC5 (h) - a failing count read is fail-closed and value-free (delegating invite_db_module)" do
    setup do
      previous = Application.fetch_env(:event_dispatcher, :invite_db_module)
      Application.put_env(:event_dispatcher, :invite_db_module, FaultyCountsInviteDB)

      on_exit(fn ->
        Application.delete_env(:nebu, :atdd_mwl_count_fault)

        case previous do
          {:ok, value} -> Application.put_env(:event_dispatcher, :invite_db_module, value)
          :error -> Application.delete_env(:event_dispatcher, :invite_db_module)
        end
      end)

      :ok
    end

    defp error_lines(log), do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "[error]"))

    test "createRoom: 500 and NOTHING created (no room, row, event, audit row, rooms row) for an error and a raise; the error log names no user id", %{a: a, b: b} do
      before = footprint(a.uid, [b.uid])

      for fault <- [:db_down, :raise] do
        Application.put_env(:nebu, :atdd_mwl_count_fault, fault)
        {conn, log} = with_log(fn -> create(a, %{"invite" => [b.uid]}) end)

        assert conn.status == 500, "#{fault}: fail closed, got #{conn.status} #{conn.resp_body}"
        assert footprint(a.uid, [b.uid]) == before, "#{fault}: no room was created"
        # the lines of THIS failure (the OIDC provisioning warnings of the request are older behaviour and name the account by design)
        assert error_lines(log) != [], "#{fault}: the failure is logged at ERROR"
        for line <- error_lines(log), uid <- [a.uid, b.uid], do: refute(line =~ uid, "#{fault}: the error log names no user id: #{line}")
        refute conn.resp_body =~ a.uid
      end

      # positive control: without the fault the same request works through the same delegating module
      Application.delete_env(:nebu, :atdd_mwl_count_fault)
      assert make_room(a, %{"invite" => [b.uid]}) |> is_binary()
    end

    test "POST /invite: 500 BEFORE the write (no row, event, wake-up, audit row); the error log names no user id", %{a: a, b: b} do
      room = make_room(a)
      before = footprint(a.uid, [b.uid])
      :pg.join("user:#{b.uid}", self())

      Application.put_env(:nebu, :atdd_mwl_count_fault, :db_down)
      {conn, log} = with_log(fn -> invite(a, room, b) end)

      assert conn.status == 500, "fail closed, got #{conn.status} #{conn.resp_body}"
      assert footprint(a.uid, [b.uid]) == before
      assert invitation_state(room, b.uid) == :none
      assert invite_events(room, b.uid) == []
      refute_receive {:new_invite, _}, 100
      assert error_lines(log) != []
      for line <- error_lines(log), uid <- [a.uid, b.uid], do: refute(line =~ uid, "the error log names no user id: #{line}")

      # positive control: the fault gone, the invitation passes and wakes B
      Application.delete_env(:nebu, :atdd_mwl_count_fault)
      invite!(a, room, b)
      assert_receive {:new_invite, ^room}, 1_000
    end
  end

  # ═══ AC6: /sync has no hidden cap ═══════════════════════════════════════════════════

  describe "AC6 - /sync lists EVERY pending invitation (D10: no per-response cap)" do
    test "120 pending invitations of B (more than the default per-invitee cap of 100): B's initial sync lists all 120 in rooms.invite", %{a: a, b: b} do
      # the rows are written through InviteDB / Room.DB (fixtures): no cap is involved, only the read side of /sync is under test
      ts = System.system_time(:millisecond) - 10_000

      rooms =
        for n <- 1..120 do
          room = "!sc#{T.rand(6)}:#{T.server_name()}"
          assert {:ok, _} = Nebu.Matrix.Room.DB.insert_room(room)
          assert :ok = Nebu.Matrix.Room.DB.insert_event(%{"event_id" => "$sc#{T.rand(8)}", "room_id" => room, "sender" => a.uid, "type" => "m.room.create", "state_key" => "", "content" => %{"creator" => a.uid}, "origin_server_ts" => ts + n})
          assert :ok = Nebu.Matrix.Room.InviteDB.insert_invitation(room, a.uid, b.uid)
          room
        end

      listed = invite_rooms(b)
      assert map_size(listed) == 120, "all 120 pending invitations are served, got #{map_size(listed)}"
      assert Enum.sort(Map.keys(listed)) == Enum.sort(rooms)
    end
  end

  # ═══ AC12: the Oracle gate tests ═══════════════════════════════════════════════════

  describe "AC12 (a) - Retry-After on EVERY 429 path" do
    test "join, invite and createRoom (create bucket denial and invite bucket denial): an integer >= 1 and retry_after_ms == Retry-After * 1000", %{a: a, b: b, c: c} do
      room = public_room(c)

      seed("join", a, 0)
      assert_429(join(a, room), "join")

      seed("invite", a, 0)
      assert_429(invite(a, room, b), "invite")

      seed("create_room", a, 0)
      assert_429(create(a, %{}), "createRoom, create bucket empty")

      seed("create_room", a, 20)
      seed("invite", a, 0)
      assert_429(create(a, %{"invite" => [b.uid]}), "createRoom, invite bucket empty")
      assert tokens("create_room", a) == 20.0, "the create bucket was not charged by the denial of the invite bucket"
    end
  end

  describe "AC12 (b) - a take_all denial carries the LARGER of the two waits, header and body agree" do
    test "invite bucket needs ~60 s, create bucket ~6 s: the answer is the 60 s wait (not 6, not the sum)", %{a: a} do
      # only the SHAPE of the list is charged before anything is read: 20 distinct well-formed ids
      invitees = for n <- 1..20, do: "@wait#{n}-#{T.rand(3)}:#{T.server_name()}"
      seed("create_room", a, 0)
      seed("invite", a, 0)

      secs = assert_429(create(a, %{"invite" => invitees}), "both buckets empty, 20 invitees")
      assert secs in 59..61, "the invite bucket (20 units at 20 / min = 60 s) is the larger wait, got #{secs} s"
      assert tokens("create_room", a) == 0.0 and tokens("invite", a) == 0.0, "nothing was charged"
    end

    test "create bucket needs ~6 s, invite bucket ~3 s: the answer is the 6 s wait", %{a: a} do
      invitees = for n <- 1..20, do: "@wait#{n}-#{T.rand(3)}:#{T.server_name()}"
      seed("create_room", a, 0)
      # 19 of the 20 invite units: one missing = 3 s at 20 / min
      seed("invite", a, 19)

      secs = assert_429(create(a, %{"invite" => invitees}), "create empty, invite one short")
      assert secs in 6..7, "the create bucket (1 unit at 10 / min = 6 s) is the larger wait, got #{secs} s"
      assert_in_delta tokens("invite", a), 19.0, 1.0e-6, "the invite bucket was not charged by the create bucket's denial"
    end
  end

  describe "AC12 (c) - the three cap 403 bodies are EXACTLY errcode + error" do
    test "per inviter, per pair and per invitee: {errcode: M_FORBIDDEN, error: <fixed text>}, application/json, never M_LIMIT_EXCEEDED, no admin_contact / retry_after_ms", %{a: a, b: b, c: c} do
      # per pair (cap 1)
      put_cap(:invite_max_pending_per_pair, 1)
      invite!(a, make_room(a), b)
      conn = invite(a, make_room(a), b)
      assert_cap_403(conn, @pair_cap_text, "pair")
      assert Map.keys(T.json(conn)) |> Enum.sort() == ["errcode", "error"]

      # per invitee (cap 1, B already holds one)
      put_cap(:invite_max_pending_per_pair, 10)
      put_cap(:invite_max_pending_per_invitee, 1)
      conn = invite(c, make_room(c), b)
      assert_cap_403(conn, @invitee_cap_text, "invitee")
      assert Map.keys(T.json(conn)) |> Enum.sort() == ["errcode", "error"]

      # per inviter (cap 1, A already holds one)
      put_cap(:invite_max_pending_per_invitee, 100)
      put_cap(:invite_max_pending_per_inviter, 1)
      conn = invite(a, make_room(a), c)
      assert_cap_403(conn, @inviter_cap_text, "inviter")
      assert Map.keys(T.json(conn)) |> Enum.sort() == ["errcode", "error"]
    end
  end

  describe "AC12 (d) - an ignored inviter learns nothing from the answer" do
    test "B ignores A: A's POST /invite answers 200 {} like any invite, the row exists and COUNTS towards the pair cap, and B's initial and incremental /sync do not list it", %{a: a, b: b, c: c} do
      since = sync(b)["next_batch"]
      assert put_account_data(b, "m.ignored_user_list", %{"ignored_users" => %{a.uid => %{}}}).status == 200

      control_room = make_room(c)
      control = invite(c, control_room, b)

      put_cap(:invite_max_pending_per_pair, 1)
      room = make_room(a)
      ignored = invite(a, room, b)

      assert ignored.status == 200 and ignored.resp_body == "{}"
      assert ignored.resp_body == control.resp_body, "byte-identical to the invitation of a user who is not ignored"
      assert invitation_state(room, b.uid) == :pending, "the row exists"
      assert [%{"membership" => "invite"}] = invite_events(room, b.uid)

      # it COUNTS: the second invitation by A is the pair cap
      assert_cap_403(invite(a, make_room(a), b), @pair_cap_text, "second invitation of an ignored inviter")

      # B's sync: the ignored inviter's invitation is in no section, the other one is there (positive control)
      initial = invite_rooms(b)
      assert Map.has_key?(initial, control_room)
      refute Map.has_key?(initial, room), "initial sync"

      incremental = invite_rooms(b, since)
      assert Map.has_key?(incremental, control_room), "incremental sync: the invitation of the non-ignored inviter IS delivered (positive control)"
      refute Map.has_key?(incremental, room), "incremental sync"
    end
  end

  describe "AC12 (e) - the re-join positive control" do
    test "a joined user's POST /join answers 200 {room_id}, writes no second join event and costs exactly ONE join token", %{a: a, b: b} do
      room = public_room(a)

      first = join(b, room)
      assert first.status == 200 and T.json(first) == %{"room_id" => room}
      events_after_first = member_events(room, b.uid)
      assert [%{"membership" => "join"}] = events_after_first
      assert tokens("join", b) == 29.0

      again = join(b, room)
      assert again.status == 200 and T.json(again) == %{"room_id" => room}
      assert member_events(room, b.uid) == events_after_first, "no second join event"
      assert tokens("join", b) == 28.0, "the idempotent re-join is charged exactly one token"
    end
  end

  describe "AC12 (f) - the charge comes before the already-invited no-op" do
    test "an already-invited target with the inviter's invite bucket EMPTY is 429, not the 200 no-op; with a token left it is the 200 no-op", %{a: a, b: b} do
      room = make_room(a)
      invite!(a, room, b)

      seed("invite", a, 0)
      assert_429(invite(a, room, b), "already-invited no-op with an empty bucket")

      seed("invite", a, 1)
      conn = invite(a, room, b)
      assert conn.status == 200 and conn.resp_body == "{}", "positive control: the no-op is the 200 {}"
    end
  end

  describe "AC12 (g) - no limiter-free join path" do
    test "POST /rooms/{roomId}/join and POST /knock/{roomIdOrAlias} are still unrouted: 404 M_UNRECOGNIZED, authenticated and not, and they touch no join bucket", %{a: a} do
      room = public_room(a)
      paths = [path(room, "join"), "/_matrix/client/v3/knock/#{enc(room)}"]

      unrecognized = %{"errcode" => "M_UNRECOGNIZED", "error" => "Unrecognized request"}

      for p <- paths do
        authed = T.matrix_request(:post, p, a.at, body: %{})
        assert authed.status == 404 and T.json(authed) == unrecognized, "authenticated #{p}: #{authed.status} #{authed.resp_body}"

        anon =
          Plug.Test.conn(:post, p, "{}")
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Map.put(:remote_ip, T.unique_ip())
          |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

        assert anon.status == 404 and T.json(anon) == unrecognized, "unauthenticated #{p}: #{anon.status} #{anon.resp_body}"
      end

      assert tokens("join", a) == nil, "the unrouted paths charged no join token"
    end
  end
end
