defmodule Nebu.Web.MediaDownloadStallTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control` —
  `2d-download-stall-mechanism` (AC1-AC7): the opt-in `?timeout_ms=N` stall on
  `:quarantined`/`:scanning` media, per
  `docs/stories/media-security-admin-control/2d-download-stall-mechanism.md`.

  Follows `Nebu.Web.MediaDownloadTest` / `Nebu.Web.MediaDownloadGateTest`'s
  Plug.Test/Plug.Conn + `Nebu.Web.MediaTestSupport` + `Nebu.Web.MediaFakes`
  conventions, plus the `Phoenix.PubSub` test-supervision pattern from
  `Nebu.Web.LogStoreTest` (`start_supervised!({Phoenix.PubSub, name:
  Nebu.PubSub})` when not already running).

  ## Why this MUST FAIL now

  `Nebu.Media.download/3,4` (server/lib/nebu/media.ex) does not read
  `conn.query_params["timeout_ms"]` at all today — every request goes straight
  to Story 1c's immediate state → response mapping
  (`with_authorised_media/4` → `download_gate/1`), regardless of any query
  string. `Nebu.Media.DownloadStall` (server/lib/nebu/media/download_stall.ex)
  does not exist. `Nebu.Media.max_stall_ms/0` / `max_concurrent_stalls/0` do
  not exist. There is no `Phoenix.PubSub.subscribe/2` call anywhere in
  `lib/nebu/media.ex`.

  Tests 1-4, 7, 9 assert WALL-CLOCK TIMING (the stall must actually block, and
  for a bounded, correct duration) and/or a DIFFERENT status/errcode than the
  immediate state gives today (tests 3/4) — these fail today because the
  request currently always resolves near-instantly off the row's CURRENT
  state, never waiting and never reacting to a later broadcast.

  Tests 5, 6, 8 are the "no regression" pins for AC1/AC3/AC7 (absent,
  malformed, and `:reserved` all must behave EXACTLY like Story 1c, i.e.
  immediately, with no subscribe). Because `timeout_ms` is not read AT ALL
  today, these three currently PASS VACUOUSLY (every request already behaves
  as if `timeout_ms` were absent, since nothing consults it) — this is
  expected and correct for a "must never change" contract: they exist to
  catch a FUTURE regression once the stall path is wired in, not to prove the
  new capability exists. They are kept in this file rather than deferred so
  the full acceptance-test suite for this story lives in one place, and so
  dev-story's own manual smoke-check has them as an always-on safety net from
  the very first commit.

  ## PubSub coordination note (Story 4b not yet landed)

  Story 4b's `MediaScanWorker` (the real producer that would broadcast on
  scan completion) has not landed yet — `Nebu.Media.StateMachine.transition/4`
  does NOT broadcast, and `Nebu.Media.ScanEnqueue` is a no-op stub. Per the
  story's Technical Requirements, these tests simulate the future producer
  manually: a background `Task` mutates a test-local, in-memory "current
  state" (read by the injected `:media_lookup_fun` fake — there is no live
  Postgres row here, matching `MediaDownloadGateTest`'s all-fake-boundary
  style) and THEN calls `Phoenix.PubSub.broadcast(Nebu.PubSub,
  "media:\#{media_id}", {:media_state_transition, media_id, new_state})`
  itself, exactly mirroring what 4b/1b will eventually do on every terminal
  transition out of `:quarantined`/`:scanning`. `Nebu.Media.StateMachine`'s
  real `transition/4` (which requires a live `Nebu.Repo`) is intentionally
  NOT invoked here — this test file has no `@tag :integration` / DB
  dependency, matching `MediaDownloadGateTest`'s existing all-fake-boundary
  convention, so mutating the fake's backing state directly (rather than a
  real DB row) is the house-consistent choice for "the test's row-seeding
  helper" alternative the story explicitly permits.

  ## Known gap (flagged for code-review / dev-story)

  The lost-wakeup race (AC4/Technical Requirements: subscribe-before-recheck
  ordering, so a transition landing in the narrow window between the
  handler's first state read and the `Phoenix.PubSub.subscribe/2` call is not
  silently missed) is not independently exercised at this acceptance-test
  level — reliably winning that race from outside the process in a
  black-box HTTP test is not practical (there is no hook to pause the
  handler between "read" and "subscribe"). It is covered indirectly by tests
  1/3/4 (which prove SOME broadcast arriving after the request starts is
  observed), but a dedicated white-box/unit-level test of
  `Nebu.Media.DownloadStall`'s subscribe-then-recheck ordering (once that
  module exists) is recommended for dev-story or test-review to add.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.MediaTestSupport, as: S
  alias Nebu.Web.MediaFakes

  @plaintext "the-quick-brown-fox-jumps-over-the-lazy-dog-image-bytes"
  @room_id "!room:test.local"

  # 1c's deny-state → {status, errcode, error message} table
  # (server/lib/nebu/media.ex download_gate/1 + gate_message/1), reused here
  # so AC1's "absent behaves exactly like 1c" regression pin doesn't
  # duplicate a second copy of the mapping that could drift from the real one.
  # media-security-admin-control/6a-routine-state-actions (Kassandra security-review,
  # 2026-07-19): :admin_blocked was corrected from {451, "M_NOT_FOUND"} to
  # {404, "M_NOT_FOUND"} — byte-identical status AND body to :infected/:deleted/
  # :hard_deleted, not merely an anonymized body behind a distinguishing 451
  # status line. See ADR-026's 2026-07-19 correction.
  @deny_table [
    {:reserved, 451, "M_NOT_YET_UPLOADED", "Media not yet available"},
    {:quarantined, 451, "M_NOT_YET_UPLOADED", "Media not yet available"},
    {:scanning, 451, "M_NOT_YET_UPLOADED", "Media not yet available"},
    {:scan_failed, 451, "M_NOT_YET_UPLOADED", "Media not yet available"},
    {:admin_blocked, 404, "M_NOT_FOUND", "Media not found"},
    {:infected, 404, "M_NOT_FOUND", "Media not found"},
    {:deleted, 404, "M_NOT_FOUND", "Media not found"},
    {:hard_deleted, 404, "M_NOT_FOUND", "Media not found"}
  ]

  setup do
    priv = S.setup_oidc_keys()
    {uid, token} = S.bearer_for("kai", priv)
    {ciphertext, key_hex, nonce_hex} = S.encrypt_like_go(@plaintext)

    {:ok, state_agent} = Agent.start_link(fn -> %{} end)

    Application.put_env(:nebu_http, :media_db_module, MediaFakes.DB)
    Application.put_env(:nebu_http, :media_storage_module, MediaFakes.Storage)
    Application.put_env(:nebu_http, :media_membership_module, MediaFakes.Membership)

    # kai is a member of every media's room in this file — these tests exist
    # to exercise the STATE/stall gate, not the membership check.
    Application.put_env(:nebu_http, :media_member_fun, fn room, user ->
      room == @room_id and user == uid
    end)

    # A single ciphertext/key/nonce triple is reused for every media_id in
    # this file (only the lifecycle `state` varies per test/media_id).
    Application.put_env(:nebu_http, :media_storage_get_fun, fn _key -> {:ok, ciphertext} end)

    # `state_agent` holds a %{media_id => state} map — the test-local stand-in
    # for `media_files.state` (no live Postgres row here, see moduledoc). The
    # lookup fake re-reads it on EVERY call, so a background Task can mutate
    # it mid-request to simulate the state actually changing while a (future)
    # stall wait is in progress.
    Application.put_env(:nebu_http, :media_lookup_fun, fn server, media_id ->
      if server == S.server_name() do
        case Agent.get(state_agent, &Map.fetch(&1, media_id)) do
          {:ok, state} ->
            {:ok,
             S.media_row(
               media_id: media_id,
               content_type: "image/jpeg",
               file_size: byte_size(@plaintext),
               aes_key_hex: key_hex,
               nonce_hex: nonce_hex,
               room_id: @room_id,
               storage_key: media_id,
               state: state
             )}

          :error ->
            {:error, :not_found}
        end
      else
        {:error, :not_found}
      end
    end)

    on_exit(fn ->
      for k <- [
            :media_db_module,
            :media_storage_module,
            :media_membership_module,
            :media_lookup_fun,
            :media_storage_get_fun,
            :media_member_fun
          ],
          do: Application.delete_env(:nebu_http, k)

      # A normally-exiting ExUnit test process exits with reason `:normal`,
      # which does NOT propagate to a non-trapping linked process — the
      # Agent would otherwise leak past this test. Explicit stop, mirroring
      # this file's own more careful start_supervised!/1 treatment of
      # Nebu.PubSub (test-review MINOR finding).
      if Process.alive?(state_agent), do: Agent.stop(state_agent)
    end)

    {:ok, token: token, user_id: uid, state_agent: state_agent}
  end

  # ── shared helpers (mirrors media_download_test.exs / media_download_gate_test.exs) ──

  defp get(path, headers) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, S.router_opts())
  end

  defp download_path(media_id), do: "/_matrix/media/v3/download/#{S.server_name()}/#{media_id}"
  defp download_path(media_id, query), do: download_path(media_id) <> "?" <> query

  defp topic(media_id), do: "media:#{media_id}"

  defp put_state(state_agent, media_id, state) do
    Agent.update(state_agent, &Map.put(&1, media_id, state))
  end

  # Ensures Nebu.PubSub is up (it is already started unconditionally by
  # Nebu.Application today, but this mirrors log_store_test.exs's own
  # defensive pattern so this file does not implicitly depend on
  # Nebu.Application's current supervision-tree shape).
  defp ensure_pubsub_started! do
    case Process.whereis(Nebu.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: Nebu.PubSub})
      _pid -> :ok
    end
  end

  # Simulates the future Story 4b producer: after `ms`, updates the fake's
  # backing state AND manually broadcasts
  # `{:media_state_transition, media_id, new_state}` on `"media:#{media_id}"`
  # — exactly the contract this story's consumer (Nebu.Media.DownloadStall,
  # not yet implemented) must react to. Runs in an unlinked Task so a slow
  # test process teardown racing this callback can never fail the test.
  defp broadcast_after(ms, media_id, new_state, state_agent) do
    Task.start(fn ->
      Process.sleep(ms)
      if Process.alive?(state_agent), do: put_state(state_agent, media_id, new_state)

      if Process.whereis(Nebu.PubSub) do
        Phoenix.PubSub.broadcast(
          Nebu.PubSub,
          topic(media_id),
          {:media_state_transition, media_id, new_state}
        )
      end
    end)
  end

  defp with_media_config(overrides, fun) do
    original = Application.get_env(:nebu, Nebu.Media, [])
    Application.put_env(:nebu, Nebu.Media, Keyword.merge(original, overrides))

    try do
      fun.()
    after
      Application.put_env(:nebu, Nebu.Media, original)
    end
  end

  # ── AT1 — released mid-wait → 200 with file body, well before the window ──

  test "released within the timeout window returns 200 with the file body",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()
    media_id = "stall-released-#{System.unique_integer([:positive])}"
    put_state(agent, media_id, :scanning)

    broadcast_after(200, media_id, :released, agent)

    started = System.monotonic_time(:millisecond)
    conn = get(download_path(media_id, "timeout_ms=5000"), S.auth(token))
    elapsed = System.monotonic_time(:millisecond) - started

    assert conn.status == 200,
           "expected 200 once :released broadcasts ~200ms into a 5000ms stall window, " <>
             "got #{conn.status} — Nebu.Media.DownloadStall does not exist yet, so " <>
             "?timeout_ms is currently ignored and the immediate :scanning state denies with 451"

    assert conn.resp_body == @plaintext,
           "must serve the AES-256-GCM-decrypted original bytes, identical to 1c's success path"

    assert elapsed < 1_000,
           "must resolve promptly once :released broadcasts (~200ms in), not ride out the " <>
             "full 5000ms window; observed #{elapsed}ms"
  end

  # ── AT2 — no broadcast, timeout elapses → 1c deny for the still-:scanning state ──

  test "timeout elapses while still scanning falls back to the 1c deny response",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()
    media_id = "stall-timeout-#{System.unique_integer([:positive])}"
    put_state(agent, media_id, :scanning)

    started = System.monotonic_time(:millisecond)
    conn = get(download_path(media_id, "timeout_ms=200"), S.auth(token))
    elapsed = System.monotonic_time(:millisecond) - started

    assert conn.status == 451
    body = S.json(conn)
    assert body["errcode"] == "M_NOT_YET_UPLOADED"

    assert elapsed >= 150,
           "expected the handler to actually WAIT out ~200ms before falling back (not " <>
             "respond instantly) — Nebu.Media.DownloadStall does not exist yet, so " <>
             "?timeout_ms is currently ignored and the response returns immediately; " <>
             "observed #{elapsed}ms"

    assert elapsed < 1_000,
           "must not fall back to the spec's own absent-default 20000ms wait, nor any " <>
             "other multi-second wait; observed #{elapsed}ms"
  end

  # ── AT3 — :infected broadcast mid-wait → 404 promptly, not after the full window ──

  test "an infected-deny broadcast arriving mid-wait returns 404 promptly, not after the full timeout",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()
    media_id = "stall-infected-#{System.unique_integer([:positive])}"
    put_state(agent, media_id, :scanning)

    broadcast_after(150, media_id, :infected, agent)

    started = System.monotonic_time(:millisecond)
    conn = get(download_path(media_id, "timeout_ms=20000"), S.auth(token))
    elapsed = System.monotonic_time(:millisecond) - started

    assert conn.status == 404,
           "expected 404 once :infected broadcasts ~150ms into a 20000ms window, got " <>
             "#{conn.status} — today the immediate :scanning state denies with 451 instead"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_FOUND"
    assert body["error"] == "Media not found"

    assert elapsed < 750,
           "must resolve close to the ~150ms broadcast, not ride out the full 20000ms " <>
             "window (and not merely fall under a generous multi-second bound, which " <>
             "would still let a coarse polling loop slip through, AC5); observed #{elapsed}ms"
  end

  # ── AT4 — :admin_blocked broadcast mid-wait → byte-identical 404/M_NOT_FOUND promptly ──
  #
  # CORRECTED 2026-07-19 (Kassandra security-review, Story 6a): this test previously
  # asserted `conn.status == 451`, treating a distinguishable status line as
  # acceptable "anonymity" as long as the errcode was anonymized. See ADR-026's
  # 2026-07-19 correction — the status must be 404, identical to every other
  # terminal-negative state.

  test "admin_blocked broadcast arriving mid-wait returns the byte-identical 404/M_NOT_FOUND promptly",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()
    media_id = "stall-adminblocked-#{System.unique_integer([:positive])}"
    put_state(agent, media_id, :scanning)

    broadcast_after(150, media_id, :admin_blocked, agent)

    started = System.monotonic_time(:millisecond)
    conn = get(download_path(media_id, "timeout_ms=20000"), S.auth(token))
    elapsed = System.monotonic_time(:millisecond) - started

    assert conn.status == 404,
           "admin_blocked must return the SAME 404 status as a genuine not-found — a " <>
             "differing status line (e.g. 451) is itself a fingerprint, got #{conn.status}"

    body = S.json(conn)

    assert body["errcode"] == "M_NOT_FOUND",
           "expected the anonymized M_NOT_FOUND errcode (ADR-026) once :admin_blocked " <>
             "broadcasts mid-wait, got #{inspect(body["errcode"])} — today the immediate " <>
             ":scanning state denies with M_NOT_YET_UPLOADED instead, proving the deny-fast-" <>
             "path isn't wired for anything but the (currently nonexistent) stall mechanism"

    assert body["error"] == "Media not found"

    assert elapsed < 750,
           "must resolve close to the ~150ms broadcast, not ride out the full 20000ms " <>
             "window (and not merely fall under a generous multi-second bound, which " <>
             "would still let a coarse polling loop slip through, AC5); observed #{elapsed}ms"
  end

  # ── AT5 — no ?timeout_ms param: byte-for-byte 1c behavior, no regression, no subscribe ──

  test "no ?timeout_ms param behaves exactly like story 1c for every deny state (no regression, no subscribe)",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()

    for {state, expected_status, expected_errcode, expected_error} <- @deny_table do
      media_id = "stall-noparam-#{state}-#{System.unique_integer([:positive])}"
      put_state(agent, media_id, state)

      started = System.monotonic_time(:millisecond)
      conn = get(download_path(media_id), S.auth(token))
      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == expected_status,
             "state #{inspect(state)} without ?timeout_ms must return #{expected_status} " <>
               "exactly like 1c, got #{conn.status}"

      body = S.json(conn)
      assert body["errcode"] == expected_errcode
      assert body["error"] == expected_error

      assert Registry.lookup(Nebu.PubSub, topic(media_id)) == [],
             "no ?timeout_ms present must never subscribe to the media's PubSub topic " <>
               "(state #{inspect(state)}), found subscriber(s): " <>
               inspect(Registry.lookup(Nebu.PubSub, topic(media_id)))

      # A post-hoc Registry check alone can't distinguish "never subscribed"
      # from "subscribed, then already resolved and cleaned up before this
      # synchronous call returned" — a wall-clock bound directly asserts the
      # stall branch was never entered at all (test-review MAJOR finding).
      assert elapsed < 100,
             "state #{inspect(state)} without ?timeout_ms must resolve immediately " <>
               "(no stall branch entered), observed #{elapsed}ms"
    end
  end

  test "no ?timeout_ms param on :released still returns 200 with the file body (no regression, no subscribe)",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()
    media_id = "stall-noparam-released-#{System.unique_integer([:positive])}"
    put_state(agent, media_id, :released)

    started = System.monotonic_time(:millisecond)
    conn = get(download_path(media_id), S.auth(token))
    elapsed = System.monotonic_time(:millisecond) - started

    assert conn.status == 200
    assert conn.resp_body == @plaintext

    assert Registry.lookup(Nebu.PubSub, topic(media_id)) == [],
           ":released without ?timeout_ms must never subscribe to the media's PubSub topic"

    # Same rationale as the deny-table loop above: a post-hoc Registry check
    # alone can't tell "never subscribed" apart from "subscribed then already
    # resolved" — a wall-clock bound makes "stall branch never entered"
    # directly observable.
    assert elapsed < 100,
           ":released without ?timeout_ms must resolve immediately (no stall branch " <>
             "entered), observed #{elapsed}ms"
  end

  # ── AT6 — malformed ?timeout_ms values behave exactly like absent ──

  test "malformed timeout_ms values (non-integer, negative, zero) behave like absent",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()

    for raw <- ["abc", "-5", "0"] do
      media_id = "stall-malformed-#{System.unique_integer([:positive])}"
      put_state(agent, media_id, :scanning)

      started = System.monotonic_time(:millisecond)
      conn = get(download_path(media_id, "timeout_ms=#{raw}"), S.auth(token))
      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == 451,
             "?timeout_ms=#{raw} on :scanning must be treated as absent (immediate 451), " <>
               "got #{conn.status}"

      body = S.json(conn)
      assert body["errcode"] == "M_NOT_YET_UPLOADED"

      assert Registry.lookup(Nebu.PubSub, topic(media_id)) == [],
             "malformed ?timeout_ms=#{raw} must never trigger a PubSub subscribe"

      # Same rationale as test 5: a post-hoc Registry check alone can't tell
      # "never subscribed" apart from "subscribed then already resolved" — a
      # wall-clock bound makes "stall branch never entered" directly
      # observable (test-review MAJOR finding).
      assert elapsed < 100,
             "?timeout_ms=#{raw} on :scanning must resolve immediately (no stall branch " <>
               "entered), observed #{elapsed}ms"
    end
  end

  # ── AT7 — requested timeout_ms above the cap is clamped, not honored verbatim ──

  test "requested timeout_ms above the cap is clamped, not honored verbatim",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()

    with_media_config([max_stall_ms: 500], fn ->
      media_id = "stall-clamp-#{System.unique_integer([:positive])}"
      put_state(agent, media_id, :scanning)

      started = System.monotonic_time(:millisecond)
      conn = get(download_path(media_id, "timeout_ms=60000"), S.auth(token))
      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == 451
      body = S.json(conn)
      assert body["errcode"] == "M_NOT_YET_UPLOADED"

      assert elapsed >= 400,
             "expected max_stall_ms: 500 to clamp the effective wait to ~500ms, not honor " <>
               "the client's 60000ms verbatim (and not return instantly either) — " <>
               "Nebu.Media.max_stall_ms/0 does not exist yet and ?timeout_ms is ignored " <>
               "entirely today; observed #{elapsed}ms"

      assert elapsed < 1_500,
             "must not ride out the full, unclamped 60000ms window, nor any wait far " <>
               "beyond the configured 500ms cap; observed #{elapsed}ms"
    end)
  end

  # ── AT8 — :reserved is never stalled on, even with ?timeout_ms present ──

  test "reserved state is not stalled on even with ?timeout_ms present",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()
    media_id = "stall-reserved-#{System.unique_integer([:positive])}"
    put_state(agent, media_id, :reserved)

    started = System.monotonic_time(:millisecond)
    conn = get(download_path(media_id, "timeout_ms=5000"), S.auth(token))
    elapsed = System.monotonic_time(:millisecond) - started

    assert conn.status == 451
    body = S.json(conn)
    assert body["errcode"] == "M_NOT_YET_UPLOADED"

    assert elapsed < 150,
           ":reserved must never be stalled on even with ?timeout_ms present — expected an " <>
             "immediate (<150ms) deny, observed #{elapsed}ms"

    assert Registry.lookup(Nebu.PubSub, topic(media_id)) == [],
           ":reserved with ?timeout_ms present must never subscribe to the media's PubSub topic"
  end

  # ── AT9 — exceeding the concurrent-stall ceiling degrades to the no-stall response ──

  test "exceeding the concurrent-stall ceiling degrades to the no-stall response",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()

    with_media_config([max_concurrent_stalls: 1], fn ->
      first_media_id = "stall-ceiling-first-#{System.unique_integer([:positive])}"
      second_media_id = "stall-ceiling-second-#{System.unique_integer([:positive])}"

      put_state(agent, first_media_id, :scanning)
      put_state(agent, second_media_id, :scanning)

      first_task =
        Task.async(fn ->
          started = System.monotonic_time(:millisecond)
          conn = get(download_path(first_media_id, "timeout_ms=2000"), S.auth(token))
          {conn, System.monotonic_time(:millisecond) - started}
        end)

      # Give the first request a head start so it (once implemented) has
      # already taken the single available stall slot before the second
      # request arrives.
      Process.sleep(100)

      started = System.monotonic_time(:millisecond)
      second_conn = get(download_path(second_media_id, "timeout_ms=5000"), S.auth(token))
      second_elapsed = System.monotonic_time(:millisecond) - started

      assert second_conn.status == 451,
             "the second request must degrade to the immediate 1c deny response once the " <>
               "single stall slot is already held, got #{second_conn.status}"

      body = S.json(second_conn)
      assert body["errcode"] == "M_NOT_YET_UPLOADED"

      assert second_elapsed < 500,
             "a request denied a stall slot must respond immediately, not block; observed " <>
               "#{second_elapsed}ms"

      {first_conn, first_elapsed} = Task.await(first_task, 3_000)

      assert first_conn.status == 451,
             "the first (slot-holding) request must still resolve on its own timeout, " <>
               "unaffected by the second request being turned away, got #{first_conn.status}"

      assert first_elapsed >= 1_500,
             "the first request must have genuinely held its stall slot for close to its " <>
               "own 2000ms window (not been preempted, not returned instantly) — " <>
               "Nebu.Media.max_concurrent_stalls/0 does not exist yet and no request " <>
               "currently stalls at all; observed #{first_elapsed}ms"
    end)
  end

  # ── fix-cycle 1 (MINOR-2) — a misconfigured non-positive max_stall_ms must
  #    never crash a stall-eligible download; it degrades to the immediate 1c
  #    deny instead of raising FunctionClauseError (a 500). ──

  test "a non-positive max_stall_ms config degrades stall-eligible downloads to the immediate 1c deny (no crash)",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()

    for bad_cap <- [-1, 0] do
      with_media_config([max_stall_ms: bad_cap], fn ->
        media_id = "stall-badcap-#{bad_cap}-#{System.unique_integer([:positive])}"
        put_state(agent, media_id, :scanning)

        started = System.monotonic_time(:millisecond)
        conn = get(download_path(media_id, "timeout_ms=5000"), S.auth(token))
        elapsed = System.monotonic_time(:millisecond) - started

        assert conn.status == 451,
               "max_stall_ms: #{bad_cap} on :scanning with ?timeout_ms present must degrade " <>
                 "to the immediate 1c deny (451), NOT crash with a FunctionClauseError/500; " <>
                 "got #{conn.status}"

        body = S.json(conn)
        assert body["errcode"] == "M_NOT_YET_UPLOADED"

        assert Registry.lookup(Nebu.PubSub, topic(media_id)) == [],
               "a non-positive max_stall_ms (#{bad_cap}) must never enter the stall branch " <>
                 "or subscribe to the media's PubSub topic"

        assert elapsed < 150,
               "a non-positive max_stall_ms (#{bad_cap}) must resolve immediately (no stall " <>
                 "branch entered), observed #{elapsed}ms"
      end)
    end
  end

  # ── fix-cycle 2 (MINOR) — a list-shaped ?timeout_ms (e.g. ?timeout_ms[]=1,
  #    which Plug parses into a List instead of a String) must never crash;
  #    it degrades to the immediate 1c deny like any other malformed value. ──

  test "list-shaped timeout_ms (array query syntax) behaves like absent, does not crash",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()
    media_id = "stall-listparam-#{System.unique_integer([:positive])}"
    put_state(agent, media_id, :scanning)

    started = System.monotonic_time(:millisecond)
    conn = get(download_path(media_id, "timeout_ms[]=1&timeout_ms[]=2"), S.auth(token))
    elapsed = System.monotonic_time(:millisecond) - started

    assert conn.status == 451,
           "a list-shaped ?timeout_ms[] must degrade to the immediate 1c deny (451), NOT " <>
             "crash with a FunctionClauseError/500; got #{conn.status}"

    body = S.json(conn)
    assert body["errcode"] == "M_NOT_YET_UPLOADED"

    assert Registry.lookup(Nebu.PubSub, topic(media_id)) == [],
           "a list-shaped ?timeout_ms[] must never enter the stall branch or subscribe"

    assert elapsed < 150,
           "a list-shaped ?timeout_ms[] must resolve immediately (no stall branch entered), " <>
             "observed #{elapsed}ms"
  end
end
