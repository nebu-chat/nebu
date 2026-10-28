defmodule Nebu.OAuth.OAuthAbuseCapsTest do
  @moduledoc """
  RED-phase acceptance tests (integration, real PostgreSQL) for story `oauth-dcr-abuse-hardening`
  (phase 2, P2 of epic oauth-broker): AC2 (registration: `client_domain`), AC5 (`ClientStore.register/1`
  caps), AC6 (N-1 through `POST /oauth2/register` with distinct client IPs), AC10 (live authorization
  requests per source), AC11 (account login requests per source) and AC12 (logging).

  ## ATDD decisions (the story leaves these seams open; the dev run must honour them)

    * `ClientStore.register/1` attrs: `:client_domain` (from `Registration.validate/1`, else derived
      from the client host), `:source_key` (`Nebu.OAuth.SourceKey.for_conn/1` on the HTTP path) and
      `:ip`. Tests pass `:ip` AND `:source_key` (both derived from the same address); "no source" =
      neither key given. Cap seams: `:pending_host_cap` (existing), `:pending_source_cap` (NEW),
      `:pending_cap` (existing, global).
    * `AuthzStore.insert/1` attrs: `:source_key` and the seam `:source_cap` (default 300); the global
      seam stays `:cap`. `AccountStore.insert_login_request/1`: `:source_key` + `:source_cap`
      (default 300); global `:cap`.
    * Caps are NOT rate-limit buckets: `NEBU_RATE_LIMIT_DISABLED` does not disable them.
      The tests call `T.reset_rate_limits/0` anyway to keep the frozen-clock buckets deterministic.
    * Every test uses its own registrable domain (`t<rand>.com` ...) so that persistent databases
      with foreign pending rows do not interfere.

  All new modules are called through `apply/3` (this file compiles before they exist); tests fail
  because the implementation is missing, not because of compile errors.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @sk Nebu.OAuth.SourceKey
  @https "https://app.example.com/cb"
  @a "198.51.100.9"
  @b "203.0.113.7"

  setup do
    prior_trusted = Nebu.Web.ClientIP.trusted()
    Nebu.Web.ClientIP.configure(nil)
    T.enable_oauth()
    T.reset_rate_limits()
    {:ok, ids} = Agent.start(fn -> [] end)

    on_exit(fn ->
      :persistent_term.put({Nebu.Web.ClientIP, :trusted}, prior_trusted)
      T.cleanup_clients(Agent.get(ids, & &1))
      Agent.stop(ids)
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    {:ok, ids: ids}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp key(ip), do: apply(@sk, :from_ip, [ip])

  # Source text without `#` comments and without the module doc, so a comment or doc sentence can
  # never make a static pin pass or fail.
  defp code_only(src) do
    src
    |> String.replace(~r/@moduledoc """.*?"""/s, "")
    |> String.replace(~r/@doc """.*?"""/s, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end
  defp domain(tld \\ "com"), do: "t#{T.rand(5)}.#{tld}"

  defp body(host) do
    T.web_body(%{"client_uri" => "https://" <> host, "redirect_uris" => ["https://" <> host <> "/callback"]})
  end

  defp remember(ids, conn_or_result) do
    id =
      case conn_or_result do
        %Plug.Conn{status: 201} = conn -> T.json(conn)["client_id"]
        {:ok, %{client_id: id, created?: true}} -> id
        _ -> nil
      end

    if id, do: Agent.update(ids, &[id | &1])
    conn_or_result
  end

  # HTTP registration of NEW metadata with remembered cleanup.
  defp http_reg(ids, host, opts), do: remember(ids, T.register(body(host), opts))

  # ClientStore-level registration of NEW metadata for `host` from source address `ip` (string or nil).
  defp store(ids, host, ip, seams \\ []) do
    {:ok, v} = Nebu.OAuth.Registration.validate(body(host))

    attrs =
      case ip do
        nil -> v
        ip -> Map.merge(v, %{ip: ip, source_key: key(ip), user_agent: "AtddAgent/1.0"})
      end

    ids |> remember(Nebu.OAuth.ClientStore.register(Map.merge(attrs, Map.new(seams))))
  end

  defp store_attrs(host) do
    {:ok, v} = Nebu.OAuth.Registration.validate(body(host))
    v
  end

  defp pending_count do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM oauth_clients WHERE status = 'pending'")
    n
  end

  # pending rows of one client_uri host (attacker + legit registrations alike)
  defp host_pending(host) do
    %{rows: [[n]]} = T.sql!("SELECT count(*) FROM oauth_clients WHERE client_host = $1 AND status = 'pending'", [host])
    n
  end

  # a unique source address per call (M8: no :rand collisions between tests/runs)
  defp unique_source_key, do: Base.encode16(:crypto.hash(:sha256, "atdd-source-" <> T.rand(12)), case: :lower)

  defp assert_created({:ok, %{created?: true}} = r), do: r
  defp assert_created(other), do: flunk("expected a newly created registration, got #{inspect(other)}")

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — registration: the registrable domain is stored
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2.2 — client_domain through POST /oauth2/register" do
    test "a subdomain of a private suffix is accepted (201) and its client_domain is itself", %{ids: ids} do
      host = "n#{T.rand(5)}.github.io"

      conn =
        T.register(T.web_body(%{"client_uri" => "https://" <> host, "redirect_uris" => ["https://" <> host <> "/cb"]}))
        |> then(&remember(ids, &1))

      assert conn.status == 201, "https://name.github.io must be accepted, got #{conn.status}: #{conn.resp_body}"
      assert T.client_row(T.json(conn)["client_id"])["client_domain"] == host
    end

    test "an ordinary subdomain stores the registrable domain of the host", %{ids: ids} do
      d = domain()
      conn = http_reg(ids, "app." <> d, [])
      assert conn.status == 201
      row = T.client_row(T.json(conn)["client_id"])
      assert row["client_domain"] == d
      assert row["client_host"] == "app." <> d
    end

    test "an ICANN multi-label suffix: app.foo.co.uk groups under foo.co.uk", %{ids: ids} do
      host = "app.t#{T.rand(5)}.co.uk"
      conn = http_reg(ids, host, [])
      assert conn.status == 201
      assert T.client_row(T.json(conn)["client_id"])["client_domain"] == String.replace_prefix(host, "app.", "")
    end
  end

  describe "AC2.3 — validate/1 and valid_host?/1" do
    test "validate/1 returns client_domain next to client_host; the metadata hash is unchanged by the new key" do
      d = domain()
      assert {:ok, v} = Nebu.OAuth.Registration.validate(body("app." <> d))
      assert Map.get(Map.new(v), :client_domain) == d
      assert Map.get(Map.new(v), :client_host) == "app." <> d
      refute Map.has_key?(v.metadata, "client_domain"), "client_domain is not part of the metadata / hash"

      # hash vector of the story-1 metadata normalisation (computed at HEAD before this story)
      assert {:ok, %{hash: hash}} =
               Nebu.OAuth.Registration.validate(%{
                 "client_name" => "Vec",
                 "client_uri" => "https://example.com",
                 "redirect_uris" => ["https://example.com/callback"],
                 "application_type" => "web"
               })

      assert hash == "4f01b3959573d3a57934e7ff104c0b77f3c07b36ad9e07d2b5c94c7db3845352"
    end

    test "Registration.valid_host?/1 is the public LDH predicate" do
      for ok <- ["example.com", "a.b.example.com", "EXAMPLE.com"] do
        assert apply(Nebu.OAuth.Registration, :valid_host?, [ok]), "#{ok} must be a valid host"
      end

 # the registration rule (story 1): >= 2 labels, ASCII LDH, no punycode label
      for bad <- ["localhost", "xn--bcher-kva.example", "", "exa mple.com", "-x.example.com", "a..example.com", "ex_ample.com", "example.com/", "a" <> String.duplicate("b", 70) <> ".com"] do
        refute apply(Nebu.OAuth.Registration, :valid_host?, [bad]), "#{inspect(bad)} must not be a valid host"
      end
    end

    test "parse_https/1 uses the public predicate (no copy of ascii_dns_host?/1)" do
      src = File.read!(Path.expand("../../../lib/nebu/oauth/registration.ex", __DIR__))
      assert src =~ "valid_host?("
      refute src =~ ~r/defp\s+ascii_dns_host\?/, "ascii_dns_host?/1 became the public valid_host?/1"
      refute src =~ "No public-suffix check is done", "moduledoc updated (AC14.2)"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — ClientStore.register/1: caps keyed on (registrable domain, source)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.1 — per (domain, source) host cap (AH1)" do
    test "the cap is per source: A is refused at the cap, B registers NEW metadata for the same host", %{ids: ids} do
      d = domain()
      seams = [pending_host_cap: 3]
      for _ <- 1..3, do: assert_created(store(ids, "app." <> d, @a, seams))

      assert {:error, :capacity} = store(ids, "app." <> d, @a, seams)
      assert_created(store(ids, "app." <> d, @b, seams))
    end

    test "grouping is by registrable domain: another host of the same domain counts, another domain does not", %{ids: ids} do
      d = domain()
      seams = [pending_host_cap: 3]
      for _ <- 1..3, do: assert_created(store(ids, "app." <> d, @a, seams))

      assert {:error, :capacity} = store(ids, "other." <> d, @a, seams)
      assert {:error, :capacity} = store(ids, "a.b.c." <> d, @a, seams)
      assert_created(store(ids, "app." <> domain("org"), @a, seams))
    end

    test "rows store the registrable domain and the source key (pending rows only, AH6/AH7)", %{ids: ids} do
      d = domain()
      assert {:ok, %{client_id: id}} = assert_created(store(ids, "app." <> d, @a))
      row = T.client_row(id)
      assert row["client_domain"] == d
      assert row["source_key"] == key(@a)
      assert row["created_from_ip"] == @a, "the clear IP of pending rows is kept for triage (unchanged)"
    end

    test "IPv6 sources are per /64", %{ids: ids} do
      d = domain()
      seams = [pending_host_cap: 2]
      for i <- 1..2, do: assert_created(store(ids, "app." <> d, "2001:db8:1:2::#{i}", seams))

      assert {:error, :capacity} = store(ids, "app." <> d, "2001:db8:1:2:ffff::1", seams)
      assert_created(store(ids, "app." <> d, "2001:db8:1:3::1", seams))
    end
  end

  describe "AC5.2 — per-source total cap (AH2)" do
    test "a source is limited over ALL domains; another source is unaffected", %{ids: ids} do
      seams = [pending_source_cap: 2]
      assert_created(store(ids, "app." <> domain(), @a, seams))
      assert_created(store(ids, "app." <> domain(), @a, seams))
      third = domain()
      assert {:error, :capacity} = store(ids, "app." <> third, @a, seams)
      assert_created(store(ids, "app." <> third, @b, seams))
    end

    test "the default per-source cap is 100 (built-in, no server_config key)", %{ids: ids} do
      src = File.read!(Path.expand("../../../lib/nebu/oauth/client_store.ex", __DIR__))
      assert src =~ ~r/@pending_source_cap\s+100\b/
      # behavioural proof with a cheap bulk fixture: 100 pending rows of one source, the 101st is refused
      key_a = key("198.51.100.77")

      T.sql!(
        "INSERT INTO oauth_clients (client_id, metadata, metadata_hash, application_type, client_domain, source_key) " <>
          "SELECT 'atdd-ac52-' || $1::text || '-' || g, '{}'::jsonb, 'atdd-ac52-h-' || $1::text || '-' || g, 'web', 'seed' || g || '.example', $2 " <>
          "FROM generate_series(1, 100) g",
        [T.rand(), key_a]
      )

      %{rows: seeded_ids} = T.sql!("SELECT client_id FROM oauth_clients WHERE source_key = $1", [key_a])
      Agent.update(ids, &(List.flatten(seeded_ids) ++ &1))
      seeded = length(seeded_ids)
      assert seeded == 100
      assert {:error, :capacity} = store(ids, "app." <> domain(), "198.51.100.77")
      assert_created(store(ids, "app." <> domain(), "198.51.100.78"))
    end
  end

  describe "AC5.3 — the global cap still refuses" do
    test "at the current pending count every source is refused; one slot more admits exactly one", %{ids: ids} do
      n = pending_count()
      assert {:error, :capacity} = store(ids, "app." <> domain(), "198.51.100.1", pending_cap: n)
      assert_created(store(ids, "app." <> domain(), "198.51.100.2", pending_cap: n + 1))
      assert {:error, :capacity} = store(ids, "app." <> domain(), "198.51.100.3", pending_cap: n + 1)
    end
  end

  describe "AC5.4 — dedup hits are never refused" do
    test "a known registration is answered although its source and domain are at their caps", %{ids: ids} do
      d = domain()
      seams = [pending_host_cap: 1, pending_source_cap: 1]
      {:ok, v} = Nebu.OAuth.Registration.validate(body("app." <> d))
      register = fn src -> Nebu.OAuth.ClientStore.register(Map.merge(v, %{ip: src, source_key: key(src)}) |> Map.merge(Map.new(seams))) end

      assert {:ok, %{client_id: id, created?: true}} = remember(ids, register.(@a))

      # NEW metadata from the capped source is refused ...
      assert {:error, :capacity} = store(ids, "app." <> d, @a, seams)

      # ... the SAME metadata again is a dedup hit, from the capped source and from any other
      for src <- [@a, @b] do
        assert {:ok, %{client_id: ^id, created?: false}} = register.(src)
      end
    end
  end

  describe "AC5.5 — approve / reject erase the source key and free the slot" do
    for action <- [:approve, :reject] do
      test "#{action} sets source_key, created_from_ip and user_agent to NULL and frees the (domain, source) slot", %{ids: ids} do
        d = domain()
        seams = [pending_host_cap: 1]
        {:ok, %{client_id: id}} = assert_created(store(ids, "app." <> d, @a, seams))
        assert T.client_row(id)["source_key"] == key(@a)
        assert {:error, :capacity} = store(ids, "app." <> d, @a, seams)

        assert :ok =
                 apply(Nebu.OAuth, :"#{unquote(action)}_registration", [id, "@admin:test.local"])

        row = T.client_row(id)
        assert row["source_key"] == nil
        assert row["created_from_ip"] == nil
        assert row["user_agent"] == nil

        assert_created(store(ids, "app." <> d, @a, seams))
      end
    end
  end

  describe "AC5.6 — without a source" do
    test "source_key is NULL; the per-source cap is skipped; the domain cap counts NULL-source rows of the domain", %{ids: ids} do
      d = domain()
      seams = [pending_host_cap: 2, pending_source_cap: 1]

      assert {:ok, %{client_id: id1}} = assert_created(store(ids, "app." <> d, nil, seams))
      assert T.client_row(id1)["source_key"] == nil
      assert_created(store(ids, "app." <> d, nil, seams))
      assert {:error, :capacity} = store(ids, "app." <> d, nil, seams)

      # per-source cap skipped for NULL sources: two NULL-source rows of other domains fit with a cap of 1
      assert_created(store(ids, "app." <> domain(), nil, seams))
      assert_created(store(ids, "app." <> domain(), nil, seams))

      # a source-bearing registration for the same domain is another group
      assert_created(store(ids, "app." <> d, @a, seams))
    end

    test "metadata alone (no :ip, no :source_key) is accepted by register/1" do
      attrs = store_attrs("app." <> domain())
      refute Map.has_key?(attrs, :source_key)
      assert {:ok, %{client_id: id, created?: true}} = Nebu.OAuth.ClientStore.register(attrs)
      on_exit(fn -> T.cleanup_clients([id]) end)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 — N-1 through POST /oauth2/register with distinct client IPs
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6 — an attacker filling the host cap does not block the real client" do
    @attacker {198, 51, 100, 9}
    @legit {203, 0, 113, 7}

    test "AC6.1 default cap 20: attacker's 21st is 503 + Retry-After; the legit client (other IP) registers NEW metadata", %{ids: ids} do
      host = "element.#{domain("example")}"
      for i <- 1..20, do: assert(http_reg(ids, host, ip: @attacker).status == 201, "attacker registration #{i}")

      conn = http_reg(ids, host, ip: @attacker)
      T.assert_oauth_error(conn, 503, "temporarily_unavailable")
      assert {n, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert n >= 1

      legit = http_reg(ids, host, ip: @legit)
      assert legit.status == 201, "the real client must still register (N-1), got #{legit.status}: #{legit.resp_body}"
      assert T.client_row(T.json(legit)["client_id"])["status"] == "pending"
      assert host_pending(host) == 21, "never evict: the attacker's 20 rows are still pending next to the legit one"
    end

    test "AC6.2 through a trusted proxy: XFF 198.51.100.9 is capped, XFF 203.0.113.7 is not", %{ids: ids} do
      Nebu.Web.ClientIP.configure("10.0.0.0/8")
      host = "element.#{domain("example")}"
      proxy = {10, 0, 0, 5}

      for i <- 1..20, do: assert(http_reg(ids, host, ip: proxy, xff: "198.51.100.9").status == 201, "attacker registration #{i}")
      T.assert_oauth_error(http_reg(ids, host, ip: proxy, xff: "198.51.100.9"), 503, "temporarily_unavailable")

      assert http_reg(ids, host, ip: proxy, xff: "203.0.113.7").status == 201
      assert host_pending(host) == 21, "never evict: the attacker's rows survive the legit registration"
    end

    test "AC6.3 spoofing: an untrusted peer rotating X-Forwarded-For stays ONE source", %{ids: ids} do
      host = "element.#{domain("example")}"

      for i <- 1..20 do
        assert http_reg(ids, host, ip: @attacker, xff: "203.0.113.#{i}").status == 201
      end

      T.assert_oauth_error(http_reg(ids, host, ip: @attacker, xff: "203.0.113.99"), 503, "temporarily_unavailable")
      assert host_pending(host) == 20, "the refused request inserted nothing and nothing was evicted"
    end

    test "AC6.4 IPv6: the cap is per /64 (20 addresses of one /64, then another /64)", %{ids: ids} do
      host = "element.#{domain("example")}"

      for i <- 1..20, do: assert(http_reg(ids, host, ip: {0x2001, 0xDB8, 1, 2, 0, 0, 0, i}).status == 201, "address #{i}")

      T.assert_oauth_error(http_reg(ids, host, ip: {0x2001, 0xDB8, 1, 2, 0, 0, 0, 0x99}), 503, "temporarily_unavailable")
      assert http_reg(ids, host, ip: {0x2001, 0xDB8, 1, 3, 0, 0, 0, 1}).status == 201
    end

    test "AC6.5 response shapes are unchanged (RFC 7591 201, CORS *, no-store; 503 + CORS + Retry-After)", %{ids: ids} do
      T.enable_oauth(T.issuer(), %{pending_host_cap: 1})
      host = "element.#{domain("example")}"

      ok = http_reg(ids, host, ip: @attacker)
      assert ok.status == 201
      assert is_binary(T.json(ok)["client_id"])
      assert T.header(ok, "access-control-allow-origin") == "*"
      assert T.header(ok, "cache-control") =~ "no-store"

      refused = http_reg(ids, host, ip: @attacker)
      T.assert_oauth_error(refused, 503, "temporarily_unavailable")
      assert T.header(refused, "access-control-allow-origin") == "*"
      assert T.header(refused, "cache-control") =~ "no-store"
      assert T.header(refused, "retry-after")
    end

    test "dedup hits stay answered for the capped attacker (cap counts NEW metadata only)", %{ids: ids} do
      T.enable_oauth(T.issuer(), %{pending_host_cap: 1})
      host = "element.#{domain("example")}"
      first = body(host)
      ok = T.register(first, ip: @attacker) |> then(&remember(ids, &1))
      assert ok.status == 201
      T.assert_oauth_error(http_reg(ids, host, ip: @attacker), 503, "temporarily_unavailable")
      assert T.register(first, ip: @attacker).status == 201
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 — gate (h): live authorization requests per source
  # ════════════════════════════════════════════════════════════════════════════

  defp authz_attrs(cid, source_key, seams) do
    base = %{
      state_hash: Nebu.OAuth.AuthzStore.hash("st-" <> T.rand(8)),
      client_id: cid,
      redirect_uri: @https,
      code_challenge: "c",
      device_id: "D",
      scope: "s",
      scope_prefix: "urn:matrix:client:",
      response_mode: "fragment",
      client_state: nil,
      client_nonce: nil,
      openid_requested: false,
      idp_code_verifier_enc: "enc",
      idp_nonce: "n",
      browser_binding_hash: "b"
    }

    base = if source_key == :none, do: base, else: Map.put(base, :source_key, source_key)
    Map.merge(base, Map.new(seams))
  end

  defp seed_live_authz!(filler, source_key, count) do
    T.sql!(
      "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix, " <>
        "response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, expires_at, source_key) " <>
        "SELECT 'atdd-ah10-' || $1::text || '-' || g, $2, 'https://app.example.com/cb', 'c', 'D', 's', 'urn:matrix:client:', " <>
        "'fragment', 'enc', 'n', 'b', now() + interval '5 minutes', $3 FROM generate_series(1, $4::int) g",
      [T.rand(), filler, source_key, count]
    )
  end

  describe "AC10.1 — AuthzStore.insert/1 per-source cap (AH10)" do
    setup do
      {:ok, cid: T.oauth_client!([@https])}
    end

    test "the 4th live row of a source is refused (:capacity); another source is admitted", %{cid: cid} do
      src = unique_source_key()
      other = unique_source_key()

      for _ <- 1..3, do: assert(:ok = Nebu.OAuth.AuthzStore.insert(authz_attrs(cid, src, source_cap: 3)))
      assert {:error, :capacity} = Nebu.OAuth.AuthzStore.insert(authz_attrs(cid, src, source_cap: 3))
      assert :ok = Nebu.OAuth.AuthzStore.insert(authz_attrs(cid, other, source_cap: 3))
      assert T.count_for("oauth_authz_requests", cid) == 4, "the refused request inserted nothing and nothing was evicted"
    end

    test "expired rows and NULL-source rows do not count per source", %{cid: cid} do
      src = unique_source_key()

      T.sql!(
        "INSERT INTO oauth_authz_requests (state_hash, client_id, redirect_uri, code_challenge, device_id, scope, scope_prefix, " <>
          "response_mode, idp_code_verifier_enc, idp_nonce, browser_binding_hash, created_at, expires_at, source_key) " <>
          "SELECT 'atdd-ah10x-' || $1::text || '-' || g, $2, 'u', 'c', 'D', 's', 'urn:matrix:client:', 'fragment', 'e', 'n', 'b', " <>
          "now() - interval '11 minutes', now() - interval '1 minute', $3 FROM generate_series(1, 5) g",
        [T.rand(), cid, src]
      )

      for _ <- 1..5, do: assert(:ok = Nebu.OAuth.AuthzStore.insert(authz_attrs(cid, :none, source_cap: 3)), "NULL-source rows never count")
      for _ <- 1..3, do: assert(:ok = Nebu.OAuth.AuthzStore.insert(authz_attrs(cid, src, source_cap: 3)), "expired rows never count")
      assert {:error, :capacity} = Nebu.OAuth.AuthzStore.insert(authz_attrs(cid, src, source_cap: 3))
    end

    test "the default per-source cap is 300 and the global cap stays 10 000 (built-in, no eviction)" do
      src = Path.expand("../../../lib/nebu/oauth/authz_store.ex", __DIR__) |> File.read!() |> code_only()
      assert src =~ ~r/@source_live_cap\s+300\b/
      assert src =~ ~r/@live_cap\s+10_000\b/
      # behaviour pinned by the AC10.1 tests above (nothing evicted); statically: only consume/1 and purge_expired/0 delete
      assert length(Regex.scan(~r/DELETE\s+FROM\s+oauth_authz_requests/i, src)) == 2, "the only DELETEs are consume/1 and purge_expired/0"
    end
  end

  describe "AC10.2-10.3 — authorize through the router, distinct client IPs" do
    setup do
      T.setup_idp!()
      {:ok, cid: T.oauth_client!([@https]), filler: T.oauth_client!([@https])}
    end

    defp authz_key(cid) do
      [row] = T.rows_for("oauth_authz_requests", cid)
      row["source_key"]
    end

    test "AC10.2 a source with 300 live rows gets temporarily_unavailable; another source reaches the IdP", %{cid: cid, filler: filler} do
      seed_live_authz!(filler, key("203.0.113.7"), 300)

      pairs = T.authorize_params(cid, @https)
      conn = T.authorize(pairs, ip: {203, 0, 113, 7})
      T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(pairs, "state"))
      assert T.count_for("oauth_authz_requests", cid) == 0, "nothing inserted"
      assert T.count_for("oauth_authz_requests", filler) == 300, "nothing evicted"

      flow = T.start_flow(cid, @https, %{}, ip: {203, 0, 113, 8})
      assert flow.conn.status == 302
      assert authz_key(cid) == key("203.0.113.8")
    end

    test "AC10.3 IPv6: the cap is per /64", %{cid: cid, filler: filler} do
      seed_live_authz!(filler, key("2001:db8:1:2::1"), 300)

      pairs = T.authorize_params(cid, @https)
      conn = T.authorize(pairs, ip: {0x2001, 0xDB8, 1, 2, 0, 0, 0, 0x99})
      T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(pairs, "state"))

      T.start_flow(cid, @https, %{}, ip: {0x2001, 0xDB8, 1, 3, 0, 0, 0, 1})
      assert authz_key(cid) == key("2001:db8:1:3::1")
    end

    test "AC10.3 through a trusted proxy the key is the forwarded client", %{cid: cid, filler: filler} do
      Nebu.Web.ClientIP.configure("10.0.0.0/8")
      seed_live_authz!(filler, key("203.0.113.7"), 300)

      pairs = T.authorize_params(cid, @https)
      conn = T.authorize(pairs, ip: {10, 0, 0, 5}, xff: "203.0.113.7")
      T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(pairs, "state"))

      T.start_flow(cid, @https, %{}, ip: {10, 0, 0, 5}, xff: "203.0.113.8")
      assert authz_key(cid) == key("203.0.113.8")
    end

    test "AC10.3 an untrusted peer cannot dodge the cap with X-Forwarded-For", %{cid: cid, filler: filler} do
      seed_live_authz!(filler, key("203.0.113.7"), 300)

      for i <- 1..3 do
        pairs = T.authorize_params(cid, @https)
        conn = T.authorize(pairs, ip: {203, 0, 113, 7}, xff: "198.51.100.#{i}")
        T.assert_error_redirect(conn, @https, "temporarily_unavailable", "fragment", T.param(pairs, "state"))
      end
    end

    test "once the source's live rows are gone it can start a flow again (no sticky block)", %{cid: cid, filler: filler} do
      src = key("203.0.113.7")
      seed_live_authz!(filler, src, 300)
      T.cleanup_clients([filler])

      T.start_flow(cid, @https, %{}, ip: {203, 0, 113, 7})
      assert authz_key(cid) == src
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11 — gate (aa): account login requests per source
  # ════════════════════════════════════════════════════════════════════════════

  defp login_attrs(source_key, seams) do
    # state_hash / binding_hash: 64 lowercase hex (CHECKs of migration 000043)
    hex = fn -> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower) end
    base = %{state_hash: hex.(), idp_verifier_enc: "atdd-ah11-enc", idp_nonce: "n", binding_hash: hex.()}
    base = if source_key == :none, do: base, else: Map.put(base, :source_key, source_key)
    Map.merge(base, Map.new(seams))
  end

  describe "AC11 — account login requests" do
    setup do
      on_exit(fn -> T.privileged_sql!("DELETE FROM oauth_account_login_requests WHERE idp_verifier_enc = 'atdd-ah11-enc'") end)
      :ok
    end

    test "AC11.1 insert_login_request/1 with source_cap: 2: the 3rd live row of a source is :capacity; another source :ok" do
      src = unique_source_key()
      for _ <- 1..2, do: assert(:ok = Nebu.OAuth.AccountStore.insert_login_request(login_attrs(src, source_cap: 2)))
      assert {:error, :capacity} = Nebu.OAuth.AccountStore.insert_login_request(login_attrs(src, source_cap: 2))
      assert :ok = Nebu.OAuth.AccountStore.insert_login_request(login_attrs(unique_source_key(), source_cap: 2))
    end

    test "AC11.1 NULL-source login requests never count per source (old nodes, AH17)" do
      for _ <- 1..4, do: assert(:ok = Nebu.OAuth.AccountStore.insert_login_request(login_attrs(:none, source_cap: 2)))
    end

    test "AC11.1 the default per-source cap is 300, the global cap stays 10 000 (built-in)" do
      src = Path.expand("../../../lib/nebu/oauth/account_store.ex", __DIR__) |> File.read!() |> code_only()
      assert src =~ ~r/@source_\w*cap\s+300\b/
      assert src =~ ~r/@login_cap\s+10_000\b/
    end

    test "AC11.2 GET /account from a capped source => unavailable page; another source => 302 to the IdP" do
      T.setup_idp!()
      capped = key("203.0.113.7")

      T.privileged_sql!(
        "INSERT INTO oauth_account_login_requests (state_hash, idp_verifier_enc, idp_nonce, binding_hash, return_action, created_at, expires_at, source_key) " <>
          "SELECT encode(sha256(('atdd-ah11-' || $1::text || g)::bytea), 'hex'), 'atdd-ah11-enc', 'n', encode(sha256(('b' || $1::text || g)::bytea), 'hex'), NULL, now(), now() + interval '9 minutes', $2 " <>
          "FROM generate_series(1, 300) g",
        [T.rand(), capped]
      )

      T.account_get("/account", ip: {203, 0, 113, 7}) |> T.assert_account_error(503, "unavailable")

      flow = T.account_start!("/account", ip: {203, 0, 113, 8})
      assert %{rows: [[stored]]} = T.sql!("SELECT source_key FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)])
      assert stored == key("203.0.113.8")
      on_exit(fn -> T.privileged_sql!("DELETE FROM oauth_account_login_requests WHERE state_hash = $1", [T.sha256_hex(flow.state)]) end)
    end

    test "AC11.2 the account SESSION table needs no per-source column (authenticated, 20 per user: gate aa closed by rationale)" do
      %{rows: rows} =
        T.sql!("SELECT column_name FROM information_schema.columns WHERE table_name = 'oauth_account_sessions' AND column_name = 'source_key'")

      assert rows == []
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC12 — logging law
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC12 — no source key, IP, host or domain in any log line" do
    setup do
      original = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original) end)
      :ok
    end

    test "registration cap hits (AC6.1 shape) log neither source key, IP, host nor domain", %{ids: ids} do
      T.enable_oauth(T.issuer(), %{pending_host_cap: 2})
      d = domain("example")
      host = "element." <> d

      log =
        capture_log([level: :info], fn ->
          for _ <- 1..3, do: http_reg(ids, host, ip: {198, 51, 100, 9})
          http_reg(ids, host, ip: {203, 0, 113, 7})
        end)

      refute log =~ key("198.51.100.9")
      refute log =~ key("203.0.113.7")
      refute log =~ "198.51.100.9"
      refute log =~ "203.0.113.7"
      refute log =~ host
      refute log =~ d
      assert log =~ ~r/pending cap reached/i, "the cap-hit line is kept (text: global or per source)"
    end

    test "an authorize cap hit logs neither source key nor IP" do
      T.setup_idp!()
      cid = T.oauth_client!([@https])
      filler = T.oauth_client!([@https])
      seed_live_authz!(filler, key("203.0.113.7"), 300)

      log =
        capture_log([level: :info], fn ->
          pairs = T.authorize_params(cid, @https)
          T.authorize(pairs, ip: {203, 0, 113, 7})
        end)

      refute log =~ key("203.0.113.7")
      refute log =~ "203.0.113.7"
      assert log =~ ~r/per-source live authorization request cap reached/
      refute log =~ ~r/global live authorization request cap reached/, "a per-source refusal is told apart from the global cap"
      refute log =~ cid, "the per-source line carries no client id either"
    end

    test "the per-source line is throttled: repeated refusals of one source log it once per window" do
      T.setup_idp!()
      cid = T.oauth_client!([@https])
      filler = T.oauth_client!([@https])
      seed_live_authz!(filler, key("203.0.113.7"), 300)

      log =
        capture_log([level: :info], fn ->
          for _ <- 1..3 do
            pairs = T.authorize_params(cid, @https)
            T.assert_error_redirect(T.authorize(pairs, ip: {203, 0, 113, 7}), @https, "temporarily_unavailable", "fragment", T.param(pairs, "state"))
          end
        end)

      assert length(Regex.scan(~r/per-source live authorization request cap reached/, log)) == 1
    end

    test "a per-source account login refusal logs one source-free per-source line" do
      T.setup_idp!()
      capped = key("203.0.113.7")

      T.privileged_sql!(
        "INSERT INTO oauth_account_login_requests (state_hash, idp_verifier_enc, idp_nonce, binding_hash, return_action, created_at, expires_at, source_key) " <>
          "SELECT encode(sha256(('atdd-ah11l-' || $1::text || g)::bytea), 'hex'), 'atdd-ah11-enc', 'n', encode(sha256(('b' || $1::text || g)::bytea), 'hex'), NULL, now(), now() + interval '9 minutes', $2 " <>
          "FROM generate_series(1, 300) g",
        [T.rand(), capped]
      )

      on_exit(fn -> T.privileged_sql!("DELETE FROM oauth_account_login_requests WHERE idp_verifier_enc = 'atdd-ah11-enc'") end)

      log =
        capture_log([level: :info], fn ->
          for _ <- 1..2, do: T.account_get("/account", ip: {203, 0, 113, 7}) |> T.assert_account_error(503, "unavailable")
        end)

      assert length(Regex.scan(~r/per-source live login request cap reached/, log)) == 1
      refute log =~ capped
      refute log =~ "203.0.113.7"
    end
  end
end
