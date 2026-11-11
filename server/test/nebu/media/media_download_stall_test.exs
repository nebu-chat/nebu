defmodule Nebu.Web.MediaDownloadStallTest do
  @moduledoc """
  ATDD tests for `media-security-admin-control` — `2d-download-stall-mechanism`
  (AC1-AC7): the `?timeout_ms=N` stall on `:quarantined`/`:scanning` media, per
  `docs/stories/media-security-admin-control/2d-download-stall-mechanism.md`,
  plus `bugfix/media-download-451-scan-race` (see the section near the bottom):
  an ABSENT `timeout_ms` now stalls for the spec default window and
  `thumbnail/3` stalls too. In the pre-existing 2d tests below, "absent" and
  "malformed" no longer mean "no stall" for stallable states: an explicit
  `timeout_ms=0` (or a malformed value) is the no-stall form.

  Follows `Nebu.Web.MediaDownloadTest` / `Nebu.Web.MediaDownloadGateTest`'s
  Plug.Test/Plug.Conn + `Nebu.Web.MediaTestSupport` + `Nebu.Web.MediaFakes`
  conventions, plus the `Phoenix.PubSub` test-supervision pattern from
  `Nebu.Web.LogStoreTest` (`start_supervised!({Phoenix.PubSub, name:
  Nebu.PubSub})` when not already running).

  ## What the tests pin

  Tests 1-4, 7, 9 assert WALL-CLOCK TIMING (the stall must actually block, and
  for a bounded, correct duration) and/or a DIFFERENT status/errcode than the
  immediate state gives (tests 3/4): a request holding on `:quarantined`/
  `:scanning` must react to a later broadcast, never answer instantly off the
  row's current state.

  Tests 5, 6, 8 are the "no regression" pins for AC1/AC3/AC7 (a non-stallable
  state, `timeout_ms=0`/malformed, and `:reserved` all must behave EXACTLY
  like Story 1c, i.e. immediately, with no subscribe).

  ## PubSub coordination note

  The real producer is `Nebu.Media.MediaScanWorker.broadcast/2`, but it needs
  a live Repo/ClamAV. Per the story's Technical Requirements, these tests
  simulate the producer manually: a background `Task` mutates a test-local, in-memory "current
  state" (read by the injected `:media_lookup_fun` fake — there is no live
  Postgres row here, matching `MediaDownloadGateTest`'s all-fake-boundary
  style) and THEN calls `Phoenix.PubSub.broadcast(Nebu.PubSub,
  "media:\#{media_id}", {:media_state_transition, media_id, new_state})`
  itself, exactly mirroring what the scan worker does on every terminal
  transition out of `:quarantined`/`:scanning`. `Nebu.Media.StateMachine`'s
  real `transition/4` (which requires a live `Nebu.Repo`) is intentionally
  NOT invoked here — this test file has no `@tag :integration` / DB
  dependency, matching `MediaDownloadGateTest`'s existing all-fake-boundary
  convention, so mutating the fake's backing state directly (rather than a
  real DB row) is the house-consistent choice for "the test's row-seeding
  helper" alternative the story explicitly permits.

  ## Lost-wakeup race coverage

  The lost-wakeup race (AC4/Technical Requirements: subscribe-before-recheck
  ordering, so a transition landing in the narrow window between the
  handler's first state read and the `Phoenix.PubSub.subscribe/2` call is not
  silently missed) is not independently exercised at this HTTP level — reliably winning that race from outside the process in a
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

  # Bounded poll (never an open-ended wait) until a request is subscribed to
  # `media:<id>`, i.e. is genuinely inside the stall. Replaces hard sleeps as
  # test synchronisation.
  defp await_subscriber(media_id, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_subscriber(media_id, deadline)
  end

  defp poll_subscriber(media_id, deadline) do
    cond do
      Registry.lookup(Nebu.PubSub, topic(media_id)) != [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("no request subscribed to #{topic(media_id)} within the polling bound")

      true ->
        Process.sleep(5)
        poll_subscriber(media_id, deadline)
    end
  end

  # Bounded poll until the `media:<id>` topic has no subscriber left. The wait
  # task's Registry entry is removed asynchronously after it exits, so an
  # immediate `Registry.lookup == []` right after the response can flake.
  defp await_unsubscribed(media_id, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_unsubscribed(media_id, deadline)
  end

  defp poll_unsubscribed(media_id, deadline) do
    cond do
      Registry.lookup(Nebu.PubSub, topic(media_id)) == [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("subscription to #{topic(media_id)} leaked past the polling bound")

      true ->
        Process.sleep(5)
        poll_unsubscribed(media_id, deadline)
    end
  end

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
  # — exactly the contract the consumer (Nebu.Media.DownloadStall) reacts to
  # (the real producer is Nebu.Media.MediaScanWorker.broadcast/2). Runs in an unlinked Task so a slow
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
             "got #{conn.status} — the stall did not wait for the broadcast, so the " <>
             "immediate :scanning state denied with 451"

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
             "respond instantly); the response returned too early, " <>
             "observed #{elapsed}ms"

    assert elapsed < 1_000,
           "must not ride out the 20000ms max/default window, nor any " <>
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

  # bugfix/media-download-451-scan-race: an ABSENT `timeout_ms` no longer means
  # "no stall" for :quarantined/:scanning — it now means the spec default
  # (`default_stall_ms`, see the "default stall" describe block at the bottom
  # of this file). The immediate-1c pin below therefore covers only the
  # NON-stallable deny states; the stallable ones are pinned with an explicit
  # `timeout_ms=0` (the spec-defined "client waits 0 ms") further down.
  test "no ?timeout_ms param behaves exactly like story 1c for every non-stallable deny state (no regression, no subscribe)",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()

    non_stallable = Enum.reject(@deny_table, fn {state, _, _, _} -> state in [:quarantined, :scanning] end)

    for {state, expected_status, expected_errcode, expected_error} <- non_stallable do
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
      assert elapsed < 250,
             "state #{inspect(state)} without ?timeout_ms must resolve immediately " <>
               "(no stall branch entered), observed #{elapsed}ms"
    end
  end

  test "explicit timeout_ms=0 on :quarantined/:scanning behaves exactly like story 1c (immediate 451, no subscribe)",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()

    for state <- [:quarantined, :scanning] do
      media_id = "stall-zero-#{state}-#{System.unique_integer([:positive])}"
      put_state(agent, media_id, state)

      started = System.monotonic_time(:millisecond)
      conn = get(download_path(media_id, "timeout_ms=0"), S.auth(token))
      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == 451
      assert S.json(conn)["errcode"] == "M_NOT_YET_UPLOADED"
      assert Registry.lookup(Nebu.PubSub, topic(media_id)) == []
      assert elapsed < 250, "timeout_ms=0 on #{inspect(state)} must not stall; observed #{elapsed}ms"
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
    assert elapsed < 250,
           ":released without ?timeout_ms must resolve immediately (no stall branch " <>
             "entered), observed #{elapsed}ms"
  end

  # ── AT6 — malformed ?timeout_ms values behave like timeout_ms=0 (no stall) ──

  test "malformed timeout_ms values (non-integer, negative, zero) behave like timeout_ms=0 (no stall)",
       %{token: token, state_agent: agent} do
    ensure_pubsub_started!()

    for raw <- ["abc", "-5", "0"] do
      media_id = "stall-malformed-#{System.unique_integer([:positive])}"
      put_state(agent, media_id, :scanning)

      started = System.monotonic_time(:millisecond)
      conn = get(download_path(media_id, "timeout_ms=#{raw}"), S.auth(token))
      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == 451,
             "?timeout_ms=#{raw} on :scanning must be treated as no-stall (immediate 451), " <>
               "got #{conn.status}"

      body = S.json(conn)
      assert body["errcode"] == "M_NOT_YET_UPLOADED"

      assert Registry.lookup(Nebu.PubSub, topic(media_id)) == [],
             "malformed ?timeout_ms=#{raw} must never trigger a PubSub subscribe"

      # Same rationale as test 5: a post-hoc Registry check alone can't tell
      # "never subscribed" apart from "subscribed then already resolved" — a
      # wall-clock bound makes "stall branch never entered" directly
      # observable (test-review MAJOR finding).
      assert elapsed < 250,
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
               "the client's 60000ms verbatim (and not return instantly either); " <>
               "observed #{elapsed}ms"

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

    assert elapsed < 250,
           ":reserved must never be stalled on even with ?timeout_ms present — expected an " <>
             "immediate (<250ms) deny, observed #{elapsed}ms"

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

      # The first request must hold the single stall slot before the second
      # arrives: poll until it is subscribed instead of sleeping.
      await_subscriber(first_media_id)

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
               "own 2000ms window (not been preempted, not returned instantly); " <>
               "observed #{first_elapsed}ms"
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

        assert elapsed < 250,
               "a non-positive max_stall_ms (#{bad_cap}) must resolve immediately (no stall " <>
                 "branch entered), observed #{elapsed}ms"
      end)
    end
  end

  # ── fix-cycle 2 (MINOR) — a list-shaped ?timeout_ms (e.g. ?timeout_ms[]=1,
  #    which Plug parses into a List instead of a String) must never crash;
  #    it degrades to the immediate 1c deny like any other malformed value. ──

  test "list-shaped timeout_ms (array query syntax) behaves like timeout_ms=0 (no stall), does not crash",
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

    assert elapsed < 250,
           "a list-shaped ?timeout_ms[] must resolve immediately (no stall branch entered), " <>
             "observed #{elapsed}ms"
  end

  # ════════════════════════════════════════════════════════════════════════════
  # bugfix/media-download-451-scan-race — DEFAULT stall + thumbnail stall
  # (docs/stories/bugfix/media-download-451-scan-race.md, AC1-AC7)
  #
  # Element Web uploads and ~40ms later requests download + thumbnail WITHOUT
  # `timeout_ms`; the async ClamAV scan releases the file ~100ms after that.
  # Before the fix an absent `timeout_ms` meant "no stall" and
  # `Nebu.Media.thumbnail/3` never stalled at all, so both 451. Matrix CS API v1.18: `timeout_ms` defaults
  # to 20000 on all six media endpoints, the server SHOULD cap it.
  #
  # New config key: `config :nebu, Nebu.Media, default_stall_ms: 20_000`
  # (read via Nebu.Media.default_stall_ms/0, always clamped by max_stall_ms).
  # These tests drive it purely through app config + HTTP so they fail on
  # BEHAVIOUR (immediate 451) rather than on a missing function.
  #
  # Fast-config used throughout: default_stall_ms 250, max_stall_ms 600. Tests
  # that assert an EARLY return (broadcast mid-window) use a window far larger
  # than their bound (@window_cfg) so scheduler jitter cannot flip them.
  #
  # SPEC DEVIATION TRACKER (out of scope, ADR-026): after the wait the spec
  # answers `504 M_NOT_YET_UPLOADED`; Nebu answers `451`. Timeout assertions
  # below therefore assert the ERRCODE and `status in [451, 504]` via
  # `assert_not_yet_uploaded/1`, so a later 504 switch is a one-line change
  # there. A skipped `@tag :spec_deviation_451_vs_504` test pins the target.
  # ════════════════════════════════════════════════════════════════════════════

  @fast_cfg [default_stall_ms: 250, max_stall_ms: 600]
  @window_cfg [default_stall_ms: 2_000, max_stall_ms: 3_000]

  defp v1_dl(media_id), do: "/_matrix/client/v1/media/download/#{S.server_name()}/#{media_id}"
  defp v1_thumb(media_id), do: "/_matrix/client/v1/media/thumbnail/#{S.server_name()}/#{media_id}"
  defp v3_thumb(media_id), do: "/_matrix/media/v3/thumbnail/#{S.server_name()}/#{media_id}"

  @thumb_q "width=64&height=64&method=scale"

  # The ONE list of media GET endpoints that must stall identically (AC1 + AC2:
  # v3 and v1 share one code path): {label, kind}. Both the compile-time test
  # generation and the runtime `endpoints/0` builders derive from it.
  @endpoint_specs [
    {"v3 download", :v3_download},
    {"v1 download", :v1_download},
    {"v1 download/{fileName}", :v1_download_named},
    {"v3 thumbnail", :v3_thumbnail},
    {"v1 thumbnail", :v1_thumbnail}
  ]

  # {label, builder(media_id, extra_query | nil)}
  defp endpoints, do: for({label, kind} <- @endpoint_specs, do: {label, builder(kind)})

  defp builder(:v3_download), do: fn id, q -> with_q(download_path(id), q) end
  defp builder(:v1_download), do: fn id, q -> with_q(v1_dl(id), q) end
  defp builder(:v1_download_named), do: fn id, q -> with_q(v1_dl(id) <> "/cat.jpg", q) end
  defp builder(:v3_thumbnail), do: fn id, q -> with_q(v3_thumb(id), join_q(@thumb_q, q)) end
  defp builder(:v1_thumbnail), do: fn id, q -> with_q(v1_thumb(id), join_q(@thumb_q, q)) end

  defp thumbnail_endpoints, do: Enum.filter(endpoints(), fn {l, _} -> l =~ "thumbnail" end)

  defp with_q(path, nil), do: path
  defp with_q(path, ""), do: path
  defp with_q(path, q), do: path <> "?" <> q

  defp join_q(base, nil), do: base
  defp join_q(base, q), do: base <> "&" <> q

  defp new_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp timed_get(path, token) do
    started = System.monotonic_time(:millisecond)
    conn = get(path, S.auth(token))
    {conn, System.monotonic_time(:millisecond) - started}
  end

  # 451 today; spec says 504. Errcode is the stable part (see tracker above).
  defp assert_not_yet_uploaded(conn) do
    assert conn.status in [451, 504],
           "expected the not-yet-uploaded status (451 today, 504 per spec), got #{conn.status}"

    assert S.json(conn)["errcode"] == "M_NOT_YET_UPLOADED"
  end

  # Wraps the fake lookup so tests can count DB reads per request.
  defp count_lookups do
    inner = Application.get_env(:nebu_http, :media_lookup_fun)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Application.put_env(:nebu_http, :media_lookup_fun, fn server, id ->
      Agent.update(counter, &(&1 + 1))
      inner.(server, id)
    end)

    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)
    counter
  end

  # ── AC1 / AC2 / AC7 — absent timeout_ms, released mid-window → 200 ─────────

  describe "AC1/AC2/AC7: absent timeout_ms stalls (download + thumbnail, v3 + v1)" do
    for {label, kind} <- @endpoint_specs,
        initial <- [:quarantined, :scanning] do
      test "#{label}: #{initial} -> :released mid-window returns 200 with the bytes", %{token: token, state_agent: agent} do
        ensure_pubsub_started!()
        build = builder(unquote(kind))
        media_id = new_id("default-released")
        put_state(agent, media_id, unquote(initial))

        with_media_config(@window_cfg, fn ->
          broadcast_after(100, media_id, :released, agent)
          {conn, elapsed} = timed_get(build.(media_id, nil), token)

          assert conn.status == 200,
                 "no timeout_ms on a #{unquote(initial)} file must hold the request for the default " <>
                   "window and serve once :released broadcasts (~100ms in); got #{conn.status} " <>
                   "(absent timeout_ms must stall, thumbnail included)"

          assert conn.resp_body == @plaintext
          # PubSub-driven wake-up, not "sleep the whole default window".
          assert elapsed < 1_000, "must resolve on the broadcast (~100ms), not ride out the 2000ms window; observed #{elapsed}ms"
        end)
      end
    end

    test "AC7 race repro: download + thumbnail requested ~40ms after upload, scan finishes ~150ms in -> both 200",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("race-repro")
      put_state(agent, media_id, :quarantined)

      with_media_config([default_stall_ms: 600, max_stall_ms: 1_000], fn ->
        # t=0: upload finished, scan worker about to flip state at ~150ms.
        broadcast_after(150, media_id, :released, agent)
        Process.sleep(40)

        # Element fires thumbnail and download back-to-back, no timeout_ms.
        thumb = Task.async(fn -> timed_get(v1_thumb(media_id) <> "?" <> @thumb_q, token) end)
        dl = Task.async(fn -> timed_get(v1_dl(media_id), token) end)

        {thumb_conn, _} = Task.await(thumb, 3_000)
        {dl_conn, _} = Task.await(dl, 3_000)

        assert thumb_conn.status == 200, "thumbnail raced the scan and got #{thumb_conn.status}"
        assert dl_conn.status == 200, "download raced the scan and got #{dl_conn.status}"
        assert dl_conn.resp_body == @plaintext
      end)
    end

    test "the wait is event-driven: a subscriber exists while stalled and the row is not polled",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("default-eventdriven")
      put_state(agent, media_id, :quarantined)
      counter = count_lookups()

      with_media_config(@window_cfg, fn ->
        task = Task.async(fn -> get(download_path(media_id), S.auth(token)) end)
        await_subscriber(media_id)

        assert length(Registry.lookup(Nebu.PubSub, topic(media_id))) == 1,
               "a default-stalled request must be subscribed to media:<id> while waiting"

        put_state(agent, media_id, :released)
        Phoenix.PubSub.broadcast(Nebu.PubSub, topic(media_id), {:media_state_transition, media_id, :released})

        conn = Task.await(task, 3_000)
        assert conn.status == 200

        # initial read + subscribe-recheck + final authorised read; a polling
        # loop while stalled would add more.
        assert Agent.get(counter, & &1) <= 4,
               "stall must not poll the DB; saw #{Agent.get(counter, & &1)} lookups"
      end)
    end
  end

  # ── AC4 — never released: wait the window, then not-yet-uploaded ──────────

  describe "AC4: never released -> M_NOT_YET_UPLOADED only AFTER the default window" do
    for {label, kind} <- @endpoint_specs do
      test "#{label}: still scanning after the window", %{token: token, state_agent: agent} do
        ensure_pubsub_started!()
        build = builder(unquote(kind))
        media_id = new_id("default-timeout")
        put_state(agent, media_id, :scanning)

        # default 300ms, max 5000ms: "used max" (5000) or the 20000 built-in
        # blows the 1500ms bound by a wide margin, scheduler jitter does not.
        with_media_config([default_stall_ms: 300, max_stall_ms: 5_000], fn ->
          {conn, elapsed} = timed_get(build.(media_id, nil), token)

          assert_not_yet_uploaded(conn)

          assert elapsed >= 250,
                 "must wait ~default_stall_ms (300) before giving up, not answer instantly; observed #{elapsed}ms"

          assert elapsed < 1_500,
                 "must honour default_stall_ms (300), not max_stall_ms (5000) or the 20000 built-in; observed #{elapsed}ms"

          await_unsubscribed(media_id)
        end)
      end
    end

    @tag :skip
    @tag :spec_deviation_451_vs_504
    test "TRACKER (out of scope, needs ADR-026 decision): spec says 504 M_NOT_YET_UPLOADED after the wait, Nebu returns 451",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("deviation-504")
      put_state(agent, media_id, :scanning)

      with_media_config(@fast_cfg, fn ->
        {conn, _} = timed_get(download_path(media_id), token)
        assert conn.status == 504
        assert S.json(conn)["errcode"] == "M_NOT_YET_UPLOADED"
      end)
    end
  end

  describe "AC4: mid-window terminal broadcasts keep the ADR-026 mapping (default stall)" do
    for {broadcast_state, status, errcode} <- [
          {:infected, 404, "M_NOT_FOUND"},
          {:admin_blocked, 404, "M_NOT_FOUND"},
          {:deleted, 404, "M_NOT_FOUND"},
          {:hard_deleted, 404, "M_NOT_FOUND"},
          {:scan_failed, 451, "M_NOT_YET_UPLOADED"}
        ],
        {label, kind} <- @endpoint_specs,
        label in ["v3 download", "v1 thumbnail"] do
      test "#{label}: #{broadcast_state} broadcast mid-window -> #{status} #{errcode} promptly",
           %{token: token, state_agent: agent} do
        ensure_pubsub_started!()
        build = builder(unquote(kind))
        media_id = new_id("default-deny")
        put_state(agent, media_id, :scanning)

        with_media_config(@window_cfg, fn ->
          broadcast_after(100, media_id, unquote(broadcast_state), agent)
          {conn, elapsed} = timed_get(build.(media_id, nil), token)

          assert conn.status == unquote(status),
                 "#{unquote(broadcast_state)} mid-window must map exactly like ADR-026; got #{conn.status}"

          assert S.json(conn)["errcode"] == unquote(errcode)
          assert elapsed < 1_000, "must resolve on the broadcast (~100ms), not the 2000ms window; observed #{elapsed}ms"
        end)
      end
    end

    test "non-stallable states and unknown ids incur NO wait, NO subscription and exactly one lookup",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      counter = count_lookups()

      with_media_config(@fast_cfg, fn ->
        for {label, build} <- endpoints() do
          cases =
            [{:released, nil}] ++
              for {state, _, _, _} <- @deny_table, state not in [:quarantined, :scanning], do: {state, nil}

          for {state, _} <- cases do
            media_id = new_id("nostall-#{state}")
            put_state(agent, media_id, state)
            Agent.update(counter, fn _ -> 0 end)

            {conn, elapsed} = timed_get(build.(media_id, nil), token)

            assert elapsed < 250, "#{label} #{inspect(state)} must not stall; observed #{elapsed}ms"

            assert Registry.lookup(Nebu.PubSub, topic(media_id)) == []

            assert Agent.get(counter, & &1) == 1,
                   "#{label} #{inspect(state)}: today's single DB lookup, no extra pre-stall read; " <>
                     "got #{Agent.get(counter, & &1)}"

            expected =
              if state == :released,
                do: 200,
                else: Enum.find_value(@deny_table, fn {s, st, _, _} -> if s == state, do: st end)

            assert conn.status == expected, "#{label} #{inspect(state)} -> #{conn.status}, expected #{expected}"
          end

          # unknown id: 404, immediate, one lookup
          Agent.update(counter, fn _ -> 0 end)
          {conn, elapsed} = timed_get(build.(new_id("unknown"), nil), token)
          assert conn.status == 404
          assert S.json(conn)["errcode"] == "M_NOT_FOUND"
          assert elapsed < 250, "#{label} unknown id must not stall; observed #{elapsed}ms"
          assert Agent.get(counter, & &1) == 1
        end
      end)
    end
  end

  # ── AC3 — explicit timeout_ms wins; 0 = no stall; malformed = no stall ─────

  describe "AC3: explicit timeout_ms semantics (default stall configured to 250ms)" do
    test "timeout_ms=0 means no stall on every endpoint (immediate 451, no subscription)",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()

      with_media_config(@fast_cfg, fn ->
        for {label, build} <- endpoints() do
          media_id = new_id("explicit-zero")
          put_state(agent, media_id, :scanning)
          {conn, elapsed} = timed_get(build.(media_id, "timeout_ms=0"), token)

          assert_not_yet_uploaded(conn)
          assert elapsed < 250, "#{label}: timeout_ms=0 must not stall; observed #{elapsed}ms"
          assert Registry.lookup(Nebu.PubSub, topic(media_id)) == []
        end
      end)
    end

    test "malformed / negative / empty / array timeout_ms is treated as no-stall on every endpoint (documented rule)",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()

      with_media_config(@fast_cfg, fn ->
        for {label, build} <- endpoints(),
            q <- ["timeout_ms=abc", "timeout_ms=-5", "timeout_ms=", "timeout_ms=1.5", "timeout_ms=10ms", "timeout_ms[]=1&timeout_ms[]=2"] do
          media_id = new_id("malformed")
          put_state(agent, media_id, :scanning)
          {conn, elapsed} = timed_get(build.(media_id, q), token)

          assert_not_yet_uploaded(conn)
          assert elapsed < 250, "#{label} ?#{q}: malformed value must not stall (nor fall back to the default); observed #{elapsed}ms"
          assert Registry.lookup(Nebu.PubSub, topic(media_id)) == []
        end
      end)
    end

    test "an explicit timeout_ms smaller than the default wins (waits ~150ms, not the 1500ms default)",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()

      with_media_config([default_stall_ms: 1_500, max_stall_ms: 5_000], fn ->
        for {label, build} <- endpoints() do
          media_id = new_id("explicit-small")
          put_state(agent, media_id, :scanning)
          {conn, elapsed} = timed_get(build.(media_id, "timeout_ms=150"), token)

          assert_not_yet_uploaded(conn)
          assert elapsed >= 120, "#{label}: must wait ~150ms; observed #{elapsed}ms (no stall?)"
          assert elapsed < 1_000, "#{label}: explicit 150ms must win over default 1500ms; observed #{elapsed}ms"
        end
      end)
    end

    test "an explicit timeout_ms larger than the default (but under the cap) wins: release at ~400ms is observed",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()

      with_media_config([default_stall_ms: 250, max_stall_ms: 1_000], fn ->
        for {label, build} <- endpoints() do
          media_id = new_id("explicit-large")
          put_state(agent, media_id, :scanning)
          broadcast_after(400, media_id, :released, agent)
          {conn, _} = timed_get(build.(media_id, "timeout_ms=900"), token)
          assert conn.status == 200, "#{label}: explicit timeout_ms=900 must outlive the 250ms default; got #{conn.status}"
        end
      end)
    end

    test "explicit timeout_ms above max_stall_ms is clamped on thumbnails too",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()

      with_media_config([default_stall_ms: 250, max_stall_ms: 500], fn ->
        for {label, build} <- thumbnail_endpoints() do
          media_id = new_id("clamp-thumb")
          put_state(agent, media_id, :scanning)
          {conn, elapsed} = timed_get(build.(media_id, "timeout_ms=60000"), token)

          assert_not_yet_uploaded(conn)
          assert elapsed >= 400, "#{label}: must wait ~max_stall_ms; observed #{elapsed}ms"
          assert elapsed < 2_500, "#{label}: must be clamped to max_stall_ms (500), observed #{elapsed}ms"
        end
      end)
    end

    test "default_stall_ms is itself clamped by max_stall_ms (absent param, default 60000, max 500)",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()

      with_media_config([default_stall_ms: 60_000, max_stall_ms: 500], fn ->
        for {label, build} <- endpoints() do
          media_id = new_id("clamp-default")
          put_state(agent, media_id, :scanning)
          {conn, elapsed} = timed_get(build.(media_id, nil), token)

          assert_not_yet_uploaded(conn)
          assert elapsed >= 400, "#{label}: default must stall ~max_stall_ms; observed #{elapsed}ms (no default stall?)"
          assert elapsed < 2_500, "#{label}: default must be clamped by max_stall_ms (500); observed #{elapsed}ms"
        end
      end)
    end
  end

  # ── config boundaries: default_stall_ms / kill switch ─────────────────────

  describe "default_stall_ms config" do
    test "ships the Matrix-spec default of 20_000 ms (key present in config.exs)" do
      assert Nebu.Media.default_stall_ms() == 20_000
      assert Keyword.fetch!(Application.get_env(:nebu, Nebu.Media), :default_stall_ms) == 20_000
    end

    for bad <- [0, -1] do
      test "default_stall_ms: #{bad} is a kill switch for the ABSENT case (immediate 451, no subscribe)",
           %{token: token, state_agent: agent} do
        ensure_pubsub_started!()

        with_media_config([default_stall_ms: unquote(bad), max_stall_ms: 5_000], fn ->
          for {label, build} <- endpoints() do
            media_id = new_id("killswitch")
            put_state(agent, media_id, :scanning)
            {conn, elapsed} = timed_get(build.(media_id, nil), token)

            assert_not_yet_uploaded(conn)
            assert elapsed < 250, "#{label}: kill-switched default must not stall; observed #{elapsed}ms"
            assert Registry.lookup(Nebu.PubSub, topic(media_id)) == []
          end
        end)
      end
    end

    test "kill-switched default does not disable an explicit positive timeout_ms",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()

      with_media_config([default_stall_ms: 0, max_stall_ms: 5_000], fn ->
        media_id = new_id("killswitch-explicit")
        put_state(agent, media_id, :scanning)
        broadcast_after(100, media_id, :released, agent)
        {conn, _} = timed_get(download_path(media_id) <> "?timeout_ms=2000", token)
        assert conn.status == 200
      end)
    end

    for bad_cap <- [-1, 0] do
      test "non-positive max_stall_ms (#{bad_cap}) with an ABSENT param degrades to the immediate 451 (no crash)",
           %{token: token, state_agent: agent} do
        ensure_pubsub_started!()

        with_media_config([default_stall_ms: 5_000, max_stall_ms: unquote(bad_cap)], fn ->
          for {label, build} <- endpoints() do
            media_id = new_id("badcap-absent")
            put_state(agent, media_id, :scanning)
            {conn, elapsed} = timed_get(build.(media_id, nil), token)

            assert_not_yet_uploaded(conn)
            assert elapsed < 250, "#{label}: observed #{elapsed}ms"
            assert Registry.lookup(Nebu.PubSub, topic(media_id)) == []
          end
        end)
      end
    end
  end

  # ── AC2 — thumbnail edges unchanged ─────────────────────────────────────

  describe "AC2: thumbnail edge behaviour is unchanged by the stall" do
    test "released but non-thumbnailable content type still 400 M_UNKNOWN, no wait", %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("thumb-400")
      put_state(agent, media_id, :released)

      # swap in a non-image row
      inner = Application.get_env(:nebu_http, :media_lookup_fun)

      Application.put_env(:nebu_http, :media_lookup_fun, fn server, id ->
        case inner.(server, id) do
          {:ok, row} -> {:ok, %{row | content_type: "application/pdf"}}
          other -> other
        end
      end)

      with_media_config(@fast_cfg, fn ->
        {conn, elapsed} = timed_get(v1_thumb(media_id) <> "?" <> @thumb_q, token)
        assert conn.status == 400
        assert S.json(conn)["errcode"] == "M_UNKNOWN"
        assert elapsed < 250
      end)
    end

    test "non-thumbnailable type released mid-window: stalls first, then answers 400 (not 451)",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("thumb-400-stalled")
      put_state(agent, media_id, :scanning)
      inner = Application.get_env(:nebu_http, :media_lookup_fun)

      Application.put_env(:nebu_http, :media_lookup_fun, fn server, id ->
        case inner.(server, id) do
          {:ok, row} -> {:ok, %{row | content_type: "application/pdf"}}
          other -> other
        end
      end)

      with_media_config(@fast_cfg, fn ->
        broadcast_after(100, media_id, :released, agent)
        {conn, _} = timed_get(v3_thumb(media_id) <> "?" <> @thumb_q, token)
        assert conn.status == 400, "after release the normal thumbnail edge applies; got #{conn.status}"
      end)
    end
  end

  # ── AC5 — concurrency ceiling applies to DEFAULT stalls ────────────────────

  describe "AC5: max_concurrent_stalls applies to default stalls" do
    test "second default-stalled request (download or thumbnail) degrades immediately once the slot is taken",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()

      with_media_config([default_stall_ms: 900, max_stall_ms: 1_000, max_concurrent_stalls: 1], fn ->
        first_id = new_id("ceiling-default-1")
        second_id = new_id("ceiling-default-2")
        put_state(agent, first_id, :scanning)
        put_state(agent, second_id, :scanning)

        first = Task.async(fn -> timed_get(download_path(first_id), token) end)
        # the first request must really hold the single slot before the second arrives
        await_subscriber(first_id)

        {second_conn, second_elapsed} = timed_get(v1_thumb(second_id) <> "?" <> @thumb_q, token)

        assert_not_yet_uploaded(second_conn)
        assert second_elapsed < 400, "no slot left: must degrade immediately, never block/err; observed #{second_elapsed}ms"

        {first_conn, first_elapsed} = Task.await(first, 3_000)
        assert_not_yet_uploaded(first_conn)

        assert first_elapsed >= 700,
               "the slot holder must genuinely default-stall (~900ms); observed #{first_elapsed}ms"
      end)
    end
  end

  # ── AC6 — access control first: never enters the stall ─────────────────────

  describe "AC6: unauthenticated / invalid / non-member requests never stall" do
    test "unauthenticated v1 + v3 download/thumbnail -> 401 M_MISSING_TOKEN immediately, no subscription",
         %{state_agent: agent} do
      ensure_pubsub_started!()

      with_media_config(@fast_cfg, fn ->
        for {label, build} <- endpoints() do
          media_id = new_id("unauth")
          put_state(agent, media_id, :scanning)

          started = System.monotonic_time(:millisecond)
          conn = get(build.(media_id, nil), [])
          elapsed = System.monotonic_time(:millisecond) - started

          assert conn.status == 401, "#{label}: got #{conn.status}"
          assert S.json(conn)["errcode"] == "M_MISSING_TOKEN"
          assert elapsed < 250, "#{label}: must be rejected before any stall; observed #{elapsed}ms"
          assert Registry.lookup(Nebu.PubSub, topic(media_id)) == []
        end
      end)
    end

    test "invalid token -> 401 M_UNKNOWN_TOKEN immediately, no subscription", %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      [h, p, sig] = String.split(token, ".", parts: 3)
      bad = Enum.join([h, p, String.reverse(sig)], ".")

      with_media_config(@fast_cfg, fn ->
        for {label, build} <- endpoints() do
          media_id = new_id("badtoken")
          put_state(agent, media_id, :scanning)
          {conn, elapsed} = timed_get(build.(media_id, nil), bad)

          assert conn.status == 401, "#{label}: got #{conn.status}"
          assert S.json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
          assert elapsed < 250
          assert Registry.lookup(Nebu.PubSub, topic(media_id)) == []
        end
      end)
    end

    # A non-member must be answered exactly like `timeout_ms=0` (immediately,
    # never served) both for an absent and an explicit positive timeout_ms. The
    # release is scheduled at ~300ms inside a 600ms window, so a (wrongly)
    # stalled non-member would return at >= ~300ms and trip the elapsed bound,
    # while the immediate answer (<< 300ms) can never see :released.
    for {variant, query} <- [{"absent timeout_ms", nil}, {"explicit timeout_ms=600", "timeout_ms=600"}] do
      test "authenticated NON-member never enters the stall (#{variant}: same immediate answer as timeout_ms=0, never served)",
           %{token: token, state_agent: agent} do
        ensure_pubsub_started!()
        Application.put_env(:nebu_http, :media_member_fun, fn _room, _user -> false end)

        with_media_config([default_stall_ms: 600, max_stall_ms: 1_000], fn ->
          for {label, build} <- endpoints() do
            media_id = new_id("nonmember")
            put_state(agent, media_id, :scanning)

            # baseline: what a non-member gets with an explicit no-stall request
            {baseline, _} = timed_get(build.(media_id, "timeout_ms=0"), token)

            broadcast_after(300, media_id, :released, agent)
            {conn, elapsed} = timed_get(build.(media_id, unquote(query)), token)

            assert elapsed < 250, "#{label}: non-member must be answered immediately; observed #{elapsed}ms"
            assert Registry.lookup(Nebu.PubSub, topic(media_id)) == [], "#{label}: non-member must not subscribe"
            assert conn.status == baseline.status
            assert S.json(conn)["errcode"] == S.json(baseline)["errcode"]
            assert conn.status != 200
            refute conn.resp_body == @plaintext
          end
        end)
      end
    end
  end

  # ── Robustness: a failing / slow recheck degrades to the 1c mapping, never a 500 ──
  #
  # DownloadStall.run_wait/3 runs the DB-reading recheck inside the wait task.
  # A raise, exit or hang there must degrade to :timeout, after which the
  # caller applies the immediate ADR-026 mapping (451 for a still-:scanning
  # file) — not take the request down.

  describe "stall robustness: failing/slow recheck degrades to 1c (no crash)" do
    # Lookup call order per stalled request: 1 initial read, 2 recheck (inside
    # the wait task), 3 final authorised re-read. `on_recheck` replaces call 2.
    defp with_recheck(on_recheck) do
      inner = Application.get_env(:nebu_http, :media_lookup_fun)
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Application.put_env(:nebu_http, :media_lookup_fun, fn server, id ->
        case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
          2 ->
            on_recheck.()
            inner.(server, id)

          _ ->
            inner.(server, id)
        end
      end)

      on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)
    end

    test "raising recheck (DB error) -> 451, not a crash", %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("recheck-raise")
      put_state(agent, media_id, :scanning)
      with_recheck(fn -> raise "recheck boom" end)

      {conn, _elapsed} = timed_get(download_path(media_id, "timeout_ms=300"), token)
      assert_not_yet_uploaded(conn)
      await_unsubscribed(media_id)
    end

    test "exiting recheck -> 451, not a crash", %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("recheck-exit")
      put_state(agent, media_id, :scanning)
      with_recheck(fn -> exit(:recheck_gone) end)

      {conn, _elapsed} = timed_get(v1_thumb(media_id) <> "?" <> @thumb_q <> "&timeout_ms=300", token)
      assert_not_yet_uploaded(conn)
    end

    test "recheck slower than window + buffer, file still quarantined -> 451, not a crash",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("recheck-slow")
      put_state(agent, media_id, :quarantined)
      with_recheck(fn -> Process.sleep(1_500) end)

      {conn, elapsed} = timed_get(download_path(media_id, "timeout_ms=100"), token)
      assert_not_yet_uploaded(conn)
      # gave up at ~window + buffer, did not wait out the hung recheck
      assert elapsed < 1_200, "must not wait out a hung recheck; observed #{elapsed}ms"
      await_unsubscribed(media_id)
    end

    test "a failed wait still releases its slot (ceiling of 1 stays usable)",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("recheck-slot")
      put_state(agent, media_id, :scanning)
      with_recheck(fn -> raise "recheck boom" end)

      with_media_config([max_concurrent_stalls: 1], fn ->
        {first, _} = timed_get(download_path(media_id, "timeout_ms=200"), token)
        assert_not_yet_uploaded(first)

        # second request must be able to take the (released) slot and really stall
        {second, elapsed} = timed_get(download_path(media_id, "timeout_ms=200"), token)
        assert_not_yet_uploaded(second)
        assert elapsed >= 150, "slot leaked: second request did not stall; observed #{elapsed}ms"
      end)
    end
  end

  # ── Review cycle 2 (security F-1 / F-4) ────────────────────────────────────

  describe "slot is freed when the request process is killed mid-stall (F-1)" do
    test "killing the HTTP request process frees the slot; a follow-up request can stall again",
         %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("kill-mid-stall")
      put_state(agent, media_id, :scanning)

      with_media_config([max_concurrent_stalls: 1, default_stall_ms: 5_000, max_stall_ms: 5_000], fn ->
        before = Nebu.Media.DownloadStall.active_stalls()

        # Bandit HTTP/2 runs each request in a process that is killed from
        # outside on client disconnect: simulate with an exit signal.
        victim = spawn(fn -> timed_get(download_path(media_id), token) end)
        await_subscriber(media_id)
        assert Nebu.Media.DownloadStall.active_stalls() == before + 1

        Process.exit(victim, :kill)
        await_active_stalls(before)

        # The single slot is free again: the next request really stalls.
        {conn, elapsed} = timed_get(download_path(media_id, "timeout_ms=300"), token)
        assert_not_yet_uploaded(conn)
        assert elapsed >= 250, "slot leaked after kill: next request did not stall; observed #{elapsed}ms"
        assert Nebu.Media.DownloadStall.active_stalls() == before
      end)
    end
  end

  describe "non-integer max_stall_ms fails closed (F-4)" do
    test "string max_stall_ms => no stall, no crash", %{token: token, state_agent: agent} do
      ensure_pubsub_started!()
      media_id = new_id("string-cap")
      put_state(agent, media_id, :scanning)

      with_media_config([max_stall_ms: "5000", default_stall_ms: 5_000], fn ->
        for q <- ["timeout_ms=5000", "timeout_ms=60000", nil] do
          path = if q, do: download_path(media_id, q), else: download_path(media_id)
          {conn, elapsed} = timed_get(path, token)
          assert_not_yet_uploaded(conn)
          assert elapsed < 250, "non-integer cap must mean no stall; observed #{elapsed}ms"
        end
      end)
    end
  end

  defp await_active_stalls(expected, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> Nebu.Media.DownloadStall.active_stalls() end)
    |> Enum.reduce_while(nil, fn n, _ ->
      cond do
        n == expected -> {:halt, :ok}
        System.monotonic_time(:millisecond) > deadline -> flunk("active stalls #{n}, expected #{expected}")
        true -> Process.sleep(5) && {:cont, nil}
      end
    end)
  end
end
