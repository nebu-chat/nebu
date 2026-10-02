defmodule Nebu.Matrix.OidcMetadataTest do
  use ExUnit.Case, async: true

  # ─── bugfix-oidc-public-endpoint-urls (architecture v2: honest-issuer, no rewrite) ───
  #
  # Prior cycle 1 attempted to fix the internal-`dex`-hostname leak by REWRITING the
  # fetched discovery document's endpoint URLs from the internal issuer's origin to
  # an operator-configured "public base URL". Code review rejected that design (9
  # MAJOR findings — root cause: rewriting/synthesizing response data to compensate
  # for an internally-addressed IdP is fragile, desyncs `issuer` from the real `iss`
  # token claim, and still left routes unfixed).
  #
  # REPLACEMENT design: the IdP (dev Dex) is configured with its OWN public-reachable
  # issuer (`dev/dex/config.yaml`), made reachable from the compose network too via a
  # Docker Compose network alias (`docker-compose.yml`). Nebu therefore NEVER rewrites
  # a fetched discovery document's origin — every endpoint URL fetched from the
  # upstream IdP is already honest and is passed through byte-for-byte.
  #
  # What's left for `Nebu.Matrix.OidcMetadata` to do: Dex's discovery document
  # genuinely omits 3 MSC2965/RFC 8414 MUST-fields the Matrix Dart SDK parses
  # non-nullable (`registration_endpoint`, `response_modes_supported`,
  # `revocation_endpoint`) — `ensure_msc2965_fields/2` fills ONLY those in, verbatim
  # passthrough for everything else, no origin swapping.
  #
  # M-1 (Kassandra security review 2026-09-02): the synthesis base is the CONFIGURED
  # issuer (2nd argument — a value Nebu itself trusts, from server_config), never the
  # fetched document's own `issuer` field (attacker-influenced network input). Under
  # the honest-issuer design the two are equal on a legitimate response, but using the
  # configured value closes the gap where a compromised/spoofed upstream could steer
  # where these two synthesized endpoints point.

  alias Nebu.Matrix.OidcMetadata

  @issuer "http://dex.localtest.me:5556/dex"

  defp doc(overrides \\ %{}) do
    Map.merge(
      %{
        "issuer" => @issuer,
        "authorization_endpoint" => @issuer <> "/auth",
        "token_endpoint" => @issuer <> "/token",
        "jwks_uri" => @issuer <> "/keys"
      },
      overrides
    )
  end

  defp encode(map), do: Jason.encode!(map)

  describe "ensure_msc2965_fields/2 — synthesizes ONLY the 3 fields Dex omits" do
    test "adds registration_endpoint, response_modes_supported, revocation_endpoint when absent" do
      out = OidcMetadata.ensure_msc2965_fields(encode(doc()), @issuer)
      body = Jason.decode!(out)

      assert is_binary(body["registration_endpoint"])
      assert body["response_modes_supported"] == ["query", "fragment"]
      assert is_binary(body["revocation_endpoint"])
    end

    test "synthesized registration_endpoint/revocation_endpoint reuse the CONFIGURED issuer origin — no invented/hardcoded host" do
      out = OidcMetadata.ensure_msc2965_fields(encode(doc()), @issuer)
      body = Jason.decode!(out)

      assert String.starts_with?(body["registration_endpoint"], "http://dex.localtest.me:5556")
      assert String.starts_with?(body["revocation_endpoint"], "http://dex.localtest.me:5556")
    end

    # MAJOR-1 regression test (code review, redesign cycle 1): synthesis previously
    # stripped the issuer down to scheme+host+port only, discarding the issuer's own
    # path (`/dex`). That produced a registration_endpoint OUTSIDE dex's own mount
    # point. Assert the EXACT synthesized URL (not just an origin prefix) so a future
    # regression to origin-only stripping is caught immediately.
    test "synthesized URLs preserve the configured issuer's own path (dex mounts at /dex)" do
      out = OidcMetadata.ensure_msc2965_fields(encode(doc()), @issuer)
      body = Jason.decode!(out)

      assert body["registration_endpoint"] == "http://dex.localtest.me:5556/dex/clients/register"
      assert body["revocation_endpoint"] == "http://dex.localtest.me:5556/dex/token/revoke"
    end

    # Same regression, but for a Keycloak-style issuer scoped under a realm path —
    # the other real-world IdP shape this fix must handle (see matrix_router_test.exs).
    test "synthesized URLs preserve a Keycloak-style realm path" do
      keycloak_issuer = "https://keycloak.example.com/realms/nebu"

      raw =
        doc(%{
          "issuer" => keycloak_issuer,
          "authorization_endpoint" => keycloak_issuer <> "/protocol/openid-connect/auth",
          "token_endpoint" => keycloak_issuer <> "/protocol/openid-connect/token",
          "jwks_uri" => keycloak_issuer <> "/protocol/openid-connect/certs"
        })
        |> encode()

      body = OidcMetadata.ensure_msc2965_fields(raw, keycloak_issuer) |> Jason.decode!()

      assert body["registration_endpoint"] ==
               "https://keycloak.example.com/realms/nebu/clients/register"

      assert body["revocation_endpoint"] ==
               "https://keycloak.example.com/realms/nebu/token/revoke"
    end

    test "does NOT overwrite a field the upstream document already provides" do
      raw =
        doc(%{
          "registration_endpoint" => "http://dex.localtest.me:5556/dex/register-already-here",
          "response_modes_supported" => ["fragment"],
          "revocation_endpoint" => "http://dex.localtest.me:5556/dex/revoke-already-here"
        })
        |> encode()

      body = OidcMetadata.ensure_msc2965_fields(raw, @issuer) |> Jason.decode!()

      assert body["registration_endpoint"] == "http://dex.localtest.me:5556/dex/register-already-here"
      assert body["response_modes_supported"] == ["fragment"]
      assert body["revocation_endpoint"] == "http://dex.localtest.me:5556/dex/revoke-already-here"
    end
  end

  describe "ensure_msc2965_fields/2 — architecture regression: NO origin rewriting" do
    test "every OTHER field is passed through byte-for-byte, even an internal-looking origin" do
      # This is the explicit regression test for the rejected architecture: even
      # when the document's own fields point at a Docker-internal-looking host,
      # ensure_msc2965_fields/2 must NOT touch them. (In production this scenario
      # should not occur once Dex's own `issuer` is public — this test exists to
      # PROVE the function itself contains no rewriting logic, independent of how
      # Dex happens to be configured.)
      internal_issuer = "http://dex:5556/dex"

      raw =
        doc(%{
          "issuer" => internal_issuer,
          "authorization_endpoint" => internal_issuer <> "/auth",
          "token_endpoint" => internal_issuer <> "/token",
          "jwks_uri" => internal_issuer <> "/keys",
          "userinfo_endpoint" => internal_issuer <> "/userinfo"
        })
        |> encode()

      # Configured issuer matches the document's own issuer here (the legitimate
      # case — this scenario models a deployment that hasn't applied the
      # honest-issuer fix yet, only proving THIS function doesn't rewrite).
      body = OidcMetadata.ensure_msc2965_fields(raw, internal_issuer) |> Jason.decode!()

      assert body["issuer"] == internal_issuer
      assert body["authorization_endpoint"] == internal_issuer <> "/auth"
      assert body["token_endpoint"] == internal_issuer <> "/token"
      assert body["jwks_uri"] == internal_issuer <> "/keys"
      assert body["userinfo_endpoint"] == internal_issuer <> "/userinfo"

      # The synthesized fields fall back to the CONFIGURED issuer origin — proving
      # synthesis reuses the trusted configured value, never a separately
      # rewritten one and never the document's own (here identical) issuer field.
      assert String.starts_with?(body["registration_endpoint"], "http://dex:5556")
      assert String.starts_with?(body["revocation_endpoint"], "http://dex:5556")
    end
  end

  describe "ensure_msc2965_fields/2 — M-1: synthesis trusts the CONFIGURED issuer, never the document's own" do
    test "a document claiming a different issuer than configured does NOT steer synthesized URLs" do
      # Models a compromised/spoofed upstream response (or a misbehaving IdP)
      # whose own `issuer` field disagrees with the issuer Nebu actually queried
      # and trusts. Synthesis must anchor on the CONFIGURED value, not this one.
      attacker_issuer = "https://attacker.example/evil"

      raw =
        doc(%{
          "issuer" => attacker_issuer,
          "authorization_endpoint" => attacker_issuer <> "/auth"
        })
        |> encode()

      body = OidcMetadata.ensure_msc2965_fields(raw, @issuer) |> Jason.decode!()

      # The (unsynthesized, upstream-provided) issuer field itself is still passed
      # through verbatim — this function never rewrites what the document says.
      assert body["issuer"] == attacker_issuer

      # But the fields THIS function fabricates must never point at the
      # attacker-controlled origin — only at the configured, trusted one.
      assert body["registration_endpoint"] == "http://dex.localtest.me:5556/dex/clients/register"
      assert body["revocation_endpoint"] == "http://dex.localtest.me:5556/dex/token/revoke"
      refute String.contains?(body["registration_endpoint"], "attacker.example")
      refute String.contains?(body["revocation_endpoint"], "attacker.example")
    end
  end

  describe "ensure_msc2965_fields/2 — fail-closed on a malformed/missing CONFIGURED issuer" do
    test "missing configured issuer: URL fields are skipped (left absent), not fabricated with a garbage/empty origin" do
      raw = doc() |> encode()

      body = OidcMetadata.ensure_msc2965_fields(raw, nil) |> Jason.decode!()

      refute Map.has_key?(body, "registration_endpoint")
      refute Map.has_key?(body, "revocation_endpoint")
      # response_modes_supported needs no origin — still synthesized.
      assert body["response_modes_supported"] == ["query", "fragment"]
    end

    test "invalid (non-URI) configured issuer: URL fields are skipped rather than emitting an invalid URI" do
      raw = doc() |> encode()

      body = OidcMetadata.ensure_msc2965_fields(raw, "not-a-valid-uri") |> Jason.decode!()

      refute Map.has_key?(body, "registration_endpoint")
      refute Map.has_key?(body, "revocation_endpoint")
      assert body["response_modes_supported"] == ["query", "fragment"]
    end

    test "non-JSON input is returned unchanged (defensive — matches fetch/1's own contract)" do
      raw = "not json at all"
      assert OidcMetadata.ensure_msc2965_fields(raw, @issuer) == raw
    end
  end
end
