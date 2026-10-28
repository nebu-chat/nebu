defmodule Nebu.OAuth.OAuthTrustedRedirectOriginTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), D4 source 3 / D6 as amended by the
  security review (SEC #1): the OAuth domain's answer to the Matrix domain's one question,

      Nebu.OAuth.trusted_redirect_url?(origin :: String.t(), raw_redirect_url :: String.t()) :: boolean()

  (AC3.1 e/f, AC3.2, AC4.3), and its effect on the legacy callback.

  Auto-trusted, independent of `oauth_enabled`:

    * the ORIGIN of the configured `oauth_issuer_url` (also while OAuth is off; no DB read for this source);
    * an `approved` client's REGISTERED redirect URI, not its origin: the raw redirectUrl must EQUAL a registered
      `https` redirect_uri or start with it at a path boundary (the next character is `/`, `?` or `#`, or the
      registered URI itself ends with `/`). An origin-only match (another path on the same origin) gives the
      confirmation page: an approved client registered with `https://storage.example/<bucket>/cb` must not make
      `https://storage.example/<attacker-bucket>/x` a silent loginToken sink. `pending`, `rejected` and
      `revoked` never count.

  ONE bounded query (`timeout: 500, pool_timeout: 500`) on the jsonb array `redirect_uris` (clients stored the
  way production stores them: an object-typed `metadata`), no cache (an approve or a revocation takes effect
  immediately). Any error / timeout / exception / non-binary input is `false` plus ONE value-free WARNING
  `OAuth: trusted redirect origin lookup failed` (never the origin or the URL).

  `:integration` (client rows through `Nebu.OAuth.TestSupport`); the seam `:sso_trusted_origin_check` is NOT
  installed here: the real facade call is exercised.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  setup do
    T.reset_rate_limits()
    priv = T.setup_idp!()
    T.drop_confirm_entries!()
    T.drop_token_entries!()
    T.disable_oauth()
    T.sso_origins!([])
    original = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original)
      Application.delete_env(:nebu_http, :oauth_repo)
      T.clear_oauth_config()
      T.restore_rate_limits()
      T.drop_confirm_entries!()
    end)

    {:ok, priv: priv}
  end

  defp trusted?(origin, raw_url), do: apply(Nebu.OAuth, :trusted_redirect_url?, [origin, raw_url])

  defp host, do: "app-" <> T.rand(6) <> ".example"

  defp callback(priv, url, opts \\ []), do: T.legacy_callback!(priv, T.unique_sub(), url, opts)

  defp assert_direct(conn, url) do
    assert conn.status == 302, "expected today's 302 for #{url}, got #{conn.status} Location=#{inspect(T.location(conn))}"
    assert [token] = T.login_tokens_of(conn)
    assert T.location(conn) == Nebu.Matrix.SsoLogin.append_login_token(url, token)
    token
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Nebu.OAuth.trusted_redirect_url?/2: the issuer source (by ORIGIN)
  # ════════════════════════════════════════════════════════════════════════════

  describe "the issuer origin (also while oauth_enabled is OFF)" do
    test "the configured issuer's origin is trusted for any URL on it, with OAuth off and on" do
      T.disable_oauth()
      assert trusted?("https://nebu.example.com", "https://nebu.example.com/anything?x=1#f")
      T.enable_oauth()
      assert trusted?("https://nebu.example.com", "https://nebu.example.com/")
    end

    test "an issuer with a port trusts that origin only" do
      T.enable_oauth("https://nebu.example.com:8443")
      assert trusted?("https://nebu.example.com:8443", "https://nebu.example.com:8443/cb")
      refute trusted?("https://nebu.example.com", "https://nebu.example.com/cb")
    end

    test "an unreadable server_config contributes nothing (fail closed, never a raise)" do
      T.unreadable_oauth_config()
      refute trusted?("https://nebu.example.com", "https://nebu.example.com/cb")
    end

    test "another origin, a subdomain and an http origin of the issuer host are not trusted" do
      refute trusted?("https://other.example.com", "https://other.example.com/cb")
      refute trusted?("https://sub.nebu.example.com", "https://sub.nebu.example.com/cb")
      refute trusted?("http://nebu.example.com", "http://nebu.example.com/cb")
    end

    test "the issuer source needs no database read (it still works with an unavailable DB, without a WARNING)" do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      log = capture_log(fn -> send(self(), {:r, trusted?("https://nebu.example.com", "https://nebu.example.com/cb")}) end)
      assert_received {:r, true}
      refute log =~ "trusted redirect origin lookup failed"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # approved clients: the REGISTERED redirect URI (SEC #1)
  # ════════════════════════════════════════════════════════════════════════════

  describe "SEC #1 — an approved client's registered URI, not its origin" do
    test "the raw URL equals the registered URI, or extends it at a path boundary (/, ?, #)" do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")
      o = "https://#{h}"

      for raw <- ["#{o}/cb", "#{o}/cb/", "#{o}/cb/x", "#{o}/cb/x/y?z=1#f", "#{o}/cb?q=1", "#{o}/cb#f", "#{o}/cb?q=1#f"] do
        assert trusted?(o, raw), "#{raw} must be trusted (registered #{o}/cb)"
      end
    end

    test "another path of the same origin is NOT trusted: a longer segment, a sibling, the root, the bare origin" do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")
      o = "https://#{h}"

      for raw <- ["#{o}/cbx", "#{o}/cb2/x", "#{o}/other", "#{o}/other/cb", "#{o}/c", "#{o}/", o, "#{o}?x=1", "#{o}/CB"] do
        refute trusted?(o, raw), "#{raw} must NOT be trusted (registered #{o}/cb): an origin-only match is not enough"
      end
    end

    test "a registered URI that ends with / trusts everything below it, but not the path without the slash" do
      h = host()
      T.oauth_client!(["https://#{h}/app/"], status: "approved")
      o = "https://#{h}"

      for raw <- ["#{o}/app/", "#{o}/app/x", "#{o}/app/x/y?z#f", "#{o}/app/index.html"] do
        assert trusted?(o, raw), raw
      end

      for raw <- ["#{o}/app", "#{o}/apple/", "#{o}/appx/", "#{o}/"], do: refute(trusted?(o, raw), raw)
    end

    test "the port is part of the registered URI" do
      h = host()
      T.oauth_client!(["https://#{h}:8443/cb"], status: "approved")
      assert trusted?("https://#{h}:8443", "https://#{h}:8443/cb?x=1")
      refute trusted?("https://#{h}", "https://#{h}/cb")
      refute trusted?("https://#{h}:9443", "https://#{h}:9443/cb")
    end

    test "every https registered URI of a client counts; loopback and private-use URIs never match an https origin" do
      h1 = host()
      h2 = host()
      T.oauth_client!(["https://#{h1}/one", "https://#{h2}/two/", "http://localhost/cb", "com.example.app:/cb"], status: "approved")
      assert trusted?("https://#{h1}", "https://#{h1}/one")
      assert trusted?("https://#{h2}", "https://#{h2}/two/x")
      refute trusted?("https://#{h1}", "https://#{h1}/two")
      refute trusted?("http://localhost", "http://localhost/cb")
    end

    test "pending, rejected and revoked clients are NEVER trusted, not even for the exact registered URI" do
      for status <- ["pending", "rejected", "revoked"] do
        h = host()
        T.oauth_client!(["https://#{h}/cb"], status: status)
        refute trusted?("https://#{h}", "https://#{h}/cb"), "a #{status} client must not make its URI trusted"
      end
    end

    test "an approve takes effect immediately and a revocation too (no cache)" do
      h = host()
      cid = T.oauth_client!(["https://#{h}/cb"], status: "approved")
      assert trusted?("https://#{h}", "https://#{h}/cb")
      :ok = T.mark_revoked!(cid)
      refute trusted?("https://#{h}", "https://#{h}/cb")
    end

    test "a host that merely starts with / ends like the registered host, or a subdomain, is NOT trusted" do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")
      refute trusted?("https://#{h}.evil.example", "https://#{h}.evil.example/cb")
      refute trusted?("https://sub.#{h}", "https://sub.#{h}/cb")
      refute trusted?("https://x#{h}", "https://x#{h}/cb")
    end

    test "LIKE wildcards in the stored URI or in the asked origin never widen the match (the pattern is escaped)" do
      h = host()
      T.oauth_client!(["https://a_#{h}/cb", "https://x%#{h}/cb"], status: "approved")
      refute trusted?("https://ab#{h}", "https://ab#{h}/cb"), "`_` is not a wildcard"
      refute trusted?("https://xyz#{h}", "https://xyz#{h}/cb"), "`%` is not a wildcard"
      refute trusted?("https://%", "https://%/cb")
      refute trusted?("https://_", "https://_/cb")
    end

    test "metadata registered the way production does it (an object-typed jsonb via ClientStore.register) matches too" do
      h = host()

      {:ok, validated} =
        Nebu.OAuth.Registration.validate(T.web_body(%{"client_uri" => "https://#{h}", "redirect_uris" => ["https://#{h}/cb"]}))

      assert {:ok, %{client_id: cid}} = Nebu.OAuth.ClientStore.register(validated)
      ExUnit.Callbacks.on_exit(fn -> T.cleanup_clients([cid]) end)

      assert [["object"]] = T.sql!("SELECT jsonb_typeof(metadata) FROM oauth_clients WHERE client_id = $1", [cid]).rows, "production stores an object"
      refute trusted?("https://#{h}", "https://#{h}/cb"), "still pending"

      T.sql!("UPDATE oauth_clients SET status = 'approved', approved_by = '@admin:test.local', approved_at = NOW() WHERE client_id = $1", [cid])
      assert trusted?("https://#{h}", "https://#{h}/cb")
      assert trusted?("https://#{h}", "https://#{h}/cb/deeper?x=1")
      refute trusted?("https://#{h}", "https://#{h}/elsewhere")
    end

    test "the fixture stores an OBJECT-typed metadata (the production SQL reads the jsonb array redirect_uris)" do
      h = host()
      cid = T.oauth_client!(["https://#{h}/cb"], status: "approved")
      assert [["object"]] = T.sql!("SELECT jsonb_typeof(metadata) FROM oauth_clients WHERE client_id = $1", [cid]).rows
      assert [["https://" <> _]] = T.sql!("SELECT metadata->'redirect_uris'->>0 FROM oauth_clients WHERE client_id = $1", [cid]).rows
    end
  end

  describe "review cycle 2 (INFO-2) — ClientStore.approved_redirect_uris/1: exactly the asked host, deterministic" do
    test "https://<host> followed by the end or / : ? # only; never https://<host>.other or https://<host>x" do
      h = host()

      T.oauth_client!(
        ["https://#{h}", "https://#{h}/a", "https://#{h}:8443/b", "https://#{h}?q=1", "https://#{h}#f", "https://#{h}.other.example/no", "https://#{h}x/no"],
        status: "approved"
      )

      assert {:ok, uris} = Nebu.OAuth.ClientStore.approved_redirect_uris(h)
      assert Enum.sort(uris) == Enum.sort(["https://#{h}", "https://#{h}/a", "https://#{h}:8443/b", "https://#{h}?q=1", "https://#{h}#f"])
    end

    test "the result is ordered (the LIMIT 50 is deterministic) and repeatable" do
      h = host()
      for i <- 1..5, do: T.oauth_client!(["https://#{h}/p#{i}"], status: "approved")
      assert {:ok, first} = Nebu.OAuth.ClientStore.approved_redirect_uris(h)
      assert {:ok, ^first} = Nebu.OAuth.ClientStore.approved_redirect_uris(h)
      assert length(first) == 5
    end

    test "a non-approved client and an unavailable database give no URI / :error" do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "pending")
      assert {:ok, []} = Nebu.OAuth.ClientStore.approved_redirect_uris(h)
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      log = capture_log(fn -> send(self(), {:r, Nebu.OAuth.ClientStore.approved_redirect_uris(h)}) end)
      assert_received {:r, :error}
      assert length(Regex.scan(~r/\[warning\] OAuth: trusted redirect origin lookup failed/, log)) == 1
    end
  end

  describe "malformed input and failures => false, never a raise" do
    test "non-binary and malformed origins or URLs" do
      for {o, u} <- [
            {nil, nil},
            {"", ""},
            {123, "https://a.example/cb"},
            {:atom, :atom},
            {["https://a.example"], ["https://a.example/cb"]},
            {"https://a.example", nil},
            {"https://a.example", 5},
            {"not-an-origin", "not-an-origin"},
            {"https://", "https:///x"},
            {"ftp://a.example", "ftp://a.example/x"},
            {"https://a.example/path", "https://a.example/path"}
          ] do
        assert trusted?(o, u) == false, "trusted_redirect_url?(#{inspect(o)}, #{inspect(u)}) must be false"
      end
    end

    test "an unavailable database => false and ONE value-free WARNING; the issuer origin still works without the database" do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)

      log = capture_log(fn -> send(self(), {:r, trusted?("https://#{h}", "https://#{h}/cb")}) end)
      assert_received {:r, false}
      assert length(Regex.scan(~r/\[warning\] OAuth: trusted redirect origin lookup failed/, log)) == 1
      refute log =~ h, "neither the origin nor the URL is ever logged"
      assert trusted?("https://nebu.example.com", "https://nebu.example.com/cb"), "the issuer source needs no database"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # through the legacy callback (the real facade call, no seam)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3.1(e) — the issuer origin with OAuth OFF is listed for the legacy callback" do
    test "302 with a loginToken, no confirmation", %{priv: priv} do
      T.disable_oauth()
      url = "https://nebu.example.com/cb?x=1"
      assert_direct(callback(priv, url), url)
    end

    test "also when the database is unreachable (no DB read for this source)", %{priv: priv} do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      url = "https://nebu.example.com/cb"
      assert_direct(callback(priv, url), url)
    end
  end

  describe "AC3.1(f) / SEC #1 — an approved client's REGISTERED redirect URI is listed for the legacy callback" do
    test "the registered URI and below it: 302 with a loginToken that redeems at POST /login", %{priv: priv} do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")
      sub = T.unique_sub()
      token = assert_direct(T.legacy_callback!(priv, sub, "https://#{h}/cb"), "https://#{h}/cb")

      login = T.sso_token_login(token)
      assert login.status == 200, "got #{login.status} #{login.resp_body}"
      assert T.json(login)["user_id"] == T.sso_user_id(%{"sub" => sub})

      for url <- ["https://#{h}/cb/deeper", "https://#{h}/cb?x=1", "https://#{h}/cb#/home"] do
        assert_direct(callback(priv, url), url)
      end
    end

    test "the SAME ORIGIN with another path gets the confirmation page (no silent token)", %{priv: priv} do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")
      before = T.sso_token_keys()

      for url <- ["https://#{h}/other", "https://#{h}/cbx", "https://#{h}/", "https://#{h}/attacker-bucket/x.html"] do
        T.assert_confirm_redirect(callback(priv, url))
      end

      assert T.sso_token_keys() == before, "nothing minted for an origin-only match"
    end

    test "dot segments cannot climb out of the registered path: rejected at the leg or confirmed, never direct", %{priv: priv} do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")

      for url <- ["https://#{h}/cb/../x", "https://#{h}/cb/%2e%2e/x", "https://#{h}/cb/./../x"] do
        leg = T.sso_redirect([], redirect_url: url)

        case leg.status do
          400 ->
            assert Jason.decode!(leg.resp_body)["errcode"] == "M_INVALID_PARAM"

          302 ->
            idp = T.idp_params(leg)
            cb = T.sso_finish(%{state: idp["state"], nonce: idp["nonce"]}, priv)
            T.assert_confirm_redirect(cb)

          other ->
            flunk("unexpected status #{other} for #{url}")
        end
      end
    end

    test "X-4: matrix parameters (`;`) and double encoding (`%25`) in the path are not listed: the confirmation page, never direct", %{priv: priv} do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")
      before = T.sso_token_keys()

      for url <- ["https://#{h}/cb/..;/x", "https://#{h}/cb/;x/y", "https://#{h}/cb/sub;jsessionid=1/x", "https://#{h}/cb/%252e%252e/x", "https://#{h}/cb/a%25b"] do
        leg = T.sso_redirect([], redirect_url: url)

        case leg.status do
          400 ->
            assert Jason.decode!(leg.resp_body)["errcode"] == "M_INVALID_PARAM"

          302 ->
            idp = T.idp_params(leg)
            cb = T.sso_finish(%{state: idp["state"], nonce: idp["nonce"]}, priv)
            T.assert_confirm_redirect(cb)

          other ->
            flunk("unexpected status #{other} for #{url}")
        end
      end

      assert T.sso_token_keys() == before, "no loginToken minted for any of them"
    end

    test "X-4: Nebu.OAuth.trusted_redirect_url?/2 is false for `;` and `%25` paths below the registered URI and true for the plain rows" do
      h = host()
      T.oauth_client!(["https://#{h}/cb/"], status: "approved")

      for url <- ["https://#{h}/cb/..;/x", "https://#{h}/cb/;x/y", "https://#{h}/cb/sub;p=1/x", "https://#{h}/cb/%252e%252e/x", "https://#{h}/cb/a%25b/c"] do
        refute Nebu.OAuth.trusted_redirect_url?("https://#{h}", url), "#{url} must not be listed"
      end

      for url <- ["https://#{h}/cb/", "https://#{h}/cb/sub?x=1", "https://#{h}/cb/sub?x=a;b", "https://#{h}/cb/sub#a;b"] do
        assert Nebu.OAuth.trusted_redirect_url?("https://#{h}", url), "#{url} must stay listed"
      end
    end

    test "X-4: a `;` or `%25` in the QUERY or the fragment does not matter (only the path is checked); the plain rows stay listed", %{priv: priv} do
      h = host()
      T.oauth_client!(["https://#{h}/cb/"], status: "approved")

      for url <- ["https://#{h}/cb/", "https://#{h}/cb/sub?x=1", "https://#{h}/cb/sub?x=a;b", "https://#{h}/cb/sub?x=%25", "https://#{h}/cb/sub#a;b"] do
        assert_direct(callback(priv, url), url)
      end
    end

    test "a revocation takes effect on the very next login", %{priv: priv} do
      h = host()
      cid = T.oauth_client!(["https://#{h}/cb"], status: "approved")
      assert_direct(callback(priv, "https://#{h}/cb"), "https://#{h}/cb")
      :ok = T.mark_revoked!(cid)
      T.assert_confirm_redirect(callback(priv, "https://#{h}/cb"))
    end
  end

  describe "AC3.2 — pending, rejected and revoked clients are NOT listed" do
    for status <- ["pending", "rejected", "revoked"] do
      test "a #{status} client's registered URI gets the confirmation", %{priv: priv} do
        h = host()
        T.oauth_client!(["https://#{h}/cb"], status: unquote(status))
        before = T.sso_token_keys()
        cb = callback(priv, "https://#{h}/cb")
        T.assert_confirm_redirect(cb)
        assert T.sso_token_keys() == before
      end
    end

    test "an origin that only differs in port from an approved client's is not listed", %{priv: priv} do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")
      T.assert_confirm_redirect(callback(priv, "https://#{h}:8443/cb"))
    end
  end

  describe "AC4.3 — a failing lookup fails closed" do
    test "an unavailable database => the confirmation page, one value-free WARNING, the listed sources still work", %{priv: priv} do
      h = host()
      T.oauth_client!(["https://#{h}/cb"], status: "approved")
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      T.sso_origins!(["https://listed.example"])

      log =
        capture_log(fn ->
          send(self(), {:unlisted, callback(priv, "https://#{h}/cb")})
          send(self(), {:listed, callback(priv, "https://listed.example/cb")})
        end)

      assert_received {:unlisted, unlisted}
      assert_received {:listed, listed}
      T.assert_confirm_redirect(unlisted)
      assert_direct(listed, "https://listed.example/cb")
      assert length(Regex.scan(~r/\[warning\] OAuth: trusted redirect origin lookup failed/, log)) == 1

      # the INFO `redirect confirmation shown host=<h>` and the leg's DEBUG line name the host by design: only the
      # lookup WARNING lines must be value-free
      lookup_lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "trusted redirect origin lookup failed"))
      for line <- lookup_lines, do: refute(line =~ h, "the lookup WARNING must not name the origin: #{line}")
    end
  end
end
