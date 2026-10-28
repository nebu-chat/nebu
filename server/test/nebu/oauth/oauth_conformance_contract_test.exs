defmodule Nebu.OAuth.OAuthConformanceContractTest do
  @moduledoc """
  CONFORMANCE CONTRACT suite for story `oauth-versions-switch` (story 9 of epic
  oauth-broker), AC5 / V10 (Must #20-#35, #45-#47): the LIVE metadata document (S1, test issuer) is
  truthful.

    * (a) crawler: every advertised URL (derived from the LIVE document, never from constants) answers
      neither the router fall-through (`404 "not found"`), nor Protected's `M_NOT_FOUND`, nor
      `M_UNRECOGNIZED`; GET endpoints with GET, POST endpoints with an empty POST and with GET (405 +
      `Allow`);
    * (b) one named test per field (table of the story's Dev Notes);
    * (c) key guard: the top-level key set equals the contract set (the ONLY list of known keys);
    * (d) byte identity of `v1/auth_metadata`, the unstable alias and the issuer's openid-configuration;
    * the same crawl in S3 (documented disabled answers; revoke stays live), spec-REQUIRED fields and
      "at least" MUSTs, re-registration without an approval loop, the pending purge never deleting an
      approved client with a live session.

  The suite is the contract guard of the live document (stories 1-6 made it truthful, story 9 refactors the
  predicate under it): a red test in this file means the contract is broken (see the ATDD Decisions).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"

  @contract_keys ~w(issuer authorization_endpoint token_endpoint revocation_endpoint registration_endpoint
                    response_types_supported grant_types_supported response_modes_supported
                    code_challenge_methods_supported token_endpoint_auth_methods_supported
                    revocation_endpoint_auth_methods_supported authorization_response_iss_parameter_supported
                    jwks_uri id_token_signing_alg_values_supported account_management_uri
                    account_management_actions_supported)

  @get_fields ~w(authorization_endpoint jwks_uri account_management_uri openid-configuration)
  @post_fields ~w(token_endpoint revocation_endpoint registration_endpoint)

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    {:ok, priv: priv, doc: T.json(T.get_metadata()), cid: T.oauth_client!([@https])}
  end

  defp call(method, url, body \\ nil, ct \\ nil) do
    c = if body, do: Plug.Test.conn(method, T.router_path(url), body), else: Plug.Test.conn(method, T.router_path(url))
    c = if ct, do: Plug.Conn.put_req_header(c, "content-type", ct), else: c
    c |> Map.put(:remote_ip, T.unique_ip()) |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
  end

  # ════════════════════════════════════════════════════════════════════════════
  # (a) crawler / (c) key guard / (d) byte identity
  # ════════════════════════════════════════════════════════════════════════════

  describe "V10 (a)/Must #20 — crawler over the LIVE document (S1)" do
    test "every advertised URL is implemented (GET endpoints with GET, POST endpoints with an empty POST + GET => 405 Allow)", %{doc: doc} do
      urls = T.advertised_urls(doc)
      fields = Enum.map(urls, &elem(&1, 0))
      for f <- @get_fields ++ @post_fields, do: assert(f in fields, "#{f} must be advertised")

      for {field, url} <- urls do
        cond do
          field in @get_fields ->
            conn = call(:get, url)
            refute T.unimplemented_answer?(conn), "#{field} (GET #{T.router_path(url)}) answered #{conn.status} #{String.slice(conn.resp_body || "", 0, 120)}"

          field in @post_fields ->
            {body, ct} = if field == "registration_endpoint", do: {"{}", "application/json"}, else: {"", "application/x-www-form-urlencoded"}
            conn = call(:post, url, body, ct)
            refute T.unimplemented_answer?(conn), "#{field} (POST) answered #{conn.status}"
            get = call(:get, url)
            assert get.status == 405, "#{field}: GET => 405, got #{get.status}"
            assert T.header(get, "allow") =~ "POST"

          true ->
            flunk("advertised URL field #{field} has no contract entry")
        end
      end
    end
  end

  describe "V10 (b) — value types" do
    test "every URL-looking value starts with the issuer and is https; lists are non-empty lists of strings; the iss flag is boolean", %{doc: doc} do
      issuer = doc["issuer"]
      assert URI.parse(issuer).scheme == "https"

      for {k, v} <- doc, is_binary(v), v =~ ~r{^[a-z][a-z0-9+.-]*://}i do
        assert String.starts_with?(v, issuer), "#{k} (#{v}) must live under the issuer (no IdP / foreign URL)"
        assert URI.parse(v).scheme == "https", "#{k} must be https"
      end

      for {k, v} <- doc, String.ends_with?(k, "_supported") and k != "authorization_response_iss_parameter_supported" do
        assert is_list(v) and v != [] and Enum.all?(v, &(is_binary(&1) and &1 != "")), "#{k} must be a non-empty list of strings"
      end

      assert is_boolean(doc["authorization_response_iss_parameter_supported"])
    end
  end

  describe "V10 (c)/Must #21 — key guard" do
    test "the top-level key set equals the contract set; device grant / prompt_values / auth_issuer absent", %{doc: doc} do
      assert Enum.sort(Map.keys(doc)) == Enum.sort(@contract_keys), "a new metadata key needs a contract entry (V10 c)"
      for k <- ~w(device_authorization_endpoint prompt_values_supported auth_issuer), do: refute(Map.has_key?(doc, k))
      refute "urn:ietf:params:oauth:grant-type:device_code" in doc["grant_types_supported"]
    end
  end

  describe "V10 (d)/Must #34 — issuer and byte identity" do
    test "issuer == the test issuer; v1, unstable alias and new URL('.well-known/openid-configuration', issuer) are byte-identical", %{doc: doc} do
      assert doc["issuer"] == T.issuer()
      v1 = T.get_metadata()
      unstable = T.get("/_matrix/client/unstable/org.matrix.msc2965/auth_metadata")
      {_, oidc_url} = Enum.find(T.advertised_urls(doc), &(elem(&1, 0) == "openid-configuration"))
      oidc = call(:get, oidc_url)
      assert oidc.status == 200
      assert v1.resp_body == unstable.resp_body and unstable.resp_body == oidc.resp_body
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # (b) field semantics — one test per field
  # ════════════════════════════════════════════════════════════════════════════

  describe "V10 (b)/Must #45 — spec-REQUIRED fields and 'at least' MUSTs" do
    test "required fields present; code; authorization_code + refresh_token; query + fragment; S256", %{doc: doc} do
      for k <- ~w(issuer authorization_endpoint token_endpoint registration_endpoint revocation_endpoint response_types_supported
                  grant_types_supported response_modes_supported code_challenge_methods_supported),
          do: assert(Map.has_key?(doc, k), "spec-REQUIRED #{k} missing")

      assert "code" in doc["response_types_supported"]
      assert "authorization_code" in doc["grant_types_supported"] and "refresh_token" in doc["grant_types_supported"]
      assert "query" in doc["response_modes_supported"] and "fragment" in doc["response_modes_supported"]
      assert "S256" in doc["code_challenge_methods_supported"]
    end
  end

  describe "V10 (b) — field semantics" do
    defp authorize(doc, pairs), do: call(:get, doc["authorization_endpoint"] <> "?" <> URI.encode_query(pairs))

    test "Must #22 response_types_supported: code proceeds (302 to the IdP); token => unsupported_response_type with iss", %{doc: doc, cid: cid} do
      assert doc["response_types_supported"] == ["code"]
      ok = authorize(doc, T.authorize_params(cid, @https))
      T.idp_params(ok)
      pairs = T.authorize_params(cid, @https, %{"response_type" => "token", "response_mode" => "query"})
      T.assert_error_redirect(authorize(doc, pairs), @https, "unsupported_response_type", "query", T.param(pairs, "state"))
    end

    test "Must #23 grant_types_supported: bogus authorization_code / refresh_token => invalid_grant; others => unsupported_grant_type", %{doc: doc, cid: cid} do
      assert Enum.sort(doc["grant_types_supported"]) == ["authorization_code", "refresh_token"]
      T.token_request(T.code_grant(cid, "bogus-" <> T.rand(), @https, String.duplicate("v", 43))) |> T.assert_token_error(400, "invalid_grant")
      T.token_request(T.refresh_grant(cid, T.rand(32))) |> T.assert_token_error(400, "invalid_grant")

      for gt <- ["client_credentials", "password", "urn:ietf:params:oauth:grant-type:device_code"] do
        T.token_request([{"grant_type", gt}, {"client_id", cid}]) |> T.assert_token_error(400, "unsupported_grant_type")
      end
    end

    test "Must #24 response_modes_supported: error redirects in query and fragment mode, both with state and iss", %{doc: doc, cid: cid} do
      for mode <- doc["response_modes_supported"] do
        pairs = T.authorize_params(cid, @https, %{"response_mode" => mode, "code_challenge_method" => "plain"})
        T.assert_error_redirect(authorize(doc, pairs), @https, "invalid_request", mode, T.param(pairs, "state"))
      end
    end

    test "Must #25 code_challenge_methods_supported: plain / missing => error redirect; S256 proceeds", %{doc: doc, cid: cid} do
      assert doc["code_challenge_methods_supported"] == ["S256"]
      for o <- [%{"code_challenge_method" => "plain"}, %{"code_challenge" => nil}] do
        pairs = T.authorize_params(cid, @https, Map.put(o, "response_mode", "query"))
        T.assert_error_redirect(authorize(doc, pairs), @https, "invalid_request", "query", T.param(pairs, "state"))
      end

      T.idp_params(authorize(doc, T.authorize_params(cid, @https)))
    end

    test "Must #26 authorization_response_iss_parameter_supported: the success redirect (after the consent Allow) carries iss", %{doc: doc, cid: cid, priv: priv} do
      assert doc["authorization_response_iss_parameter_supported"] == true
      flow = T.start_flow(cid, @https)
      {_base, _mode, params, _} = T.client_redirect(T.finish_allow(flow, priv))
      assert params["iss"] == doc["issuer"]
      assert params["code"]
    end

    test "Must #27 token_endpoint_auth_methods_supported none: no client auth accepted; Basic => 401 invalid_client", %{doc: doc, cid: cid} do
      assert doc["token_endpoint_auth_methods_supported"] == ["none"]
      T.token_request(T.refresh_grant(cid, T.rand(32))) |> T.assert_token_error(400, "invalid_grant")
      T.token_request(T.refresh_grant(cid, T.rand(32)), headers: [{"authorization", "Basic " <> Base.encode64(cid <> ":")}])
      |> T.assert_token_error(401, "invalid_client")
    end

    test "Must #28/#31 revocation: none; unknown token => 200; GET => 405 Allow POST, OPTIONS", %{doc: doc} do
      assert doc["revocation_endpoint_auth_methods_supported"] == ["none"]
      T.revoke([{"token", T.rand(32)}], path: T.router_path(doc["revocation_endpoint"])) |> T.assert_revoke_ok()
      get = call(:get, doc["revocation_endpoint"])
      assert get.status == 405 and T.header(get, "allow") == "POST, OPTIONS"
    end

    test "Must #29 jwks_uri + id_token_signing_alg_values_supported: EC P-256 ES256 public keys; the id_token header alg matches", %{doc: doc, cid: cid, priv: priv} do
      assert doc["id_token_signing_alg_values_supported"] == ["ES256"]
      jw = call(:get, doc["jwks_uri"])
      assert jw.status == 200
      keys = T.json(jw)["keys"]
      assert keys != []
      for k <- keys, do: assert({k["kty"], k["crv"], k["alg"], Map.has_key?(k, "d")} == {"EC", "P-256", "ES256", false})

      grant = T.flow_code!(cid, @https, priv, authorize: %{"scope" => "openid " <> T.matrix_scope(T.stable_prefix(), "CTD" <> String.upcase(T.rand(3)))})
      body = T.redeem!(grant)
      assert T.jws_header(body["id_token"])["alg"] in doc["id_token_signing_alg_values_supported"]
    end

    test "Must #30 registration_endpoint: valid metadata => 201 + client_id; {} => 400 invalid_request (RFC 7591, no errcode)", %{doc: doc} do
      path = T.router_path(doc["registration_endpoint"])
      assert path == "/oauth2/register"
      ok = T.register(T.web_body())
      assert ok.status == 201 and is_binary(T.json(ok)["client_id"])
      on_exit(fn -> T.cleanup_clients([T.json(ok)["client_id"]]) end)
      T.register(%{}) |> T.assert_oauth_error(400, "invalid_request")
    end

    test "Must #32 token_endpoint: GET => 405 Allow POST, OPTIONS; empty form POST => 4xx RFC 6749 shape", %{doc: doc} do
      get = call(:get, doc["token_endpoint"])
      assert get.status == 405 and T.header(get, "allow") == "POST, OPTIONS"
      post = call(:post, doc["token_endpoint"], "", "application/x-www-form-urlencoded")
      assert post.status in [400, 401]
      refute Map.has_key?(T.json(post), "errcode")
    end

    test "Must #33 account_management_uri + actions: GET without session => 302 to the IdP; every advertised action renders itself", %{doc: doc} do
      assert URI.parse(doc["account_management_uri"]).path == "/account"
      T.idp_params(call(:get, doc["account_management_uri"]))
      uid = T.provision_user!()
      acct = T.account_session!(uid)
      Nebu.Matrix.DeviceKeyStore.upsert_device(uid, "CTDEV1")

      for action <- doc["account_management_actions_supported"] do
        extra = if action in ["org.matrix.device_view", "org.matrix.device_delete"], do: "&device_id=CTDEV1", else: ""
        conn = T.account_get(T.router_path(doc["account_management_uri"]) <> "?action=" <> action <> extra, cookie: acct.cookie)
        assert conn.resp_body =~ ~s(data-action="#{action}"), "advertised #{action} must render its own page, never the default page"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # S3 crawl, re-registration, purge
  # ════════════════════════════════════════════════════════════════════════════

  describe "Must #35 — the same crawl in S3 (disabled): the documented disabled answers" do
    test "token / jwks / openid 404 without error; authorize / register 404 M_UNRECOGNIZED; account unavailable page; revoke live", %{doc: doc} do
      T.disable_oauth()
      urls = Map.new(T.advertised_urls(doc))

      for f <- ["jwks_uri", "openid-configuration"] do
        conn = call(:get, urls[f])
        T.assert_unrecognized_404_no_error(conn)
      end

      call(:post, urls["token_endpoint"], "", "application/x-www-form-urlencoded") |> T.assert_unrecognized_404_no_error()
      call(:get, urls["authorization_endpoint"]) |> T.assert_unrecognized_404()
      call(:post, urls["registration_endpoint"], "{}", "application/json") |> T.assert_unrecognized_404()
      T.account_get(T.router_path(urls["account_management_uri"])) |> T.assert_account_error(404, "unavailable")
      T.revoke([{"token", T.rand(32)}], path: T.router_path(urls["revocation_endpoint"])) |> T.assert_revoke_ok()
    end
  end

  describe "Must #46/#47 — re-registration per flow, pending purge" do
    test "identical metadata registers again with the same approved client_id: no approval loop; changed metadata is pending" do
      body = T.web_body()
      first = T.register(body)
      cid = T.json(first)["client_id"]
      on_exit(fn -> T.cleanup_clients([cid]) end)
      :ok = Nebu.OAuth.approve_registration(cid, "@admin:test.local")

      again = T.register(body)
      assert again.status == 201
      assert T.json(again)["client_id"] == cid
      assert T.client_row(cid)["status"] == "approved", "an approved registration is not sent back to manual approval"

      changed = T.register(Map.put(body, "client_uri", "https://example.com/other"))
      new_cid = T.json(changed)["client_id"]
      on_exit(fn -> T.cleanup_clients([new_cid]) end)
      refute new_cid == cid
      assert T.client_row(new_cid)["status"] == "pending"
    end

    test "the pending purge never deletes an approved client with a live session (positive control: an old pending row IS purged)", %{cid: cid, priv: priv} do
      s = T.session!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), "CTP" <> String.upcase(T.rand(3)))})
      T.privileged_sql!("UPDATE oauth_clients SET created_at = now() - interval '400 days' WHERE client_id = $1", [cid])
      pending = T.oauth_client!([@https], status: "pending")
      T.privileged_sql!("UPDATE oauth_clients SET created_at = now() - interval '400 days' WHERE client_id = $1", [pending])

      _ = Nebu.OAuth.purge_expired_pending()
      assert T.client_row(pending) == nil, "positive control: the purge really ran and removed the expired pending registration"
      assert T.client_row(cid)["status"] == "approved"
      assert T.whoami(s.at).status == 200
    end
  end
end
