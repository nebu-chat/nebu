defmodule Nebu.Web.MediaCreateTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/2a-post-media-create`.

  `POST /_matrix/media/v1/create` — Matrix Client-Server API v1.18 (core-stable
  since v1.7, no MSC label). Reserves a `media_id` (via `Nebu.Media.StateMachine`,
  Story 1b) and returns `{content_uri, unused_expires_at}` — no bytes are read,
  stored, or persisted here (that begins in Story 2b's `PUT .../upload/...`).

  ## Corrected technical design (coordinator, superseding the story's stale
  `StateMachine.reserve/1` sketch — see the story's own header note)

  * The dev-story implementation is expected to add a NEW genesis function on
    `Nebu.Media.StateMachine` (e.g. `create/1`) that INSERTs a fresh
    `media_files` row in `state: :reserved` plus the matching
    `media_state_transitions` audit row (`from_state: nil, to_state: :reserved,
    actor_type: :system, actor_id: nil`) in one `Repo.transaction/1` — the
    `{:system, nil}` actor shape is already legal under `transition/4`'s
    existing guard, no ENUM/guard changes needed.
  * Uploader identity is NOT threaded through `media_state_transitions.actor_id`
    (that column only ever holds an admin UUID or NULL, per
    `Nebu.Media.StateMachine.actor/0`'s type). It lives in the pre-existing
    `media_files.uploader_user_id` TEXT column instead — same convention
    `Nebu.Media.upload/1` already uses (`server/lib/nebu/media.ex`). So test 1
    below asserts the seam was called with `uploader_user_id`, NOT that it
    shows up as `actor_id` on the transitions ledger (that ledger shape is
    Story 1b's own contract, exercised by `state_machine_test.exs`, not here).

  ## Test seams introduced by this story (added to `media_fakes.exs`)

    * `:media_permission_module`      — `can_upload?(user_id) :: boolean`
                                         (`Nebu.Web.MediaFakes.Permission`).
    * `:media_state_machine_module`   — `create(attrs) :: {:ok, media_id} |
                                         {:error, reason}`
                                         (`Nebu.Web.MediaFakes.StateMachine`).
    * `:media_db_module`'s new `count_pending_reservations/1` (AC3's
      `COUNT(*) ... WHERE uploader_user_id = $1 AND state = 'reserved'` seam).

  ## Why this MUST FAIL now

  `Nebu.Media.create/1` does not exist yet and `Nebu.Web.Router.Media` has no
  `post "/v1/create"` route — every `POST /_matrix/media/v1/create` currently
  falls through to that router's `match _` catch-all, which returns a plain
  `404 M_NOT_FOUND` ("Unrecognized request"), never the 200/403/429 bodies
  asserted below. This is expected RED (no route) until the dev-story wires
  the router entry + handler + StateMachine genesis function.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @create_path "/_matrix/media/v1/create"

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("uploader", priv)

    test_pid = self()

    # Pin every injectable boundary this handler will need, mirroring the
    # convention already established by media_upload_test.exs/media_fakes.exs:
    # tests supply a closure via Application env; the fake module dispatches
    # to it, falling back to a permissive default when unset.
    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_permission_module, MediaFakes.Permission)
    Application.put_env(:nebu_http, :media_state_machine_module, MediaFakes.StateMachine)

    Application.put_env(:nebu_http, :media_permission_fun, fn _user -> true end)
    Application.put_env(:nebu_http, :media_pending_count_fun, fn _uploader -> 0 end)

    Application.put_env(:nebu_http, :media_state_machine_create_fun, fn attrs ->
      send(test_pid, {:state_machine_create, attrs})
      {:ok, Map.fetch!(attrs, :media_id)}
    end)

    # These AC1-happy-path tests are not about the per-IP abuse limiter — mirror
    # media_upload_test.exs's convention of disabling it for this suite.
    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_permission_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_permission_fun)
      Application.delete_env(:nebu_http, :media_pending_count_fun)
      Application.delete_env(:nebu_http, :media_state_machine_create_fun)
      Application.delete_env(:nebu_http, :media_max_pending_per_user)

      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    {:ok, token: token, user_id: uid}
  end

  defp post_create(headers, query \\ "") do
    path = if query == "", do: @create_path, else: @create_path <> "?" <> query

    conn =
      conn(:post, path)
      |> Map.put(:req_headers, [])

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    Nebu.Web.Router.call(conn, S.router_opts())
  end

  # ── AC1/AC2/AC5 happy path ──────────────────────────────────────────────────

  test "authenticated POST /create -> 200 with content_uri + unused_expires_at, " <>
         "reservation created via the StateMachine seam with correct uploader_user_id",
       %{token: token, user_id: uid} do
    now_ms = System.system_time(:millisecond)

    conn = post_create(S.auth(token))

    assert conn.status == 200,
           "expected 200 from POST #{@create_path}, got #{conn.status} " <>
             "(#{inspect(S.json(conn))}) — /v1/create route not implemented"

    body = S.json(conn)

    uri = body["content_uri"]
    assert is_binary(uri)
    assert String.starts_with?(uri, "mxc://#{S.server_name()}/")
    media_id = String.replace_prefix(uri, "mxc://#{S.server_name()}/", "")
    assert media_id != "" and not String.contains?(media_id, "/")
    # AC5: media_id is a URL-safe base64url token, no padding, no +/ chars.
    assert media_id =~ ~r/^[A-Za-z0-9_-]+$/,
           "media_id must be base64url-shaped (no padding, no +/), got #{inspect(media_id)}"

    expires_at = body["unused_expires_at"]
    assert is_integer(expires_at)
    assert expires_at > now_ms, "unused_expires_at must be a future ms-epoch timestamp"

    # The reservation must go through the injected StateMachine genesis seam —
    # never a raw SQL insert into media_files — and it must carry the
    # uploader's identity as `uploader_user_id` (NOT as a transitions actor_id;
    # see this file's moduledoc for why that assumption changed).
    assert_received {:state_machine_create, attrs}
    assert attrs.uploader_user_id == uid
    assert attrs.server_name == S.server_name()
    assert attrs.media_id == media_id

    # Exactly one state-machine invocation on the happy path — the seam must
    # not be invoked twice for a single successful reservation (contrast with
    # the collision-retry test below, which legitimately expects two calls).
    refute_received {:state_machine_create, _second_attrs}
  end

  # ── AC5 collision-resistant generation ──────────────────────────────────────

  test "POST /create twice returns two distinct media_ids", %{token: token} do
    conn1 = post_create(S.auth(token))
    conn2 = post_create(S.auth(token))

    assert conn1.status == 200,
           "expected 200 from first POST #{@create_path}, got #{conn1.status}"

    assert conn2.status == 200,
           "expected 200 from second POST #{@create_path}, got #{conn2.status}"

    uri1 = S.json(conn1)["content_uri"]
    uri2 = S.json(conn2)["content_uri"]

    assert is_binary(uri1) and is_binary(uri2)
    assert uri1 != uri2
  end

  # ── AC3: 429 M_LIMIT_EXCEEDED on pending-upload cap ────────────────────────

  test "POST /create when max_pending_per_user is exceeded -> 429 M_LIMIT_EXCEEDED " <>
         "with retry_after_ms, no reservation created",
       %{token: token} do
    Application.put_env(:nebu_http, :media_max_pending_per_user, 1)
    # Simulate the caller already holding 1 (i.e. at the configured cap)
    # :reserved row, per the AC3 counting seam.
    Application.put_env(:nebu_http, :media_pending_count_fun, fn _uploader -> 1 end)

    conn = post_create(S.auth(token))

    assert conn.status == 429,
           "expected 429 from POST #{@create_path} at the pending cap, got #{conn.status} " <>
             "(#{inspect(S.json(conn))})"

    body = S.json(conn)
    assert body["errcode"] == "M_LIMIT_EXCEEDED"
    assert is_integer(body["retry_after_ms"])

    # The permission/pending-count gate must short-circuit BEFORE any
    # reservation is created.
    refute_received {:state_machine_create, _attrs}
  end

  # ── AC4: 403 M_FORBIDDEN when the caller lacks upload permission ──────────

  test "POST /create for a user without upload permission -> 403 M_FORBIDDEN, " <>
         "no reservation created",
       %{token: token} do
    Application.put_env(:nebu_http, :media_permission_fun, fn _user -> false end)

    conn = post_create(S.auth(token))

    assert conn.status == 403,
           "expected 403 from POST #{@create_path} for a disallowed user, got #{conn.status} " <>
             "(#{inspect(S.json(conn))})"

    assert S.json(conn)["errcode"] == "M_FORBIDDEN"

    refute_received {:state_machine_create, _attrs}
  end

  # ── Technical Requirements §6: permission check MUST run before the ────────
  # ── pending-count check — a forbidden user must never learn their pending- ─
  # ── upload count via a 429 instead of a 403. ───────────────────────────────

  test "POST /create when the caller BOTH lacks upload permission AND is over the " <>
         "pending cap -> 403 M_FORBIDDEN, never 429 M_LIMIT_EXCEEDED",
       %{token: token} do
    # Configure BOTH failure conditions simultaneously: the permission gate
    # must short-circuit first, so the pending-count gate is never reached
    # (and its result is therefore irrelevant/never observed by the client).
    Application.put_env(:nebu_http, :media_permission_fun, fn _user -> false end)
    Application.put_env(:nebu_http, :media_max_pending_per_user, 1)
    Application.put_env(:nebu_http, :media_pending_count_fun, fn _uploader -> 1 end)

    conn = post_create(S.auth(token))

    assert conn.status == 403,
           "permission check (403) must run BEFORE the pending-count check (429) — " <>
             "a forbidden user must never learn their pending-count via a different " <>
             "error code, got #{conn.status} (#{inspect(S.json(conn))})"

    assert S.json(conn)["errcode"] == "M_FORBIDDEN"

    refute_received {:state_machine_create, _attrs}
  end

  # ── AC5 / Technical Requirements §5: media_id collision-retry path ─────────

  test "POST /create silently retries once on {:error, :media_id_taken} and " <>
         "returns 200 with the media_id from the successful SECOND attempt",
       %{token: token} do
    test_pid = self()
    {:ok, call_counter} = Agent.start_link(fn -> 0 end)
    rejected_media_id = "first-attempt-collided-media-id"
    winning_media_id = "second-attempt-succeeded-media-id"

    Application.put_env(:nebu_http, :media_state_machine_create_fun, fn attrs ->
      call_no = Agent.get_and_update(call_counter, fn n -> {n + 1, n + 1} end)
      send(test_pid, {:state_machine_create, attrs})

      case call_no do
        1 -> {:error, :media_id_taken}
        2 -> {:ok, winning_media_id}
      end
    end)

    conn = post_create(S.auth(token))

    assert conn.status == 200,
           "a {:error, :media_id_taken} collision must trigger exactly one silent " <>
             "retry and still return 200 to the client, got #{conn.status} " <>
             "(#{inspect(S.json(conn))})"

    body = S.json(conn)
    uri = body["content_uri"]

    refute String.contains?(uri, rejected_media_id),
           "content_uri must not carry the media_id from the rejected first attempt"

    assert String.ends_with?(uri, "/#{winning_media_id}"),
           "content_uri must carry the media_id from the successful second attempt, " <>
             "got #{inspect(uri)}"

    # Exactly two calls: one rejected collision, one successful retry — no
    # further (unnecessary) retries beyond that.
    assert_received {:state_machine_create, _first_attrs}
    assert_received {:state_machine_create, _second_attrs}
    refute_received {:state_machine_create, _third_attrs}
  end

  # ── MINOR: production defaults (no override) — max_pending_per_user = 20, ─
  # ── unused_expires_at window ~24h ──────────────────────────────────────────

  test "POST /create with NO config override uses the production defaults: " <>
         "max_pending_per_user = 20, unused_expires_at ~24h out",
       %{token: token} do
    now_ms = System.system_time(:millisecond)

    # 19 pending reservations is BELOW the production default cap (20) — the
    # reservation must still succeed, proving the real default is in effect
    # (not some other overridden value from another test).
    Application.put_env(:nebu_http, :media_pending_count_fun, fn _uploader -> 19 end)

    conn_ok = post_create(S.auth(token))

    assert conn_ok.status == 200,
           "expected the production default max_pending_per_user (20) to allow a " <>
             "19th pending reservation, got #{conn_ok.status} (#{inspect(S.json(conn_ok))})"

    expires_at = S.json(conn_ok)["unused_expires_at"]

    assert_in_delta expires_at - now_ms,
                    86_400_000,
                    60_000,
                    "unused_expires_at must default to ~24h (86_400_000 ms) from now, " <>
                      "got delta #{expires_at - now_ms}"

    # 20 pending reservations is AT the production default cap — the next
    # reservation must now be rejected.
    Application.put_env(:nebu_http, :media_pending_count_fun, fn _uploader -> 20 end)

    conn_limit = post_create(S.auth(token))

    assert conn_limit.status == 429,
           "expected the production default max_pending_per_user (20) to reject a " <>
             "21st pending reservation, got #{conn_limit.status} " <>
             "(#{inspect(S.json(conn_limit))})"
  end

  # ── AC7: 401 unauthenticated (mirrors media_upload_test.exs) ───────────────

  test "POST /create with NO Bearer token -> 401 M_MISSING_TOKEN" do
    conn = post_create([])

    assert conn.status == 401
    assert S.json(conn)["errcode"] == "M_MISSING_TOKEN"
  end

  test "POST /create with a garbage Bearer token -> 401 M_UNKNOWN_TOKEN" do
    conn = post_create([{"authorization", "Bearer not-a-real-jwt"}])

    assert conn.status == 401
    assert S.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
  end

  # ── AC6: stray query parameters are ignored, not rejected ──────────────────

  test "POST /create ignores an expires_at query parameter instead of rejecting it", %{
    token: token
  } do
    conn = post_create(S.auth(token), "expires_at=1234567890")

    assert conn.status == 200,
           "a stray query parameter must be silently ignored (200), got #{conn.status} " <>
             "(#{inspect(S.json(conn))})"

    expires_at = S.json(conn)["unused_expires_at"]

    assert expires_at != 1_234_567_890,
           "unused_expires_at must be server-computed, never echo a client-supplied value"
  end
end
