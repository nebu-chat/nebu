defmodule Nebu.OAuth.OAuthAuthorizeRequestTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-authorize-idp-delegation-code`, AC3 / AC4 / AC5 /
  D10 / D11 / D13 / D14 / D23: the pure request module `Nebu.OAuth.AuthorizeRequest`.

  ## Contract pinned here (ATDD Decisions (story 2), story file)

      parse_query(query_string) :: {:ok, [{name, value}]} | {:error, :malformed}
        RAW parse (D13): order and duplicates preserved, `x[]` stays the literal name "x[]",
        www-form decoding (`+` => space), a malformed percent-encoding => {:error, :malformed}.

      match_redirect_uri(requested, registered_uris) :: {:ok, requested} | :error      (AC3)

      default_response_mode(redirect_uri) :: "fragment" (https) | "query" (otherwise)  (D10)

      validate(pairs, trusted_redirect_uri) ::
        {:ok, %{response_mode:, code_challenge:, state: binary | nil, nonce: binary | nil,
                scope:, scope_prefix:, device_id:, openid_requested: boolean,
                prompt: "create" | nil}}
        | {:error, error_code :: String.t(), %{state: binary | nil, response_mode: String.t()}}
        Runs ONLY the AC4 checks (client_id / redirect_uri are already trusted by the caller), in
        the AC4 order: response_type, PKCE, response_mode, state, nonce, duplicates, scope, prompt.
        `state` in the error context is the client's state when present AND valid, else nil.
        `response_mode` in the error context is the explicit valid mode, else the default (D10).

      redirect_location(redirect_uri, mode, [{name, value}]) :: String.t()               (AC5)

  Fails today because `Nebu.OAuth.AuthorizeRequest` does not exist.
  Crash/restart — NOT APPLICABLE (pure functions).
  """
  use ExUnit.Case, async: true

  alias Nebu.OAuth.TestSupport, as: T

  @mod Nebu.OAuth.AuthorizeRequest
  defp parse_query(qs), do: apply(@mod, :parse_query, [qs])
  defp match(req, regs), do: apply(@mod, :match_redirect_uri, [req, regs])
  defp default_mode(uri), do: apply(@mod, :default_response_mode, [uri])
  defp validate(pairs, uri), do: apply(@mod, :validate, [pairs, uri])
  defp location(uri, mode, params), do: apply(@mod, :redirect_location, [uri, mode, params])

  @https "https://app.example.com/cb"
  @loop "http://localhost:53682/cb"

  defp req(overrides, uri \\ @https), do: T.authorize_params("cid", uri, overrides)

  # ── D13 raw parsing ────────────────────────────────────────────────────────

  describe "D13 — raw query parsing" do
    test "keeps order and duplicates (conn.query_params would be last-wins)" do
      assert {:ok, [{"a", "1"}, {"b", "2"}, {"a", "3"}]} = parse_query("a=1&b=2&a=3")
    end

    test "array-shaped names stay literal (no list building)" do
      assert {:ok, [{"client_id[]", "x"}]} = parse_query("client_id%5B%5D=x")
      assert {:ok, [{"client_id[]", "x"}]} = parse_query("client_id[]=x")
    end

    test "www-form decoding: + is a space, %20 is a space, %2B is a plus" do
      assert {:ok, [{"scope", "a b c+"}]} = parse_query("scope=a+b%20c%2B")
    end

    test "a malformed percent-encoding is {:error, :malformed}, never a raise" do
      for qs <- ["a=%zz", "a=%", "a=%4", "%zz=1"] do
        assert parse_query(qs) == {:error, :malformed}, inspect(qs)
      end
    end

    test "an empty query yields no pairs" do
      assert {:ok, []} = parse_query("")
    end
  end

  # ── AC3 redirect matching ──────────────────────────────────────────────────

  describe "AC3 — exact redirect URI matching (no normalization)" do
    test "byte-for-byte equality with one registered entry" do
      regs = ["https://a.example.com/cb", "com.example.app:/oauth2/callback"]
      assert match("https://a.example.com/cb", regs) == {:ok, "https://a.example.com/cb"}
      assert match("com.example.app:/oauth2/callback", regs) == {:ok, "com.example.app:/oauth2/callback"}
    end

    test "case, trailing slash, default port, percent-encoding, query and fragment all count" do
      regs = ["https://a.example.com/cb"]

      for bad <- [
            "https://A.example.com/cb",
            "https://a.example.com/CB",
            "https://a.example.com/cb/",
            "https://a.example.com:443/cb",
            "https://a.example.com/%63b",
            "https://a.example.com/cb?x=1",
            "https://a.example.com/cb#f",
            "http://a.example.com/cb",
            "https://a.example.com/cb ",
            ""
          ] do
        assert match(bad, regs) == :error, "#{inspect(bad)} must not match"
      end
    end

    test "a non-loopback registered URI never matches with an extra port" do
      assert match("https://a.example.com:8443/cb", ["https://a.example.com/cb"]) == :error
      assert match("http://example.com:8080/cb", ["http://example.com/cb"]) == :error
    end
  end

  describe "AC3 — loopback port exception (RFC 8252 7.3)" do
    test "any port 1..65535 is accepted for http://localhost, 127.0.0.1 and [::1]; the requested URI is returned" do
      assert match("http://localhost:53682/cb", ["http://localhost/cb"]) == {:ok, "http://localhost:53682/cb"}
      assert match("http://localhost:1/cb", ["http://localhost/cb"]) == {:ok, "http://localhost:1/cb"}
      assert match("http://localhost:65535/cb", ["http://localhost/cb"]) == {:ok, "http://localhost:65535/cb"}
      assert match("http://127.0.0.1:8080/cb", ["http://127.0.0.1/cb"]) == {:ok, "http://127.0.0.1:8080/cb"}
      assert match("http://[::1]:8080/cb", ["http://[::1]/cb"]) == {:ok, "http://[::1]:8080/cb"}
      assert match("http://localhost:8080", ["http://localhost"]) == {:ok, "http://localhost:8080"}
      assert match("http://localhost:8080?x=1", ["http://localhost?x=1"]) == {:ok, "http://localhost:8080?x=1"}
    end

    test "the portless registered URI itself still matches" do
      assert match("http://localhost/cb", ["http://localhost/cb"]) == {:ok, "http://localhost/cb"}
    end

    test "ports 0, 65536, +80, -1, empty, non-decimal are rejected" do
      for bad <- [":0", ":65536", ":+80", ":-1", ":", ":80a", ":0x50", ":99999999999"] do
        assert match("http://localhost#{bad}/cb", ["http://localhost/cb"]) == :error, "port #{bad}"
      end
    end

    test "localhost and 127.0.0.1 are NOT interchangeable (both directions), nor [::1]" do
      assert match("http://127.0.0.1:8080/cb", ["http://localhost/cb"]) == :error
      assert match("http://localhost:8080/cb", ["http://127.0.0.1/cb"]) == :error
      assert match("http://[::1]:8080/cb", ["http://localhost/cb"]) == :error
    end

    test "the rest of the URI must stay identical; host tricks never match" do
      regs = ["http://localhost/cb"]

      for bad <- [
            "http://localhost:8080/cb/",
            "http://localhost:8080/other",
            "http://localhost.evil.com/cb",
            "http://localhost.evil.com:8080/cb",
            "http://localhost:80@evil.com/cb",
            "http://user@localhost:8080/cb",
            "https://localhost:8080/cb",
            "http://LOCALHOST:8080/cb"
          ] do
        assert match(bad, regs) == :error, "#{inspect(bad)} must not match"
      end
    end

    test "a registered loopback URI WITH a port only matches exactly" do
      assert match("http://localhost:3000/cb", ["http://localhost:3000/cb"]) == {:ok, "http://localhost:3000/cb"}
      assert match("http://localhost:4000/cb", ["http://localhost:3000/cb"]) == :error
    end
  end

  # ── D10 default response mode ──────────────────────────────────────────────

  describe "D10 — default response mode" do
    test "https => fragment; loopback http and private-use schemes => query" do
      assert default_mode("https://app.example.com/cb") == "fragment"
      assert default_mode("http://localhost:53682/cb") == "query"
      assert default_mode("http://127.0.0.1:8080/cb") == "query"
      assert default_mode("com.example.app:/oauth2/callback") == "query"
    end
  end

  # ── AC4 validation + error table ───────────────────────────────────────────

  describe "AC4 — a fully valid request" do
    test "returns the validated fields (stable prefix, no nonce/openid)" do
      pairs = req(%{})
      assert {:ok, v} = validate(pairs, @https)
      assert v.response_mode == "fragment"
      assert v.code_challenge == T.param(pairs, "code_challenge")
      assert v.state == T.param(pairs, "state")
      assert v.nonce == nil
      assert v.scope == "urn:matrix:client:api:* urn:matrix:client:device:AbCdEfGhIj"
      assert v.scope_prefix == "urn:matrix:client:"
      assert v.device_id == "AbCdEfGhIj"
      assert v.openid_requested == false
    end

    test "js-sdk 41.3.0 shape: openid + unstable prefix + nonce + response_mode=query on https (D10/D23)" do
      pairs = req(%{"scope" => T.js_sdk_scope(), "nonce" => "client-nonce-123", "response_mode" => "query"})
      assert {:ok, v} = validate(pairs, @https)
      assert v.response_mode == "query", "an explicit query is honoured for an https redirect URI"
      assert v.nonce == "client-nonce-123"
      assert v.openid_requested == true
      assert v.scope == T.js_sdk_scope()
      assert v.scope_prefix == "urn:matrix:org.matrix.msc2967.client:"
    end

    test "absent state => state nil (optional, RFC 6749 RECOMMENDED)" do
      assert {:ok, %{state: nil}} = validate(req(%{"state" => nil}), @https)
    end

    test "explicit fragment honoured for loopback; absent mode => query for loopback" do
      assert {:ok, %{response_mode: "fragment"}} = validate(req(%{"response_mode" => "fragment"}, @loop), @loop)
      assert {:ok, %{response_mode: "query"}} = validate(req(%{}, @loop), @loop)
    end

    test "unknown parameters are ignored (action, login_hint, max_age, ui_locales, claims, request, request_uri)" do
      extra = %{
        "action" => "register",
        "login_hint" => "x",
        "max_age" => "0",
        "ui_locales" => "de",
        "claims" => "{}",
        "request" => "eyJ",
        "request_uri" => "https://evil.example.com/r"
      }

      assert {:ok, _} = validate(req(extra), @https)
    end

    test "prompt=create is carried; other single prompt values are ignored" do
      assert {:ok, %{prompt: "create"}} = validate(req(%{"prompt" => "create"}), @https)
      assert {:ok, %{prompt: nil}} = validate(req(%{"prompt" => "login"}), @https)
      assert {:ok, %{prompt: nil}} = validate(req(%{"prompt" => "consent"}), @https)
    end
  end

  defp err(pairs, uri \\ @https), do: validate(pairs, uri)

  describe "AC4 — error table (first failure wins)" do
    test "response_type missing => invalid_request; other value => unsupported_response_type" do
      assert {:error, "invalid_request", _} = err(req(%{"response_type" => nil}))

      for rt <- ["token", "code id_token", "id_token", "CODE", "code "] do
        assert {:error, "unsupported_response_type", _} = err(req(%{"response_type" => rt})), "response_type=#{inspect(rt)}"
      end
    end

    test "PKCE: missing challenge, missing method, plain, malformed challenge => invalid_request" do
      {_v, good} = T.pkce_pair()

      for o <- [
            %{"code_challenge" => nil},
            %{"code_challenge_method" => nil},
            %{"code_challenge_method" => "plain"},
            %{"code_challenge_method" => "s256"},
            %{"code_challenge" => String.slice(good, 0, 42)},
            %{"code_challenge" => good <> "A"},
            %{"code_challenge" => String.duplicate("A", 64)},
            %{"code_challenge" => String.duplicate("A", 128)},
            %{"code_challenge" => String.slice(good, 0, 42) <> "+"},
            %{"code_challenge" => String.slice(good, 0, 42) <> "="}
          ] do
        assert {:error, "invalid_request", _} = err(req(o)), "PKCE override #{inspect(o)}"
      end
    end

    test "code_challenge of exactly 43 chars of [A-Za-z0-9_-] passes" do
      assert {:ok, _} = err(req(%{"code_challenge" => String.duplicate("a", 21) <> "_-" <> String.duplicate("Z", 20)}))
    end

    test "response_mode other than query/fragment => invalid_request in the redirect URI's DEFAULT mode" do
      for m <- ["form_post", "query.jwt", "fragment.jwt", "jwt", "QUERY", ""] do
        assert {:error, "invalid_request", %{response_mode: "fragment"}} = err(req(%{"response_mode" => m})), m
        assert {:error, "invalid_request", %{response_mode: "query"}} = err(req(%{"response_mode" => m}, @loop), @loop)
      end
    end

    test "an error after a valid explicit response_mode uses that mode" do
      assert {:error, "invalid_scope", %{response_mode: "query"}} =
               err(req(%{"response_mode" => "query", "scope" => "openid"}))

      assert {:error, "invalid_scope", %{response_mode: "fragment"}} =
               err(req(%{"response_mode" => "fragment", "scope" => "openid"}, @loop), @loop)
    end

    test "state: > 2048 bytes, invalid UTF-8, control characters => invalid_request WITHOUT echoing the state" do
      for s <- [String.duplicate("s", 2049), <<0xFF, 0xFE>>, "a\x00b", "line\nbreak", "tab\t", "del\x7F"] do
        assert {:error, "invalid_request", %{state: nil}} = err(req(%{"state" => s})), inspect(s)
      end
    end

    test "state of exactly 2048 bytes and non-ASCII UTF-8 are valid and echoed in later errors" do
      long = String.duplicate("s", 2048)
      assert {:error, "invalid_scope", %{state: ^long}} = err(req(%{"state" => long, "scope" => "openid"}))
      assert {:error, "invalid_scope", %{state: "zustand-äöü"}} = err(req(%{"state" => "zustand-äöü", "scope" => "x"}))
    end

    test "client nonce validated like state (D23): too long / invalid UTF-8 / control chars => invalid_request" do
      for n <- [String.duplicate("n", 2049), <<0xC3>>, "a\x00b", "a\rb"] do
        assert {:error, "invalid_request", _} = err(req(%{"nonce" => n})), inspect(n)
      end

      assert {:ok, %{nonce: n}} = err(req(%{"nonce" => String.duplicate("n", 2048)}))
      assert byte_size(n) == 2048
    end

    test "duplicated parameters other than client_id/redirect_uri => invalid_request" do
      base = req(%{"nonce" => "n1", "response_mode" => "query", "prompt" => "login", "action" => "login"})

      for name <- ~w(scope response_type code_challenge code_challenge_method nonce response_mode prompt action) do
        assert {:error, "invalid_request", _} = err(base ++ [{name, T.param(base, name)}]), "duplicated #{name}"
      end
    end

    test "duplicated state => invalid_request" do
      base = req(%{"state" => "s1"})
      assert {:error, "invalid_request", _} = err(base ++ [{"state", "s1"}])
    end

    test "scope errors => invalid_scope (missing, mixed prefixes, 0/2 devices, no api:*)" do
      for s <- [
            nil,
            "",
            "openid",
            T.stable_prefix() <> "api:* " <> T.unstable_prefix() <> "device:X",
            T.stable_prefix() <> "api:*",
            T.matrix_scope() <> " " <> T.stable_prefix() <> "device:Y",
            T.stable_prefix() <> "device:X"
          ] do
        assert {:error, "invalid_scope", _} = err(req(%{"scope" => s})), inspect(s)
      end
    end

    test "prompt=none => login_required; prompt list combining none => invalid_request" do
      assert {:error, "login_required", %{state: st}} = err(req(%{"prompt" => "none", "state" => "st-1"}))
      assert st == "st-1"
      assert {:error, "invalid_request", _} = err(req(%{"prompt" => "none login"}))
      assert {:error, "invalid_request", _} = err(req(%{"prompt" => "create none"}))
    end

    test "order: response_type before PKCE before response_mode before state before nonce before scope before prompt" do
      assert {:error, "unsupported_response_type", _} =
               err(req(%{"response_type" => "token", "code_challenge" => nil, "scope" => "x", "prompt" => "none"}))

      assert {:error, "invalid_request", %{response_mode: "query"}} =
               err(req(%{"code_challenge" => nil, "response_mode" => "query", "scope" => "x"}))

      # invalid response_mode beats an invalid scope; the error uses the default mode
      assert {:error, "invalid_request", %{response_mode: "fragment"}} =
               err(req(%{"response_mode" => "form_post", "scope" => "x"}))

      # invalid state beats an invalid scope (and is not echoed)
      assert {:error, "invalid_request", %{state: nil}} = err(req(%{"state" => "a\x00", "scope" => "x"}))

      # invalid scope beats prompt=none
      assert {:error, "invalid_scope", _} = err(req(%{"scope" => "x", "prompt" => "none"}))
    end

    test "the error context carries the valid client state" do
      assert {:error, "invalid_request", %{state: "keep-me"}} =
               err(req(%{"state" => "keep-me", "code_challenge" => nil}))
    end
  end

  # ── AC5 redirect building ──────────────────────────────────────────────────

  describe "AC5 — redirect_location/3" do
    test "query mode appends with ? (or & when the URI already has a query) and www-form-encodes values" do
      assert location("http://localhost:53682/cb", "query", [{"code", "a b"}, {"state", "s&t"}, {"iss", "https://n.example"}]) ==
               "http://localhost:53682/cb?code=a+b&state=s%26t&iss=https%3A%2F%2Fn.example"

      assert location("https://a.example.com/cb?x=1", "query", [{"error", "access_denied"}]) ==
               "https://a.example.com/cb?x=1&error=access_denied"
    end

    test "fragment mode appends #<encoded params>" do
      assert location("https://a.example.com/cb", "fragment", [{"code", "c"}, {"state", "é"}, {"iss", "https://n"}]) ==
               "https://a.example.com/cb#code=c&state=%C3%A9&iss=https%3A%2F%2Fn"
    end
  end
end
