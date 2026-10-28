defmodule Nebu.Matrix.SsoStoreConfirmTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), D7 / AC10.3 - AC10.5: the
  `:confirm` tag of `Nebu.Matrix.SsoStore` (pending confirmation entries) and the `format_status/1` hardening.

  Pinned (D7):

    * `put_confirm(key, entry, ttl_seconds) :: :ok | {:error, :store_full}`, `peek_confirm(key) :: {:ok, entry} | :error`
      (non-destructive), `pop_confirm(key) :: {:ok, entry} | :error` (single use, tombstone broadcast).
    * the ETS key is `{:confirm, key}`; own cap of 10 000 `:confirm` entries per node (expired entries are evicted
      first); the `:state` / `:token` caps are independent of it (and vice versa).
    * replication is the existing `pg` protocol: `{:replicate_put, {:confirm, key}, value}` /
      `{:replicate_delete, {:confirm, key}}` to every OTHER member of `nebu_matrix_sso_store`.
    * `SsoStore.format_status/1` (OTP 25+) keeps `:put_token` / `:put_confirm` / `:replicate_put` payloads and
      table contents out of crash reports and `:sys.get_status/1`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.SsoStore
  alias Nebu.OAuth.TestSupport, as: T

  @group "nebu_matrix_sso_store"

  setup do
    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    T.reset_rate_limits()
    T.drop_confirm_entries!()
    T.drop_token_entries!()

    on_exit(fn ->
      T.restore_rate_limits()
      if Process.whereis(SsoStore), do: (T.drop_confirm_entries!(); T.drop_token_entries!())
    end)

    :ok
  end

  defp put(key, entry \\ nil, ttl \\ 300), do: apply(SsoStore, :put_confirm, [key, entry || T.confirm_entry_fixture(), ttl])
  defp peek(key), do: apply(SsoStore, :peek_confirm, [key])
  defp pop(key), do: apply(SsoStore, :pop_confirm, [key])

  defp key, do: "confirm-key-" <> T.rand(8)
  defp format_status(map), do: apply(SsoStore, :format_status, [map])

  describe "story admin-config-audit-atomic D6 (follow-up di, X2-5) — peek_confirm reads the ETS table directly" do
    test "a live entry is read while the node-local store process does not answer at all (the page lookup is not queued behind the store)" do
      k = key()
      entry = T.confirm_entry_fixture(%{host: "direct.example", origin: "https://direct.example", path: "/x", port: 8443})
      assert put(k, entry) == :ok

      on_exit(fn -> if pid = Process.whereis(SsoStore), do: (try do :sys.resume(pid) catch _, _ -> :ok end) end)
      :ok = :sys.suspend(SsoStore)

      try do
        # the pre-change implementation would run into the 5 s call timeout and answer :error
        assert {:ok, read} = peek(k)
        assert read.host == "direct.example"
      after
        :ok = :sys.resume(SsoStore)
      end
    end

    test "an expired entry and an unknown key are :error (the reader does not delete from the protected table)" do
      k = key()
      assert put(k, nil, -5) == :ok
      assert peek(k) == :error
      assert [_] = :ets.lookup(Module.concat(SsoStore, Table), {:confirm, k}), "the reader did not delete the expired entry from the protected table"
      assert peek(key()) == :error
    end

    test "the table is named, protected and read-concurrent: a reader process can look up, only the owner writes" do
      table = Module.concat(SsoStore, Table)
      assert :ets.info(table, :named_table) == true
      assert :ets.info(table, :protection) == :protected
      assert :ets.info(table, :read_concurrency) == true
      assert_raise ArgumentError, fn -> :ets.insert(table, {{:confirm, "x"}, {%{}, 0}}) end
    end

    test "static: peek_confirm makes no GenServer call and answers :error when the table does not exist (store not started)" do
      src = File.read!(Path.expand("../../../lib/nebu/matrix/sso_store.ex", __DIR__))
      [_, rest] = String.split(src, "def peek_confirm(key) when is_binary(key)", parts: 2)
      body = rest |> String.split("@doc", parts: 2) |> hd()
      refute body =~ "call(", "no GenServer call"
      assert body =~ ":ets.lookup"
      assert body =~ "rescue" and body =~ "ArgumentError", "a missing table (the store is not started) answers :error, never raises"
    end
  end

  describe "put_confirm / peek_confirm / pop_confirm" do
    test "put stores, peek reads without consuming, pop is single use" do
      k = key()
      entry = T.confirm_entry_fixture(%{host: "peek.example", origin: "https://peek.example", path: "/x", port: 8443})
      assert put(k, entry) == :ok

      assert {:ok, a} = peek(k)
      assert {:ok, b} = peek(k)
      assert a == b, "peek is non-destructive"
      for f <- ~w(id_token oidc_refresh_token redirect_url origin host port path user_id)a, do: assert(Map.get(a, f) == Map.get(entry, f), "field #{f}")

      assert {:ok, ^a} = pop(k)
      assert pop(k) == :error
      assert peek(k) == :error
    end

    test "a nil refresh token and a nil port are kept as nil" do
      k = key()
      put(k, T.confirm_entry_fixture(%{oidc_refresh_token: nil, port: nil}))
      assert {:ok, %{oidc_refresh_token: nil, port: nil}} = peek(k)
    end

    test "an unknown key and a key of another tag are :error" do
      assert peek("never-stored-" <> T.rand()) == :error
      assert pop("never-stored-" <> T.rand()) == :error

      SsoStore.put_login_token("only-a-token", "id", 30)
      SsoStore.put_state("only-a-state", %{verifier: "v", nonce: "n", redirect_url: "http://localhost"}, 600)
      assert peek("only-a-token") == :error
      assert peek("only-a-state") == :error
    end

    test "the three tags are independent namespaces: the same string is a state, a token and a confirm entry" do
      same = "same-string-" <> T.rand(4)
      assert SsoStore.put_state(same, %{verifier: "v", nonce: "n", redirect_url: "http://localhost"}, 600) == :ok
      assert SsoStore.put_login_token(same, "the-id-token", 30) == :ok
      assert put(same, T.confirm_entry_fixture(%{host: "ns.example"})) == :ok

      assert {:ok, %{host: "ns.example"}} = pop(same)
      assert {:ok, "the-id-token", nil} = SsoStore.pop_login_token(same)
      assert {:ok, %{nonce: "n"}} = SsoStore.pop_state(same)
    end

    test "an expired entry (ttl -1) is absent for peek and pop" do
      k = key()
      assert put(k, nil, -1) == :ok
      assert peek(k) == :error
      assert pop(k) == :error
    end

    test "a second put under the same key replaces the entry (the newer pending confirmation wins)" do
      k = key()
      put(k, T.confirm_entry_fixture(%{host: "first.example"}))
      put(k, T.confirm_entry_fixture(%{host: "second.example"}))
      assert {:ok, %{host: "second.example"}} = peek(k)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10.3 — the cap
  # ════════════════════════════════════════════════════════════════════════════

  # Filling a store to its cap is quadratic (every put counts the whole table): 45-60 s and more on the shared CI runner, so the 60 s
  # default timeout does not hold there, and the filler loginTokens need a TTL that outlives the fill.
  describe "AC10.3 — cap of 10 000 :confirm entries per node" do
    @describetag timeout: 300_000

    test "with 10 000 live entries the next put answers {:error, :store_full}; a pop frees a slot" do
      try do
        for i <- 1..10_000, do: :ok = put("cap-#{i}")
        assert put("cap-over") == {:error, :store_full}
        assert peek("cap-over") == :error

        assert {:ok, _} = pop("cap-1")
        assert put("cap-after-pop") == :ok
      after
        T.drop_confirm_entries!()
      end
    end

    test "expired entries are evicted first: 10 000 expired entries never block a new put" do
      try do
        for i <- 1..10_000, do: :ok = put("exp-#{i}", nil, -1)
        assert put("fresh") == :ok
        assert {:ok, _} = peek("fresh")
      after
        T.drop_confirm_entries!()
      end
    end

    test ":confirm entries do not count against the :state and :token caps" do
      try do
        for i <- 1..10_000, do: :ok = put("iso-#{i}")
        assert SsoStore.put_state("state-while-confirm-full", %{verifier: "v", nonce: "n", redirect_url: "http://localhost"}, 600) == :ok
        assert SsoStore.put_login_token("token-while-confirm-full", "id", 30) == :ok
        assert {:ok, _, _} = SsoStore.pop_login_token("token-while-confirm-full")
      after
        T.drop_confirm_entries!()
      end
    end

    test "10 000 live loginTokens do not block put_confirm" do
      try do
        for i <- 1..10_000, do: :ok = SsoStore.put_login_token("tok-#{i}", "id", 300)
        assert SsoStore.put_login_token("tok-over", "id", 30) == {:error, :store_full}, "the token cap itself is unchanged"
        assert put("confirm-while-tokens-full") == :ok
      after
        T.drop_token_entries!()
        T.drop_confirm_entries!()
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10.4 — replication
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10.4 — pg replication" do
    setup do
      :pg.join(@group, self())
      on_exit(fn -> :pg.leave(@group, self()) end)
      :ok
    end

    test "put_confirm broadcasts {:replicate_put, {:confirm, key}, value} to the other group members" do
      k = key()
      entry = T.confirm_entry_fixture()
      assert put(k, entry) == :ok
      assert_receive {:replicate_put, {:confirm, ^k}, {^entry, exp}}, 1_000
      assert is_integer(exp)
    end

    test "pop_confirm broadcasts {:replicate_delete, {:confirm, key}}" do
      k = key()
      put(k)
      assert_receive {:replicate_put, {:confirm, ^k}, _}, 1_000
      assert {:ok, _} = pop(k)
      assert_receive {:replicate_delete, {:confirm, ^k}}, 1_000
    end

    test "an entry replicated from a peer is served by peek / pop on this node" do
      k = key()
      entry = T.confirm_entry_fixture(%{host: "peer.example"})
      exp = System.system_time(:second) + 300
      send(Process.whereis(SsoStore), {:replicate_put, {:confirm, k}, {entry, exp}})
      _ = :sys.get_state(SsoStore)

      assert {:ok, %{host: "peer.example"}} = peek(k)
      assert {:ok, %{host: "peer.example"}} = pop(k)
      assert pop(k) == :error
    end

    test "a replicated delete (tombstone) removes the local entry" do
      k = key()
      put(k)
      send(Process.whereis(SsoStore), {:replicate_delete, {:confirm, k}})
      _ = :sys.get_state(SsoStore)
      assert peek(k) == :error
    end

    test "a peer-replicated entry is served by GET and consumed by POST (Continue) on this node" do
      priv = T.setup_idp!()
      value = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      exp = System.system_time(:second) + 300
      entry = T.confirm_entry_fixture(%{redirect_url: "https://peer.example/cb", origin: "https://peer.example", host: "peer.example", path: "/cb"})

      for k <- T.confirm_keys(value), do: send(Process.whereis(SsoStore), {:replicate_put, {:confirm, k}, {entry, exp}})
      _ = :sys.get_state(SsoStore)
      pair = {T.sso_confirm_cookie_name(), value}

      page = T.sso_confirm_get(pair)
      assert page.status == 200
      assert page.resp_body =~ "https://peer.example"

      post = T.confirm!(pair, :continue)
      assert [_token] = T.login_tokens_of(post)
      assert post.status == 303
      assert String.starts_with?(T.location(post), "https://peer.example/cb?loginToken=")
      _ = priv
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10.5 — format_status/1
  # ════════════════════════════════════════════════════════════════════════════

  @secrets ["ID-TOKEN-SECRET-abc", "IDP-RT-SECRET-def", "https://crash.example/PATH-SECRET-ghi", "LOGIN-TOKEN-SECRET-jkl"]

  defp secret_entry,
    do: %{
      id_token: "ID-TOKEN-SECRET-abc",
      oidc_refresh_token: "IDP-RT-SECRET-def",
      redirect_url: "https://crash.example/PATH-SECRET-ghi",
      origin: "https://crash.example",
      host: "crash.example",
      port: nil,
      path: "/PATH-SECRET-ghi",
      user_id: "@u:test.local"
    }

  defp assert_no_secrets(text) do
    for secret <- @secrets ++ ["PATH-SECRET-ghi"], do: refute(text =~ secret, "#{secret} leaked: #{String.slice(text, 0, 400)}")
  end

  describe "AC10.5 — SsoStore.format_status/1" do
    test "the callback is exported (OTP 25+ format_status/1)" do
      assert {:module, SsoStore} = Code.ensure_loaded(SsoStore)
      assert function_exported?(SsoStore, :format_status, 1)
    end

    test "messages and state of a crash report never print a :put_token / :put_confirm / :replicate_put payload" do
      state = :sys.get_state(SsoStore)
      entry = secret_entry()
      token_payload = %{id_token: "ID-TOKEN-SECRET-abc", oidc_refresh_token: "IDP-RT-SECRET-def"}

      messages = [
        {:put_token, "LOGIN-TOKEN-SECRET-jkl", token_payload, 99},
        {:put_confirm, "k", entry, 99},
        {:replicate_put, {:token, "LOGIN-TOKEN-SECRET-jkl"}, {token_payload, 99}},
        {:replicate_put, {:confirm, "k"}, {entry, 99}},
        {:"$gen_call", {self(), make_ref()}, {:put_confirm, "k", entry, 99}},
        {:"$gen_call", {self(), make_ref()}, {:put_token, "LOGIN-TOKEN-SECRET-jkl", token_payload, 99}},
        {:"$gen_cast", {:put_confirm, "k", entry, 99}}
      ]

      for msg <- messages do
        formatted = format_status(%{state: state, message: msg, reason: {:error, :boom}, pdict: [], log: [{:in, msg}]})
        assert_no_secrets(inspect(formatted, limit: :infinity, printable_limit: :infinity))
      end
    end

    test "the table contents are not part of the formatted state" do
      put("fmt-key", T.confirm_entry_fixture(secret_entry()))
      formatted = format_status(%{state: :sys.get_state(SsoStore), message: nil, reason: :normal, pdict: [], log: []})
      assert_no_secrets(inspect(formatted, limit: :infinity, printable_limit: :infinity))
    end

    test ":sys.get_status/1 never shows stored secrets" do
      put("status-key", T.confirm_entry_fixture(secret_entry()))
      SsoStore.put_login_token("LOGIN-TOKEN-SECRET-jkl", "ID-TOKEN-SECRET-abc", 30, oidc_refresh_token: "IDP-RT-SECRET-def")
      assert_no_secrets(inspect(:sys.get_status(SsoStore), limit: :infinity, printable_limit: :infinity))
    end

    # ONE forced crash. The default `handle_cast/2` of `use GenServer` raises for the unknown cast, which makes the
    # store crash with the secret-bearing message as its last message; no `handle_cast` clause is part of the story
    # (if one existed the store would not crash and only the log assertion below remains).
    test "ONE forced crash prints no secret; the restarted store forgot the old entries and is fully usable (volatile by design)" do
      value = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      T.put_confirm_both!(value, T.confirm_entry_fixture(), 300)
      pre = key()
      assert put(pre) == :ok
      pair = {T.sso_confirm_cookie_name(), value}
      assert T.sso_confirm_get(pair).status == 200, "the pending confirmation renders before the crash"

      pid = Process.whereis(SsoStore)

      log =
        capture_log(fn ->
          GenServer.cast(SsoStore, {:put_confirm, "crash-key", secret_entry(), 99})
          send(self(), {:restart, wait_restart(pid)})
          Logger.flush()
        end)

      assert_received {:restart, restart}
      assert_no_secrets(log)

      if restart == :ok do
        assert log =~ "terminating" or log =~ "Nebu.Matrix.SsoStore", "the crash was logged"
        new = Process.whereis(SsoStore)
        assert new != pid
        assert new in :pg.get_members(@group), "the new store process rejoined the pg group"
        assert peek(pre) == :error, "the old entry is gone (volatile)"

        k = key()
        assert put(k) == :ok
        assert {:ok, _} = peek(k)
        assert {:ok, _} = pop(k)

        T.assert_confirm_error(T.sso_confirm_get(pair), 400, "invalid_state")
      end
    end
  end

  defp wait_restart(old_pid, tries \\ 40) do
    cond do
      tries == 0 -> :gave_up
      (new = Process.whereis(SsoStore)) && new != old_pid -> :ok
      true ->
        Process.sleep(50)
        wait_restart(old_pid, tries - 1)
    end
  end
end
