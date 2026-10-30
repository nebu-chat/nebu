defmodule Nebu.Admin.RoleMappingSelfLockoutTest do
  @moduledoc """
  Story `role-mapping-self-lockout-guard` (follow-up `dg`), AC1 - AC7, decisions D1 - D7.

  The role mapping (`admin_group_claim`) is refused when the verified claims of the FRESH sign-in that the marker proves do not hold the NEW
  value (the saving admin would be locked out at the next sign-in or refresh). The claims reach the form through a compact fingerprint in the
  marker (`claims_fp`: 6-byte prefixes of SHA-256 hashes of the distinct string values at the admin claim path, at most 32, never the values;
  `claims_fp_complete`), written by the callback of `mode=reauth` for the role mapping page only.

  Pinned API: `Nebu.Web.OidcClaims.string_values_at/2`, `Nebu.Admin.Auth.role_claim_fingerprint/1` (claims -> `%{"claims_fp", "claims_fp_complete"}`),
  `Nebu.Admin.Auth.role_claim_hash/1`, `Nebu.Admin.Auth.reauth_role_check/2` (`:ok | :not_in_token | :undecidable | :unknown`),
  `Nebu.Admin.Auth.configured_admin_claim_path/0`. The callback tests of the marker content are in `admin_reauth_test.exs`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.Web.OidcClaims

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-role-lockout-test-key-base", 3)
  @role "/admin/config/role-mapping"
  @claim "/admin/config/claim-mapping"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :lockout_audit_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      :ok
    end
  end

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    T.put_env_scoped(:lockout_audit_sink, self())
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)

    Application.put_env(:nebu_http, :admin_config_role_mapping_writer, fn changes ->
      send(test_pid, {:written, :role, changes})
      :ok
    end)

    Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, []} end)
    with_path(nil)

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_config_role_mapping_writer, :admin_server_config_reader, :admin_oidc_config_reader], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp with_path(path), do: Application.put_env(:nebu_http, :admin_oidc_config_reader, fn "admin_group_claim_path" -> path; _ -> nil end)

  # the 6-byte chunks of a fingerprint
  defp chunks(<<>>), do: []
  defp chunks(<<h::binary-size(6), rest::binary>>), do: [h | chunks(rest)]

  defp hashed?(fp, value), do: Auth.role_claim_hash(value) in chunks(fp["claims_fp"])

  defp admin_conn(method, path, params \\ nil) do
    conn = %{conn(method, path) | secret_key_base: @secret_key_base}

    conn
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> then(fn c -> if params, do: c |> Map.put(:body_params, params) |> Map.put(:params, params), else: c end)
  end

  # a fresh marker of the role mapping page carrying the fingerprint of `claims` (what the callback writes)
  defp with_role_marker(conn, claims, opts \\ []) do
    fp = Auth.role_claim_fingerprint(claims)
    fp = if opts[:complete] == false, do: Map.put(fp, "claims_fp_complete", false), else: fp
    marker = T.fresh_marker("admin-1", 0, "auth_time", @role) |> Map.merge(fp)
    put_session(conn, "admin_reauth", marker)
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))
  defp post_role(value, claims, opts \\ []), do: admin_conn(:post, @role, %{"admin_group_claim" => value}) |> with_role_marker(claims, opts) |> T.put_strict_fetch_headers() |> call()

  defp refused_with(conn, text) do
    assert conn.status == 200
    assert conn.resp_body =~ text
    {:ok, doc} = Floki.parse_document(conn.resp_body)
    assert [alert] = Floki.find(doc, ~s(p[role="alert"][data-field="admin_group_claim"]))
    assert Floki.text(alert) =~ text
    assert %{"path" => @role, "sub" => "admin-1", "kind" => "auth_time"} = conn.private.plug_session["admin_reauth"], "a refusal keeps the marker"
    refute_received {:written, :role, _}
    refute_received {:audit, _, _, _, _, _, _, _}
    doc
  end

  # ─── AC6 — which values count: the same as the admin gate ──────────────────

  describe "AC6 / D2 — OidcClaims.string_values_at/2" do
    test "with a path: a string claim, a list, a nested map and a list in a map below the path all count, nothing outside the path" do
      claims = %{
        "groups" => ["ops", "dev"],
        "role" => "solo",
        "realm_access" => %{"roles" => ["r1", "r2"], "other" => "deep"},
        "name" => "Ada",
        "n" => 5,
        "empty" => ""
      }

      assert Enum.sort(OidcClaims.string_values_at(claims, "groups")) == ["dev", "ops"]
      assert OidcClaims.string_values_at(claims, "role") == ["solo"]
      assert Enum.sort(OidcClaims.string_values_at(claims, "realm_access.roles")) == ["r1", "r2"]
      assert Enum.sort(OidcClaims.string_values_at(claims, "realm_access")) == ["deep", "r1", "r2"]
      assert OidcClaims.string_values_at(claims, "missing") == []
      assert OidcClaims.string_values_at(claims, "name.first") == []
      assert OidcClaims.string_values_at(claims, "n") == [], "a non-string leaf is no value"
      assert OidcClaims.string_values_at(claims, "empty") == [], "an empty string is no value"
    end

    test "without a path (nil or empty): every string value of the whole tree (the any-key scan)" do
      claims = %{"groups" => ["ops"], "name" => "Ada", "a" => %{"b" => ["c", %{"d" => "e"}]}, "n" => 1}
      expected = ["Ada", "c", "e", "ops"]
      assert Enum.sort(OidcClaims.string_values_at(claims, nil)) == expected
      assert Enum.sort(OidcClaims.string_values_at(claims, "")) == expected
    end

    test "the values are distinct" do
      assert OidcClaims.string_values_at(%{"g" => ["a", "a", "b"], "h" => "a"}, nil) |> Enum.sort() == ["a", "b"]
    end

    test "a non-map claims value or a non-binary path never raises: no values" do
      assert OidcClaims.string_values_at(nil, "g") == []
      assert OidcClaims.string_values_at(%{"g" => "x"}, 5) == [], "a path that is no string is no path: fail closed"
    end

    test "it is exactly the predicate of the admin gate: membership equals claim_at_path_matches?/3 and claim_value_matches?/2 on every sample" do
      samples = [
        {%{"groups" => ["ops", "x"], "name" => "ops"}, "groups"},
        {%{"groups" => "ops"}, "groups"},
        {%{"realm_access" => %{"roles" => ["ops"]}}, "realm_access.roles"},
        {%{"realm_access" => %{"roles" => [%{"n" => "ops"}]}}, "realm_access"},
        {%{"a" => %{"b" => "ops"}}, "a.c"},
        {%{"groups" => ["Ops"]}, "groups"},
        {%{"groups" => [1, nil, "ops"]}, "groups"}
      ]

      for {claims, path} <- samples, target <- ["ops", "Ops", "x", "nope"] do
        assert target in OidcClaims.string_values_at(claims, path) == OidcClaims.claim_at_path_matches?(claims, path, target), inspect({claims, path, target})
        assert target in OidcClaims.string_values_at(claims, nil) == OidcClaims.claim_value_matches?(claims, target), inspect({claims, target})
      end
    end
  end

  # ─── AC1 / D3 — the fingerprint ───────────────────────────────────────────

  describe "AC1 / D3 — Auth.role_claim_fingerprint/1" do
    test "a configured path: the hash of every value at the path, of nothing else; the values themselves are not in it" do
      with_path("realm_access.roles")
      claims = %{"realm_access" => %{"roles" => ["ops-admins", "dev"]}, "name" => "Ada Lovelace", "groups" => ["other"]}
      fp = Auth.role_claim_fingerprint(claims)

      assert is_binary(fp["claims_fp"]) and rem(byte_size(fp["claims_fp"]), 6) == 0
      assert fp["claims_fp_complete"] == true
      assert hashed?(fp, "ops-admins") and hashed?(fp, "dev")
      refute hashed?(fp, "Ada Lovelace"), "a value outside the path does not count"
      refute hashed?(fp, "other")
      refute fp |> :erlang.term_to_binary() |> String.contains?("ops-admins"), "the cookie is signed, not encrypted: no claim value in it"
    end

    test "no path: the string values of the claims (the any-key scan of the admin gate) EXCEPT the protocol and identity claims (SEC review M-1 / L-1)" do
      claims = %{
        "sub" => "s1", "email" => "ada@example.com", "name" => "Ada", "preferred_username" => "ada", "typ" => "ID", "acr" => "1", "iss" => "https://idp.example",
        "aud" => "nebu", "groups" => ["ops"], "nested" => %{"x" => "y"}
      }

      fp = Auth.role_claim_fingerprint(claims)
      for v <- ["ops", "y"], do: assert(hashed?(fp, v), v)
      for v <- ["s1", "ada@example.com", "Ada", "ada", "ID", "1", "https://idp.example", "nebu"], do: refute(hashed?(fp, v), "#{v} identifies one user or occurs in every token")
      refute hashed?(fp, "nope")
      assert fp["claims_fp_path"] == ""
    end

    test "with a path the fingerprint records it, and a value under a protocol claim counts only when the path points there" do
      with_path("name")
      fp = Auth.role_claim_fingerprint(%{"name" => "Ada"})
      assert hashed?(fp, "Ada")
      assert fp["claims_fp_path"] == "name"
    end

    test "the hash is a 6-byte prefix of SHA-256 over a fixed salt and the value; case sensitive" do
      assert byte_size(Auth.role_claim_hash("ops")) == 6
      assert Auth.role_claim_hash("ops") == binary_part(:crypto.hash(:sha256, "nebu-role-fp:" <> "ops"), 0, 6)
      refute Auth.role_claim_hash("ops") == Auth.role_claim_hash("Ops")
    end

    test "at most 32 distinct values (192 bytes); more are cut off and the fingerprint says so; exactly 32 is complete" do
      with_path("groups")
      exactly = Auth.role_claim_fingerprint(%{"groups" => Enum.map(1..32, &"g#{&1}")})
      assert byte_size(exactly["claims_fp"]) == 32 * 6
      assert exactly["claims_fp_complete"] == true

      more = Auth.role_claim_fingerprint(%{"groups" => Enum.map(1..33, &"g#{&1}")})
      assert byte_size(more["claims_fp"]) == 32 * 6
      assert more["claims_fp_complete"] == false

      dup = Auth.role_claim_fingerprint(%{"groups" => Enum.map(1..100, fn _ -> "same" end)})
      assert byte_size(dup["claims_fp"]) == 6, "duplicates count once"
      assert dup["claims_fp_complete"] == true
    end

    test "the kept part of a cut-off fingerprint is deterministic (the same claims give the same bytes)" do
      with_path("groups")
      claims = %{"groups" => Enum.map(1..90, &"g#{&1}")}
      assert Auth.role_claim_fingerprint(claims) == Auth.role_claim_fingerprint(claims)
    end

    test "claims that are not a map give an empty, complete fingerprint (nothing satisfies it)" do
      assert Auth.role_claim_fingerprint(nil) == %{"claims_fp" => <<>>, "claims_fp_complete" => true, "claims_fp_path" => ""}
    end
  end

  # ─── D4 — the check ───────────────────────────────────────────────────────

  describe "AC2 - AC4 / D4 — Auth.reauth_role_check/2" do
    defp check_conn(marker_fun) do
      admin_conn(:post, @role, %{}) |> then(marker_fun)
    end

    test ":ok when the value is among the hashed values; :not_in_token when the fingerprint is complete and it is not" do
      claims = %{"groups" => ["ops-admins", "dev"]}
      c = check_conn(&with_role_marker(&1, claims))
      assert Auth.reauth_role_check(c, "ops-admins") == :ok
      assert Auth.reauth_role_check(c, "dev") == :ok
      assert Auth.reauth_role_check(c, "ops-admin") == :not_in_token
      assert Auth.reauth_role_check(c, "OPS-ADMINS") == :not_in_token, "exact, case sensitive"
      assert Auth.reauth_role_check(c, "") == :not_in_token
    end

    test ":undecidable when the fingerprint was cut off and the value is not in the kept part; :ok when it is in it" do
      claims = %{"groups" => ["ops-admins"]}
      c = check_conn(&with_role_marker(&1, claims, complete: false))
      assert Auth.reauth_role_check(c, "ops-admins") == :ok
      assert Auth.reauth_role_check(c, "something-else") == :undecidable
    end

    test ":unknown without a fingerprint (a marker of a build without the guard), without a marker, for a marker of another page, another sub, a stale one" do
      claims = %{"groups" => ["ops-admins"]}
      fp = Auth.role_claim_fingerprint(claims)

      plain = check_conn(&put_session(&1, "admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @role)))
      assert Auth.reauth_role_check(plain, "ops-admins") == :unknown

      assert Auth.reauth_role_check(admin_conn(:post, @role, %{}), "ops-admins") == :unknown

      other_page = check_conn(&put_session(&1, "admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @claim) |> Map.merge(fp)))
      assert Auth.reauth_role_check(other_page, "ops-admins") == :unknown

      other_sub = check_conn(&put_session(&1, "admin_reauth", T.fresh_marker("someone-else", 0, "auth_time", @role) |> Map.merge(fp)))
      assert Auth.reauth_role_check(other_sub, "ops-admins") == :unknown

      stale = check_conn(&put_session(&1, "admin_reauth", T.fresh_marker("admin-1", 301, "auth_time", @role) |> Map.merge(fp)))
      assert Auth.reauth_role_check(stale, "ops-admins") == :unknown

      with_path("groups")
      under_path = check_conn(&with_role_marker(&1, claims))
      assert Auth.reauth_role_check(under_path, "ops-admins") == :ok
      with_path("realm_access.roles")
      assert Auth.reauth_role_check(under_path, "ops-admins") == :unknown, "a marker made under another claim path is not trusted"
      with_path(nil)

      junk = check_conn(&put_session(&1, "admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @role) |> Map.merge(%{"claims_fp" => "abc", "claims_fp_complete" => true})))
      assert Auth.reauth_role_check(junk, "ops-admins") == :unknown, "a fingerprint that is not a multiple of 6 bytes is malformed"

      not_bool = check_conn(&put_session(&1, "admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @role) |> Map.merge(%{fp | "claims_fp_complete" => "yes"})))
      assert Auth.reauth_role_check(not_bool, "ops-admins") == :unknown
    end

    test "a non-binary value is :not_in_token, never a raise" do
      c = check_conn(&with_role_marker(&1, %{"groups" => ["a"]}))
      assert Auth.reauth_role_check(c, nil) == :not_in_token
      assert Auth.reauth_role_check(c, ["a"]) == :not_in_token
    end
  end

  # ─── AC2 - AC5 — the form ────────────────────────────────────────────────

  describe "AC2 — a value of the admin's own sign-in is saved as before" do
    test "string claim, list member and nested value: 302, written, audited, the marker consumed" do
      with_path(nil)

      for {value, claims} <- [
            {"ops-admins", %{"groups" => ["ops-admins", "dev"]}},
            {"solo", %{"role" => "solo"}},
            {"deep", %{"a" => %{"b" => [%{"c" => "deep"}]}}}
          ] do
        conn = post_role(value, claims)
        assert conn.status == 302, value
        assert_received {:written, :role, %{"admin_group_claim" => ^value}}
        assert_received {:audit, _, "admin_group_claim_changed", "server_config", "admin_group_claim", %{"admin_group_claim" => ^value}, "success", _}
        assert conn.private.plug_session["admin_reauth"] == nil, "single use: the marker is consumed"
      end
    end

    test "with a truncated fingerprint a value that is in the kept part is saved" do
      conn = post_role("ops-admins", %{"groups" => ["ops-admins"]}, complete: false)
      assert conn.status == 302
      assert_received {:written, :role, %{"admin_group_claim" => "ops-admins"}}
    end
  end

  describe "AC3 — a value the admin does not hold is refused" do
    test "200, nothing written or audited, the marker kept, the message names the sign-in token, the value stays in the field" do
      conn = post_role("ops-adminz", %{"groups" => ["ops-admins"]})
      doc = refused_with(conn, "not in your own sign-in token")
      assert [input] = Floki.find(doc, ~s(input[name="admin_group_claim"]))
      assert Floki.attribute(input, "value") == ["ops-adminz"]
      assert conn.resp_body =~ ~r/lock/i
    end

    test "the refusal names the two ways out (join the group and sign in again; the operator's rpc) and says that other administrators lose access" do
      conn = post_role("not-mine", %{"groups" => ["ops-admins"]})
      {:ok, doc} = Floki.parse_document(conn.resp_body)
      text = doc |> Floki.find(~s(p[data-field="admin_group_claim"])) |> Floki.text() |> String.replace(~r/\s+/, " ")
      assert text =~ ~r/sign in again/i
      assert text =~ ~s|bin/nebu rpc 'IO.inspect(Nebu.Release.reset_admin_group_claim("<value>"))'|, "the command is runnable as shown"
      assert text =~ ~r/other administrators/i
      assert text =~ "Not saved."
      assert [link] = Floki.find(doc, ~s(p[data-field="admin_group_claim"] a))
      assert Floki.attribute(link, "href") == [Auth.reauth_start_path(@role)], "the marker (and with it the old fingerprint) stays for 5 minutes: the way to a fresh one is one click away"
    end

    test "accessibility: the input is described by the claim path line and the error, marked invalid and focused; without an error it is only described by the path line" do
      with_path("groups")
      {:ok, doc} = post_role("typo", %{"groups" => ["ops-admins"]}).resp_body |> Floki.parse_document()
      assert [input] = Floki.find(doc, ~s(input[name="admin_group_claim"]))
      assert Floki.attribute(input, "aria-describedby") == ["admin-claim-path-line admin-group-claim-error"]
      assert Floki.attribute(input, "aria-invalid") == ["true"]
      assert Floki.attribute(input, "autofocus") != []
      assert [_] = Floki.find(doc, "p#admin-group-claim-error[role=alert]")
      assert [_] = Floki.find(doc, "p#admin-claim-path-line")

      {:ok, clean} = admin_conn(:get, @role) |> call() |> Map.fetch!(:resp_body) |> Floki.parse_document()
      assert [input2] = Floki.find(clean, ~s(input[name="admin_group_claim"]))
      assert Floki.attribute(input2, "aria-describedby") == ["admin-claim-path-line"]
      assert Floki.attribute(input2, "aria-invalid") == []
      assert Floki.attribute(input2, "autofocus") == []
    end

    test "after a refusal the SAME session corrects the value without a new sign-in (the marker survived): typo, then the right value" do
      claims = %{"groups" => ["ops-admins"]}
      first = post_role("ops-adminz", claims)
      assert first.status == 200

      second =
        conn(:post, @role)
        |> Map.put(:secret_key_base, @secret_key_base)
        |> recycle_cookies(first)
        |> Map.put(:body_params, %{"admin_group_claim" => "ops-admins"})
        |> Map.put(:params, %{"admin_group_claim" => "ops-admins"})
        |> T.put_strict_fetch_headers()
        |> call()

      assert second.status == 302
      assert_received {:written, :role, %{"admin_group_claim" => "ops-admins"}}
    end

    test "the value is trimmed before the check (a pasted value with blanks is the same group)" do
      conn = post_role("  ops-admins ", %{"groups" => ["ops-admins"]})
      assert conn.status == 302
      assert_received {:written, :role, %{"admin_group_claim" => "ops-admins"}}
    end

    test "case sensitive: Ops-Admins is not ops-admins" do
      refused_with(post_role("Ops-Admins", %{"groups" => ["ops-admins"]}), "not in your own sign-in token")
    end

    test "path scoped: with a configured path a value that exists only under another claim is refused" do
      with_path("realm_access.roles")
      claims = %{"realm_access" => %{"roles" => ["r1"]}, "name" => "ops-admins", "groups" => ["ops-admins"]}
      refused_with(post_role("ops-admins", claims), "not in your own sign-in token")
      assert post_role("r1", claims).status == 302
    end

    test "without a path any string value of the token counts, as in the admin gate, except protocol and identity claims" do
      with_path(nil)
      assert post_role("Team-Ada", %{"department" => "Team-Ada", "groups" => ["x"]}).status == 302
      assert_received {:written, :role, %{"admin_group_claim" => "Team-Ada"}}
      assert_received {:audit, _, "admin_group_claim_changed", _, _, _, _, _}

      for {key, v} <- [{"name", "Ada"}, {"sub", "s-1"}, {"email", "ada@example.com"}, {"typ", "ID"}, {"acr", "1"}, {"preferred_username", "ada"}] do
        refused_with(post_role(v, %{key => v, "groups" => ["x"]}), "not in your own sign-in token")
      end
    end
  end

  describe "AC4 — an unknown or undecidable fingerprint" do
    test "a marker without a fingerprint: 200, the 'did not record' message, nothing written, marker kept" do
      conn = admin_conn(:post, @role, %{"admin_group_claim" => "ops-admins"}) |> put_session("admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @role)) |> T.put_strict_fetch_headers() |> call()
      doc = refused_with(conn, "did not record")
      assert doc |> Floki.find(~s(p[data-field="admin_group_claim"])) |> Floki.text() =~ ~r/sign in again/i
      assert [link] = Floki.find(doc, ~s(p[data-field="admin_group_claim"] a))
      assert Floki.attribute(link, "href") == [Auth.reauth_start_path(@role)]
    end

    test "a cut-off fingerprint without the value: 200, the 'cannot be checked' message naming the 32 values and the rpc" do
      conn = post_role("far-down-the-list", %{"groups" => ["ops-admins"]}, complete: false)
      doc = refused_with(conn, "cannot be checked")
      text = doc |> Floki.find(~s(p[data-field="admin_group_claim"])) |> Floki.text()
      assert text =~ "more than 32 distinct values"
      assert text =~ "reset_admin_group_claim"
      assert Floki.find(doc, ~s(p[data-field="admin_group_claim"] a)) == [], "signing in again would not change the values: no link"
    end
  end

  describe "AC5 — the existing refusals and the gate run first" do
    test "an empty value and a universal value keep their messages and are never checked against the token" do
      conn = post_role("", %{"groups" => ["ops-admins"]})
      refused_with(conn, "must not be empty")

      for v <- ["offline_access", "default-roles-nebu", "openid"], token <- [%{"groups" => [v]}, %{"groups" => ["ops-admins"]}] do
        # whether or not the token holds the value: the universal refusal comes first (never the guard's message)
        conn = post_role(v, token)
        refused_with(conn, "occurs in every sign-in token")
        refute conn.resp_body =~ "not in your own sign-in token"
      end
    end

    test "without strict fetch metadata or without a marker nothing is checked: 403 page / redirect to the sign-in, as before" do
      no_headers = admin_conn(:post, @role, %{"admin_group_claim" => "ops-admins"}) |> with_role_marker(%{"groups" => ["ops-admins"]}) |> call()
      assert no_headers.status == 403
      no_marker = admin_conn(:post, @role, %{"admin_group_claim" => "ops-admins"}) |> T.put_strict_fetch_headers() |> call()
      assert get_resp_header(no_marker, "location") == [Auth.reauth_start_path(@role)]
      refute_received {:written, :role, _}
    end

    test "gate first: a value outside the token without fetch metadata is the 403 page, not the guard's message; without the click proof (Safari) the notice page" do
      typo = %{"admin_group_claim" => "typo"}
      claims = %{"groups" => ["ops-admins"]}

      no_headers = admin_conn(:post, @role, typo) |> with_role_marker(claims) |> call()
      assert no_headers.status == 403
      assert no_headers.resp_body =~ ~s(data-error="fetch_metadata")
      refute no_headers.resp_body =~ "not in your own sign-in token"

      unproven = admin_conn(:post, @role, typo) |> with_role_marker(claims) |> T.put_safari_fetch_headers() |> call()
      assert unproven.resp_body =~ "oauth-activation-unproven"
      refute unproven.resp_body =~ "not in your own sign-in token"
      refute_received {:written, :role, _}
      refute_received {:audit, _, _, _, _, _, _, _}
    end

    test "the claim mapping is not guarded by the fingerprint (it never had one)" do
      Application.put_env(:nebu_http, :admin_config_claim_mapping_writer, fn changes ->
        send(self(), {:written, :claim, changes})
        :ok
      end)
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_config_claim_mapping_writer) end)

      params = %{"oidc_user_id_claim" => "sub", "oidc_displayname_claim" => "name", "oidc_email_claim" => "email"}
      conn = admin_conn(:post, @claim, params) |> put_session("admin_reauth", T.fresh_marker("admin-1", 0, "auth_time", @claim)) |> T.put_strict_fetch_headers() |> call()
      assert conn.status == 302
    end
  end

  # ─── AC7 / D7 — the page ──────────────────────────────────────────────────

  describe "AC7 / D7 — the page" do
    test "it shows the configured claim path read-only, or says that every claim is scanned" do
      with_path("realm_access.roles")
      {:ok, doc} = admin_conn(:get, @role) |> call() |> Map.fetch!(:resp_body) |> Floki.parse_document()
      assert [path] = Floki.find(doc, ~s([data-role="admin-claim-path"]))
      assert Floki.text(path) =~ "realm_access.roles"
      assert Floki.find(doc, ~s(input[name="admin_claim_path"])) == [], "read-only: no field for it"

      with_path(nil)
      {:ok, doc2} = admin_conn(:get, @role) |> call() |> Map.fetch!(:resp_body) |> Floki.parse_document()
      assert [path2] = Floki.find(doc2, ~s([data-role="admin-claim-path"]))
      assert Floki.text(path2) =~ ~r/every claim of the token except protocol and identity claims/i
    end

    test "Auth.configured_admin_claim_path/0 reads the stored path: a string, or nil when none" do
      with_path("realm_access.roles")
      assert Auth.configured_admin_claim_path() == "realm_access.roles"
      with_path(nil)
      assert Auth.configured_admin_claim_path() == nil
    end

    test "the refusal page shows it too; the hint says that the value must be in the token of the person who saves; there is NO override control (D5)" do
      with_path("groups")
      conn = post_role("nope", %{"groups" => ["ops-admins"]})
      {:ok, doc} = Floki.parse_document(conn.resp_body)
      assert [_] = Floki.find(doc, ~s([data-role="admin-claim-path"]))
      text = doc |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ")
      assert text =~ "token of the person who saves"
      assert [form] = Floki.find(doc, "form[action='/admin/config/role-mapping']")
      controls = form |> Floki.find("input:not([type=hidden]), select, textarea") |> Enum.flat_map(&Floki.attribute(&1, "name"))
      assert controls == ["admin_group_claim"], "the only control of the form is the value: no override, no confirmation box"
      refute text =~ ~r/lock (myself|me) out/i
    end
  end

  describe "m1 — the cookie" do
    test "the signed admin session cookie of the reauth response (fingerprint, flash, CSRF token, a ~1 KB refresh token) stays under the 4 KB limit and holds no claim value" do
      with_path("groups")
      values = Enum.map(1..32, &"group-number-#{&1}-of-the-admin")
      marker = T.fresh_marker("admin-1", 0, "auth_time", @role) |> Map.merge(Auth.role_claim_fingerprint(%{"groups" => values}))

      conn =
        admin_conn(:get, @role)
        |> put_session("admin_reauth", marker)
        |> put_session("current_user", %{"admin" => true, "sub" => String.duplicate("s", 40), "email" => "administrator@example.com", "matrix_user_id" => "@administrator:matrix.example.com", "session_exp" => 1_900_000_000, "refresh_grace_exp" => 1_900_003_600})
        |> put_session("admin_oidc_rt", Base.encode64(:crypto.strong_rand_bytes(1500)))
        |> put_session("_csrf_token", Base.url_encode64(:crypto.strong_rand_bytes(16)))
        |> put_session("phoenix_flash", %{"info" => "Signed in again. Nothing is changed yet: enter your change and press Save."})
        |> send_resp(200, "")

      [cookie] = for {"set-cookie", v} <- conn.resp_headers, String.starts_with?(v, "_nebu_admin_key="), do: v
      [pair | _] = String.split(cookie, ";")
      # a 2000-character blob stands for a refresh token of only ~970 bytes (the real store is the hex of nonce + ciphertext + tag, 2 * (n + 28) characters); the fingerprint adds ~260 bytes (32 values): measured 3871 (Delta gate X3-1: a refresh token above ~1.05 KB overflows the 4 KB cookie on the role mapping re-authentication, fail closed)
      assert byte_size(pair) < 4000, "the session cookie is #{byte_size(pair)} bytes (limit 4096, Plug raises above it)"
      [_, signed] = String.split(pair, "=", parts: 2)
      decoded = signed |> String.split(".") |> Enum.at(1, "") |> Base.url_decode64!(padding: false)
      refute decoded =~ "group-number-1-of-the-admin"
    end
  end

  describe "static hygiene" do
    @controller Path.expand("../../../lib/nebu/admin/role_mapping_controller.ex", __DIR__)

    defp code_only(path), do: path |> File.read!() |> String.replace(~r/@moduledoc """.*?"""/s, "") |> String.replace(~r/^\s*#.*$/m, "")

    test "the controller asks Auth.reauth_role_check/2 and does not evaluate claims itself" do
      src = code_only(@controller)
      assert src =~ "Nebu.Admin.Auth.reauth_role_check("
      refute src =~ "claim_at_path_matches?"
      refute src =~ "claim_value_matches?"
    end

    test "the fingerprint is written for the role mapping page only: the callback code names that page next to the fingerprint call" do
      auth = code_only(Path.expand("../../../lib/nebu/admin/auth.ex", __DIR__))
      assert auth =~ ~r/role_claim_fingerprint\(/
      assert auth =~ ~r/"\/admin\/config\/role-mapping"/
    end
  end
end
