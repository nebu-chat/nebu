defmodule Nebu.Web.OidcClaimsTest do
  @moduledoc """
  RED-phase ATDD test for the `centralize-claim-resolution` story (epic
  oidc-simplification) — AC1.

  AC1: a new module `Nebu.Web.OidcClaims` (file: `server/lib/nebu/web/oidc_claims.ex`)
  must expose, with signatures preserved from their current (private) equivalents in
  `Nebu.Admin.Auth` (server/lib/nebu/admin/auth.ex:1108-1134 and :1504-1536):

    * `claim_value_matches?(target, value) :: boolean()` — recursive value matcher,
      arbitrary depth.
    * `flatten_discovered_claims(claims, prefix) :: [{dot_path_key, value}]` — used by
      the Bootstrap Wizard's claim-picker (`extract_discovered_claims/1` in
      `Nebu.Admin.Auth`).

  This is a pure-refactor story: NO behavior change is allowed anywhere. The cases
  below mirror the nested-claim (Keycloak-shaped) coverage already proven for the
  *current* private implementations by `admin_oidc_login_test.exs` (via the public
  `Nebu.Admin.Auth.admin_claim?/1` / `extract_discovered_claims/1` wrappers), so that
  once dev-story extracts the logic into this module and wires up delegation, both the
  new unit tests here AND the existing admin-level tests keep passing unchanged
  (AC2 — verified elsewhere, not in this file).

  `Nebu.Web.OidcClaims` DOES NOT EXIST YET, so every test in this file MUST FAIL with
  an `UndefinedFunctionError` (`Nebu.Web.OidcClaims.claim_value_matches?/2 is
  undefined` / `.flatten_discovered_claims/2 is undefined`) until the dev phase
  creates the module. Do not implement the module to make this file pass.

  ## AC3 note (recursion-depth-limit justification comment)

  AC3 requires the existing "no recursion depth limit" justification comment (signed
  token = trust boundary; recursion depth is bounded by the JSON structure of a
  trusted, signature-verified IdP token, not by adversarial input) to survive the
  move into the new file as a code comment. That is a code-review-time / diff-time
  check on `oidc_claims.ex`, not something an ExUnit assertion can observe at runtime
  (Elixir strips comments before compilation). The "deep nesting doesn't blow the
  stack" test below is only a *behavioral proxy* for "no artificial depth limit was
  added" — it does not verify the comment itself. The comment's presence must be
  confirmed by reading the diff during dev/test-review, not by this suite.
  """
  use ExUnit.Case, async: true

  alias Nebu.Web.OidcClaims

  describe "AC1 — claim_value_matches?/2 — flat match" do
    test "matches when target equals a bare top-level string value" do
      assert OidcClaims.claim_value_matches?(%{"role" => "instance_admin"}, "instance_admin")
    end

    test "does not match when the target string is absent" do
      refute OidcClaims.claim_value_matches?(%{"role" => "user"}, "instance_admin")
    end

    test "matches the target itself when called directly with two identical binaries" do
      assert OidcClaims.claim_value_matches?("instance_admin", "instance_admin")
    end
  end

  describe "AC1 — claim_value_matches?/2 — list match (flat Dex-style claims)" do
    test "matches when target is a member of a top-level list claim" do
      assert OidcClaims.claim_value_matches?(%{"groups" => ["instance_admin"]}, "instance_admin")
    end

    test "does not match when target is absent from the list" do
      refute OidcClaims.claim_value_matches?(%{"groups" => ["users"]}, "instance_admin")
    end

    test "matches a bare list directly (target in list)" do
      assert OidcClaims.claim_value_matches?(["instance_admin", "offline_access"], "instance_admin")
    end

    test "does not match a bare list without the target" do
      refute OidcClaims.claim_value_matches?(["offline_access"], "instance_admin")
    end
  end

  describe "AC1 — claim_value_matches?/2 — nested map match (arbitrary depth, Keycloak-shaped)" do
    test "matches via realm_access.roles (one level of nesting)" do
      claims = %{
        "sub" => "kai",
        "realm_access" => %{"roles" => ["instance_admin", "offline_access"]}
      }

      assert OidcClaims.claim_value_matches?(claims, "instance_admin")
    end

    test "matches via resource_access.<client>.roles (two levels of nesting)" do
      claims = %{
        "sub" => "kai",
        "realm_access" => %{"roles" => ["offline_access"]},
        "resource_access" => %{"nebu-admin" => %{"roles" => ["instance_admin"]}}
      }

      assert OidcClaims.claim_value_matches?(claims, "instance_admin")
    end

    test "does not match a Keycloak-shaped token without the marker anywhere" do
      claims = %{
        "sub" => "alex",
        "realm_access" => %{"roles" => ["offline_access"]},
        "resource_access" => %{"nebu-admin" => %{"roles" => ["uma_authorization"]}}
      }

      refute OidcClaims.claim_value_matches?(claims, "instance_admin")
    end

    test "matches a nested bare string claim (e.g. profile.custom_role), any depth" do
      claims = %{"sub" => "alex", "profile" => %{"custom_role" => "instance_admin"}}

      assert OidcClaims.claim_value_matches?(claims, "instance_admin")
    end
  end

  describe "AC1 — claim_value_matches?/2 — list-of-maps match" do
    test "matches when the target is nested inside a map that is itself a list element" do
      claims = %{
        "entitlements" => [
          %{"role" => "viewer"},
          %{"role" => "instance_admin"}
        ]
      }

      assert OidcClaims.claim_value_matches?(claims, "instance_admin")
    end

    test "does not match when no list element contains the target" do
      claims = %{
        "entitlements" => [
          %{"role" => "viewer"},
          %{"role" => "editor"}
        ]
      }

      refute OidcClaims.claim_value_matches?(claims, "instance_admin")
    end
  end

  describe "AC1 — claim_value_matches?/2 — edge cases" do
    test "empty map never matches" do
      refute OidcClaims.claim_value_matches?(%{}, "instance_admin")
    end

    test "empty list never matches" do
      refute OidcClaims.claim_value_matches?([], "instance_admin")
    end

    test "non-binary scalar values never match (integers, booleans, nil, atoms)" do
      refute OidcClaims.claim_value_matches?(%{"exp" => 1_735_689_600}, "instance_admin")
      refute OidcClaims.claim_value_matches?(%{"active" => true}, "instance_admin")
      refute OidcClaims.claim_value_matches?(%{"nickname" => nil}, "instance_admin")
      refute OidcClaims.claim_value_matches?(42, "instance_admin")
      refute OidcClaims.claim_value_matches?(nil, "instance_admin")
      refute OidcClaims.claim_value_matches?(:some_atom, "instance_admin")
    end

    test "still matches flat Dex-style groups claims (backward compatibility)" do
      assert OidcClaims.claim_value_matches?(%{"sub" => "kai", "groups" => ["instance_admin"]}, "instance_admin")
      refute OidcClaims.claim_value_matches?(%{"sub" => "alex", "groups" => ["users"]}, "instance_admin")
    end

    test "still matches a bare top-level string claim (backward compatibility)" do
      assert OidcClaims.claim_value_matches?(%{"sub" => "kai", "role" => "instance_admin"}, "instance_admin")
      refute OidcClaims.claim_value_matches?(%{"sub" => "alex", "role" => "user"}, "instance_admin")
    end
  end

  describe "AC1 — flatten_discovered_claims/2 — flat claims (bare key)" do
    test "a flat non-empty string claim keeps its original bare key with nil prefix" do
      assert OidcClaims.flatten_discovered_claims(%{"sub" => "kai"}, nil) == [{"sub", "kai"}]
    end

    test "multiple flat string claims each keep their own bare key" do
      result = OidcClaims.flatten_discovered_claims(%{"sub" => "kai", "role" => "instance_admin"}, nil)

      assert {"sub", "kai"} in result
      assert {"role", "instance_admin"} in result
      assert length(result) == 2
    end
  end

  describe "AC1 — flatten_discovered_claims/2 — nested map claims (dot-path key)" do
    test "one level of nesting produces a dot-path key (realm_access.roles)" do
      claims = %{"realm_access" => %{"roles" => ["instance_admin", "offline_access"]}}

      result = OidcClaims.flatten_discovered_claims(claims, nil)

      assert {"realm_access.roles", "instance_admin"} in result
      assert {"realm_access.roles", "offline_access"} in result
    end

    test "two levels of nesting produce a two-segment dot-path key (resource_access.<client>.roles)" do
      claims = %{"resource_access" => %{"nebu-admin" => %{"roles" => ["instance_admin"]}}}

      result = OidcClaims.flatten_discovered_claims(claims, nil)

      assert {"resource_access.nebu-admin.roles", "instance_admin"} in result
    end

    test "mixed flat and nested claims: flat keeps bare key, nested gets dot-path" do
      claims = %{
        "sub" => "kai",
        "realm_access" => %{"roles" => ["instance_admin", "offline_access"]}
      }

      result = OidcClaims.flatten_discovered_claims(claims, nil)

      assert {"sub", "kai"} in result
      assert {"realm_access.roles", "instance_admin"} in result
      assert {"realm_access.roles", "offline_access"} in result
    end

    test "a non-nil prefix is prepended to the key with a dot" do
      assert OidcClaims.flatten_discovered_claims(%{"roles" => ["instance_admin"]}, "realm_access") ==
               [{"realm_access.roles", "instance_admin"}]
    end
  end

  describe "AC1 — flatten_discovered_claims/2 — list-of-strings claims" do
    test "a bare list of strings is flattened, each keeping the given prefix as key" do
      result = OidcClaims.flatten_discovered_claims(["instance_admin", "offline_access"], "groups")

      assert {"groups", "instance_admin"} in result
      assert {"groups", "offline_access"} in result
      assert length(result) == 2
    end

    test "a list under a nil prefix keeps a nil key" do
      assert OidcClaims.flatten_discovered_claims(["a", "b"], nil) == [{nil, "a"}, {nil, "b"}]
    end
  end

  describe "AC1 — flatten_discovered_claims/2 — empty-string values excluded" do
    test "an empty-string claim value is dropped" do
      assert OidcClaims.flatten_discovered_claims(%{"nickname" => ""}, nil) == []
    end

    test "empty strings inside a list are dropped while non-empty ones survive" do
      result = OidcClaims.flatten_discovered_claims(["instance_admin", ""], "groups")

      assert result == [{"groups", "instance_admin"}]
    end
  end

  describe "AC1 — flatten_discovered_claims/2 — non-matching / empty-container edge cases" do
    test "an empty map yields no entries" do
      assert OidcClaims.flatten_discovered_claims(%{}, nil) == []
    end

    test "an empty list yields no entries" do
      assert OidcClaims.flatten_discovered_claims([], nil) == []
    end

    test "non-binary, non-map, non-list scalars (numbers, booleans, nil) yield no entries" do
      assert OidcClaims.flatten_discovered_claims(42, "exp") == []
      assert OidcClaims.flatten_discovered_claims(true, "active") == []
      assert OidcClaims.flatten_discovered_claims(nil, "nickname") == []
    end
  end

  describe "AC1 — flatten_discovered_claims/2 — de-dup behavior via the caller pattern" do
    test "duplicate {key, value} pairs across separate claim branches survive flatten (caller dedupes)" do
      # extract_discovered_claims/1 in Nebu.Admin.Auth pipes this function's output
      # through Enum.uniq/1. flatten_discovered_claims/2 itself must NOT dedupe on
      # its own -- deduping is the caller's job -- so duplicate pairs are preserved
      # here and only collapse when the caller applies Enum.uniq/1.
      claims = %{
        "groups" => ["instance_admin"],
        "realm_access" => %{"roles" => ["instance_admin"]}
      }

      result = OidcClaims.flatten_discovered_claims(claims, nil)

      # Two distinct dot-paths ("groups" and "realm_access.roles") both carry the
      # same value "instance_admin" -- these are NOT duplicate pairs (keys differ),
      # so both must be present pre-dedup.
      assert {"groups", "instance_admin"} in result
      assert {"realm_access.roles", "instance_admin"} in result

      # Enum.uniq/1 (the caller's responsibility, per extract_discovered_claims/1)
      # would not collapse these since the pairs differ by key.
      assert length(Enum.uniq(result)) == length(result)
    end
  end

  describe "claim_at_path_matches?/3 — story scope-admin-claim-to-path (AC3)" do
    test "matches when target is present at the exact flat path" do
      assert OidcClaims.claim_at_path_matches?(%{"groups" => ["instance_admin"]}, "groups", "instance_admin")
    end

    test "does not match when target is absent from the value at the path" do
      refute OidcClaims.claim_at_path_matches?(%{"groups" => ["users"]}, "groups", "instance_admin")
    end

    test "matches a nested dot-path (realm_access.roles)" do
      claims = %{"realm_access" => %{"roles" => ["instance_admin", "offline_access"]}}

      assert OidcClaims.claim_at_path_matches?(claims, "realm_access.roles", "instance_admin")
    end

    test "matches a two-segment nested dot-path (resource_access.<client>.roles)" do
      claims = %{"resource_access" => %{"nebu-admin" => %{"roles" => ["instance_admin"]}}}

      assert OidcClaims.claim_at_path_matches?(claims, "resource_access.nebu-admin.roles", "instance_admin")
    end

    test "does NOT match when the target appears elsewhere in the tree but not at the configured path (the security fix)" do
      claims = %{"groups" => ["user"], "name" => "instance_admin"}

      refute OidcClaims.claim_at_path_matches?(claims, "groups", "instance_admin")
    end

    test "does not match when the path does not resolve (missing intermediate segment)" do
      claims = %{"realm_access" => %{"roles" => ["instance_admin"]}}

      refute OidcClaims.claim_at_path_matches?(claims, "resource_access.nebu-admin.roles", "instance_admin")
    end

    test "does not match when path traverses through a non-map (e.g. a list)" do
      claims = %{"groups" => ["instance_admin"]}

      refute OidcClaims.claim_at_path_matches?(claims, "groups.nested", "instance_admin")
    end

    test "fails closed on a nil path" do
      refute OidcClaims.claim_at_path_matches?(%{"groups" => ["instance_admin"]}, nil, "instance_admin")
    end

    test "fails closed on an empty-string path" do
      refute OidcClaims.claim_at_path_matches?(%{"groups" => ["instance_admin"]}, "", "instance_admin")
    end

    test "matches a bare top-level string claim at its own path" do
      assert OidcClaims.claim_at_path_matches?(%{"role" => "instance_admin"}, "role", "instance_admin")
    end
  end

  describe "AC3 proxy — deep nesting does not blow the stack (no artificial depth limit)" do
    test "claim_value_matches?/2 finds a deeply nested target many levels down" do
      depth = 200

      deeply_nested =
        Enum.reduce(1..depth, "instance_admin", fn i, acc -> %{"level#{i}" => acc} end)

      assert OidcClaims.claim_value_matches?(deeply_nested, "instance_admin")
    end

    test "flatten_discovered_claims/2 flattens a deeply nested claims map without crashing" do
      depth = 200

      deeply_nested =
        Enum.reduce(1..depth, "instance_admin", fn i, acc -> %{"level#{i}" => acc} end)

      result = OidcClaims.flatten_discovered_claims(deeply_nested, nil)

      assert [{key, "instance_admin"}] = result
      assert key =~ "level"
    end
  end
end
