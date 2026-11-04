defmodule Nebu.OAuth.ConsentGrantTestSupport do
  @moduledoc """
  Shared helpers of the tests of story `oauth-session-and-consent/persistent-consent-grants` (REQ-2026-003): remembered OAuth consent grants.

  The FILE NAME ends with `oauth_test_support.exs` on purpose: `mix.exs` already ignores that suffix (`test_ignore_filters`), so no mix.exs change
  is needed (an unlisted support file in the test tree makes `mix test --warnings-as-errors` exit 1). Loaded once from `test/test_helper.exs`.
  Every function is `def` (no unused private helper per suite).

  ## The contract this story pins (names are the ATDD agent's; the dev may deviate only with a story Decisions note)

    * Table `oauth_consent_grants` (migration 000057), see `000057_oauth_consent_grants_test.exs`.
    * `Nebu.OAuth.ConsentGrantStore` (all calls here go through `apply/3`, so the red state compiles under `--warnings-as-errors`):
        * `normalize_scope/1` (pure): the scope string as sorted, unique, space-joined tokens WITHOUT the per-login `<prefix>device:<id>` token.
        * `covers?/2` (pure): `covers?(granted, requested)`: every normalised token of `requested` is in `granted`.
        * `upsert/1` (`%{user_id:, client_id:, scope:, redirect_uri:}`): `:ok | {:error, term()}`; the binding is read from the client row in the SAME statement.
        * `skip_consent?/4` (`user_id, client_id, scope, redirect_uri`): `{:ok, boolean()} | {:error, :storage}`; ONE statement that also checks the client.
        * `list_for_user/1`: `{:ok, [%{client_id:, client_name:, scope:, redirect_uri:, granted_at:}]} | {:error, :storage}`.
        * `withdraw/2` (`user_id, client_id`): `{:ok, :withdrawn | :not_found} | {:error, :storage}`.
    * `Nebu.OAuth.AuthorizeRequest.validate/2` result gains `force_consent: boolean` (`consent` among the space separated `prompt` values).
  """
  import ExUnit.Assertions

  alias Nebu.OAuth.TestSupport, as: T

  @store Nebu.OAuth.ConsentGrantStore
  @https "https://app.example.com/cb"
  @website "https://app.example.com"
  @consent_path "/oauth2/consent"

  def store, do: @store
  def https, do: @https
  def website, do: @website

  # ── the store, through apply/3 ──────────────────────────────────────────────

  def call(fun, args) do
    assert Code.ensure_loaded?(@store), "#{inspect(@store)} does not exist yet (lib/nebu/oauth/consent_grant_store.ex)"
    assert function_exported?(@store, fun, length(args)), "#{inspect(@store)}.#{fun}/#{length(args)} is not defined"
    apply(@store, fun, args)
  end

  def upsert(attrs), do: call(:upsert, [attrs])
  def upsert!(attrs), do: assert(:ok == upsert(attrs), "upsert/1 must answer :ok for #{inspect(Map.drop(attrs, [:scope]))}")

  def skip?(user_id, client_id, scope, redirect_uri) do
    assert {:ok, answer} = call(:skip_consent?, [user_id, client_id, scope, redirect_uri])
    answer
  end

  # ── scopes ──────────────────────────────────────────────────────────────────

  @doc "A request scope with a login specific device: `scope(device, openid: false, prefix: :stable | :unstable)`."
  def scope(device \\ "GRDEVICE01", opts \\ []) do
    prefix = if Keyword.get(opts, :prefix, :unstable) == :stable, do: T.stable_prefix(), else: T.unstable_prefix()
    openid = if Keyword.get(opts, :openid, true), do: "openid ", else: ""
    extra = case Keyword.get(opts, :extra) do nil -> ""; e -> " " <> e end
    openid <> T.matrix_scope(prefix, device) <> extra
  end

  @doc "The remembered form of `scope/2` (no device token), normalised."
  def remembered_scope(opts \\ []) do
    prefix = if Keyword.get(opts, :prefix, :unstable) == :stable, do: T.stable_prefix(), else: T.unstable_prefix()
    tokens = if(Keyword.get(opts, :openid, true), do: ["openid"], else: []) ++ [prefix <> "api:*"]
    tokens |> Enum.sort() |> Enum.join(" ")
  end

  # ── environment ─────────────────────────────────────────────────────────────

  @doc """
  The OAuth switch + IdP stub + a fresh approved client (https redirect `#{@https}` and a second one, `#{"https://other.example.com/cb"}`).
  Registers every restore through `on_exit`. Returns `%{priv, cid}`.
  """
  def setup_env!(opts \\ []) do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    ExUnit.Callbacks.on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo], do: Application.delete_env(:nebu_http, k)
    end)

    redirects = Keyword.get(opts, :redirects, [@https, "https://other.example.com/cb", "https://app.example.com/cb2"])
    cid = T.oauth_client!(redirects, client_name: Keyword.get(opts, :client_name, "Grant Test App"), client_uri: @website)
    %{priv: priv, cid: cid}
  end

  # ── driving the real flow ───────────────────────────────────────────────────

  @doc """
  authorize -> IdP stub -> callback for `sub`. `opts`: `:redirect` (#{@https}), `:device`, `:openid` (true), `:prefix`, `:scope` (raw string, replaces the
  built one), `:prompt`, `:nonce`, `:state`, `:claims` (extra id token claims; `auth_time` default now), `:authorize` (more overrides), `:ip`.
  Returns `%{flow, cb, sub, user_id, verifier, redirect, cid, outcome}` where `outcome` is `:consent` (303 to the consent page) or `{:code, params}`
  (a redirect to the client carrying a code) or `{:other, conn}`.
  """
  def login(cid, priv, sub, opts \\ []) do
    redirect = Keyword.get(opts, :redirect, @https)
    {verifier, challenge} = T.pkce_pair()
    device = Keyword.get(opts, :device, "GRDEV" <> String.upcase(T.rand(4)))

    overrides =
      %{"code_challenge" => challenge, "scope" => Keyword.get_lazy(opts, :scope, fn -> scope(device, Keyword.take(opts, [:openid, :prefix, :extra])) end)}
      |> put_if("prompt", opts[:prompt])
      |> put_if("nonce", opts[:nonce])
      |> put_if("state", opts[:state])
      |> Map.merge(Map.new(Keyword.get(opts, :authorize, %{}), fn {k, v} -> {to_string(k), v} end))

    flow = T.start_flow(cid, redirect, overrides)
    claims = Map.merge(%{"sub" => sub, "auth_time" => System.system_time(:second)}, Keyword.get(opts, :claims, %{}))
    cb = T.finish_flow(flow, priv, [claims: claims, idp_rt: Keyword.get(opts, :idp_rt, "idp-rt-" <> T.rand(8))] ++ Keyword.take(opts, [:ip]))

    %{flow: flow, cb: cb, sub: sub, user_id: T.user_id_for(%{"sub" => sub}), verifier: verifier, redirect: redirect, cid: cid, device: device, outcome: outcome(cb)}
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc "`:consent | {:code, params} | {:other, conn}` of a callback response."
  def outcome(cb) do
    loc = T.location(cb)

    cond do
      cb.status in [302, 303] and loc == @consent_path -> :consent
      cb.status in [302, 303] and is_binary(loc) and loc != @consent_path ->
        {_base, _mode, params, _names} = T.client_redirect(loc)
        if Map.has_key?(params, "code"), do: {:code, params}, else: {:other, cb}

      true -> {:other, cb}
    end
  end

  @doc "Asserts the callback asked for consent (303 + consent cookie + consent row) and returns the login."
  def assert_consent!(login) do
    assert login.outcome == :consent,
           "expected the consent screen (303 /oauth2/consent), got #{describe(login.cb)}"

    T.assert_consent_redirect(login.cb)
    login
  end

  @doc "Asserts the callback issued the code directly: a redirect to the client, no consent cookie, no consent row. Returns the redirect params."
  def assert_skipped!(login) do
    assert {:code, params} = login.outcome, "expected the code WITHOUT the consent screen, got #{describe(login.cb)}"
    assert login.cb.status in [302, 303], "a redirect (302 or 303) to the client, got #{login.cb.status}"
    assert T.consent_set_cookies(login.cb) == [], "no consent cookie on the skip path"
    assert T.count_for("oauth_consent_requests", login.cid) == 0, "no consent request row on the skip path"
    assert params["state"] == T.param(login.flow.pairs, "state"), "the client's state is echoed"
    assert is_binary(params["iss"]) and params["iss"] != "", "RFC 9207 iss is present"
    assert T.header(login.cb, "cache-control") =~ "no-store"
    assert T.header(login.cb, "access-control-allow-origin") == nil
    params
  end

  def describe(conn), do: "HTTP #{conn.status} Location=#{inspect(T.location(conn))} body=#{String.slice(conn.resp_body || "", 0, 160)}"

  @doc "Clicks Allow for a login that asked for consent; returns `{conn, code}` (the code of the client redirect)."
  def allow!(login) do
    assert_consent!(login)
    conn = T.consent!(login.cb, :allow)
    assert conn.status == 303, "Allow must 303 to the client, got #{describe(conn)}"
    {_base, _mode, params, _} = T.client_redirect(conn)
    {conn, params["code"] || flunk("no code after Allow: #{inspect(params)}")}
  end

  @doc "A first login + Allow: the user has allowed the client. Returns the login (with `:code`)."
  def allow_new!(cid, priv, sub, opts \\ []) do
    login = login(cid, priv, sub, opts)
    {_conn, code} = allow!(login)
    Map.put(login, :code, code)
  end

  @doc "Redeems the code of a login at the token endpoint (the code must be bound to the login's own PKCE verifier, redirect URI and client)."
  def redeem(login, code) do
    T.redeem(%{client_id: login.cid, code: code, redirect_uri: login.redirect, verifier: login.verifier}, %{}, [])
  end

  # ── rows ────────────────────────────────────────────────────────────────────

  @cols ~w(user_id client_id scope redirect_uri client_approved_at created_at granted_at)

  def cols, do: @cols

  def grant_rows(user_id, client_id \\ nil) do
    {where, params} =
      if client_id, do: {"user_id = $1 AND client_id = $2", [user_id, client_id]}, else: {"user_id = $1", [user_id]}

    %{rows: rows, columns: columns} = T.sql!("SELECT * FROM oauth_consent_grants WHERE #{where} ORDER BY client_id", params)
    Enum.map(rows, fn r -> columns |> Enum.zip(r) |> Map.new() end)
  end

  def grant_row(user_id, client_id), do: List.first(grant_rows(user_id, client_id))

  def grant_count(user_id, client_id \\ nil), do: length(grant_rows(user_id, client_id))

  def grant_count_for_client(client_id) do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM oauth_consent_grants WHERE client_id = $1", [client_id])
    n
  end

  @doc "Sets the STORED, verified `oauth_clients.client_host` of a fixture client (registration verifies it; the fixtures leave it NULL). Privileged."
  def set_client_host!(client_id, host) do
    # the guard trigger of 000040 freezes the identity columns of a registration, `client_host` included: like the owner override, it is
    # disabled for one privileged transaction (the same helper pattern as `reapprove!/1`)
    T.with_privileged_conn(fn conn ->
      {:ok, _} =
        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "ALTER TABLE oauth_clients DISABLE TRIGGER oauth_clients_guard_status", [])
          Postgrex.query!(tx, "UPDATE oauth_clients SET client_host = $2 WHERE client_id = $1", [client_id, host])
          Postgrex.query!(tx, "ALTER TABLE oauth_clients ENABLE TRIGGER oauth_clients_guard_status", [])
        end)
    end)

    :ok
  end

  @doc "Inserts a grant row DIRECTLY (runtime role) with the binding of the client row now: for edge cases (`:binding_sql` replaces the binding)."
  def insert_grant!(user_id, client_id, attrs \\ %{}) do
    attrs = Map.new(attrs)
    binding = Map.get(attrs, :binding_sql, "(SELECT approved_at FROM oauth_clients WHERE client_id = $2)")

    T.sql!(
      "INSERT INTO oauth_consent_grants (user_id, client_id, scope, redirect_uri, client_approved_at) VALUES ($1, $2, $3, $4, #{binding})",
      [user_id, client_id, Map.get(attrs, :scope, remembered_scope()), Map.get(attrs, :redirect_uri, @https)]
    )

    :ok
  end

  @doc "Deletes the grants of the given users (privileged): the users of a test are random and never reused, this only keeps the table small."
  def cleanup_grants(user_ids) when is_list(user_ids) do
    T.privileged_sql!("DELETE FROM oauth_consent_grants WHERE user_id = ANY($1)", [user_ids])
    :ok
  end

  @hidden "oauth_consent_grants_atdd_hidden"

  @doc """
  Runs `fun` while `oauth_consent_grants` cannot be reached (the table is renamed away by the privileged role: every statement on it fails with
  `undefined_table`, like an outage of that table). The name is restored in an `after` AND by `on_exit`. Returns the result of `fun`.
  """
  def with_table_unreadable(fun) do
    T.privileged_sql!("ALTER TABLE oauth_consent_grants RENAME TO #{@hidden}")
    ExUnit.Callbacks.on_exit(&restore_table/0)

    try do
      fun.()
    after
      restore_table()
    end
  end

  def restore_table do
    case T.privileged_sql!("SELECT to_regclass('#{@hidden}')::text").rows do
      [[nil]] -> :ok
      _ -> T.privileged_sql!("ALTER TABLE #{@hidden} RENAME TO oauth_consent_grants") && :ok
    end
  end

  @doc """
  Every INSERT into `oauth_codes` for `user_id` fails (privileged BEFORE INSERT trigger with a fixed text): the code cannot be stored, so the Allow
  ends in the `server_error` redirect. Removed by `on_exit`; returns a 0-arity fun that removes it early.
  """
  def block_code_inserts!(user_id) do
    true = Regex.match?(~r/\A@[A-Za-z0-9._=\-\/]+:[A-Za-z0-9.\-]+\z/, user_id)
    name = "atdd_grant_fault_" <> T.rand(5)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.user_id = '#{user_id}' THEN RAISE EXCEPTION 'atdd: forced failure'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON oauth_codes FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON oauth_codes")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  # ── revocation helpers ──────────────────────────────────────────────────────

  @doc """
  The client is APPROVED again after a revocation. The guard trigger forbids it (a revocation is final for that registration), so, like the
  owner override the revocation story names, the trigger is disabled for one privileged transaction. `approved_at` is the NEW decision time.
  """
  def reapprove!(client_id) do
    T.with_privileged_conn(fn conn ->
      {:ok, _} =
        Postgrex.transaction(conn, fn tx ->
          Postgrex.query!(tx, "ALTER TABLE oauth_clients DISABLE TRIGGER oauth_clients_guard_status", [])

          Postgrex.query!(
            tx,
            "UPDATE oauth_clients SET status = 'approved', revoked_by = NULL, revoked_at = NULL, revoked_reason = NULL, " <>
              "approved_by = '@admin2:test.local', approved_at = clock_timestamp() + interval '2 seconds' WHERE client_id = $1",
            [client_id]
          )

          Postgrex.query!(tx, "ALTER TABLE oauth_clients ENABLE TRIGGER oauth_clients_guard_status", [])
        end)
    end)

    :ok
  end

  @doc "Revokes through the REAL path (`Nebu.OAuth.ClientStore.revoke/3`, the CR4 transaction)."
  def revoke!(client_id, opts \\ []) do
    assert {:ok, %{devices: _}} = Nebu.OAuth.ClientStore.revoke(client_id, "@admin:test.local", opts)
    :ok
  end

  # ── the account page ────────────────────────────────────────────────────────

  @doc "A live account session (inserted directly) for the user: `%{cookie, csrf}`; `:auth_time` (unix s) default now."
  def account!(user_id, opts \\ []), do: T.account_session!(user_id, opts)

  @doc """
  POST `/account/apps/withdraw` the way the account page's form submits it: the CSRF token of the session, `Origin` = the issuer origin and
  `Sec-Fetch-Site: same-origin` (the lenient level of the device sign-out). Options: `:csrf` (override), `:headers` (REPLACES the default
  headers), `:ip`, `:https`.
  """
  def withdraw_post(account, client_id, opts \\ []) do
    params = [{"csrf_token", Keyword.get(opts, :csrf, account.csrf)}] ++ if(client_id, do: [{"client_id", client_id}], else: [])
    headers = Keyword.get(opts, :headers, [{"origin", T.issuer()}, {"sec-fetch-site", "same-origin"}])
    T.account_post("/account/apps/withdraw", params, [cookie: account.cookie, headers: headers] ++ Keyword.take(opts, [:ip, :https]))
  end

  @doc "GET `/account/apps` with the session cookie."
  def apps_get(account, opts \\ []), do: T.account_get("/account/apps", [cookie: account.cookie] ++ opts)

  # ── erasure ─────────────────────────────────────────────────────────────────

  @doc "Seeds a grant for `user_id` on `client_id` through the store (what the seeded world of the erasure suites does)."
  def seed_grant!(user_id, client_id, opts \\ []) do
    upsert!(%{user_id: user_id, client_id: client_id, scope: Keyword.get(opts, :scope, scope()), redirect_uri: Keyword.get(opts, :redirect_uri, @https)})
  end
end
