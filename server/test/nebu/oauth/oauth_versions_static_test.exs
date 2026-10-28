defmodule Nebu.OAuth.OAuthVersionsStaticTest do
  @moduledoc """
  Static acceptance tests for story `oauth-versions-switch` (story 9 of epic oauth-broker),
  AC4 (V2) and V1/V5 (Must #5, #19), no DB:

    * `Metadata.normalize_issuer(` is called only in `config.ex` (`live_state/0`) and `metadata.ex`
      (`Authorize.live_issuer/0` and `Http.auth_issuer/1` delegate to `Config.live_state/0`);
    * no file under `lib/nebu/matrix/` or `lib/nebu/web/` names `Nebu.OAuth.Config` / `Nebu.OAuth.Metadata`
      (the router's `forward ... to: Nebu.OAuth.Http` lines are the allowed edge);
    * the version lists live only in `http_public.ex` (exactly one on- and one off-list); `router.ex`
      holds no version literal and calls `Nebu.Matrix.HttpPublic.versions(`;
    * no OAuth MSC key literal for `unstable_features` in `lib/`; no cache in the predicate path.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  # Strips @moduledoc / @doc heredocs (prose may mention "v1.15" or normalize_issuer) and FULL-LINE
  # comments only: a blanket `#...` strip would also cut `#{...}` string interpolations and hide code.
  defp code(path) do
    path
    |> File.read!()
    |> String.replace(~r/@(module)?doc\s+~?[sS]?"""[\s\S]*?"""/, "")
    |> String.replace(~r/^\s*#[^\n]*$/m, "")
  end
  defp rel(path), do: Path.relative_to(path, @lib)
  defp lib_files, do: Path.wildcard(Path.join(@lib, "**/*.ex"))

  # Story admin-oauth-switch (AS3, AS10): the Admin UI form validates the issuer the admin types with the SAME function, reached through the
  # facade (`Nebu.OAuth.normalize_issuer/1`, a delegate, ADR-020): `oauth.ex` (the delegate), `oauth/switch_store.ex` (defence in depth
  # before persisting) and `admin/oauth_switch.ex` (the form validation and the status list) and `release.ex` (the operator's `disable_oauth/0` keeps a valid stored issuer). They validate INPUT; the liveness predicate
  # (V2: one predicate, one place) stays in `Config.live_state/1`.
  test "Must #19: normalize_issuer( is called only in config.ex and metadata.ex (the liveness predicate) and by the input validators of the Admin UI switch" do
    callers =
      lib_files()
      |> Enum.filter(&(code(&1) =~ "normalize_issuer("))
      |> Enum.map(&rel/1)
      |> Enum.sort()

    assert callers == ["nebu/admin/oauth_switch.ex", "nebu/oauth.ex", "nebu/oauth/config.ex", "nebu/oauth/metadata.ex", "nebu/oauth/switch_store.ex", "nebu/release.ex"],
           "callers: #{inspect(callers)} (V2: one predicate, one place)"
  end

  test "Must #19: Authorize.live_issuer/0 and Http.auth_issuer delegate to Config.live_state/0" do
    authorize = code(Path.join(@lib, "nebu/oauth/authorize.ex"))
    [_, live] = String.split(authorize, ~r/def\s+live_issuer/, parts: 2)
    assert live |> String.split(~r/\n  def/, parts: 2) |> hd() =~ "live_state()"

    http = code(Path.join(@lib, "nebu/oauth/http.ex"))
    [_, ai] = String.split(http, ~r/defp\s+auth_issuer\(/, parts: 2)
    assert ai |> String.split(~r/\n  defp?\s/, parts: 2) |> hd() =~ "live_state()"
  end

  test "Must #19: Matrix / Web files name no Nebu.OAuth.Config / Nebu.OAuth.Metadata" do
    for f <- Path.wildcard(Path.join(@lib, "nebu/{matrix,web}/**/*.ex")) ++ [Path.join(@lib, "nebu/matrix.ex")] do
      refute code(f) =~ ~r/Nebu\.OAuth\.(Config|Metadata)\b/, "#{rel(f)} must ask Nebu.OAuth.oauth_aware?/0 (ADR-020)"
    end
  end

  test "V1/V3: the version lists live only in http_public.ex; router.ex calls HttpPublic.versions/1 and holds no version literal" do
    router = code(Path.join(@lib, "nebu/web/router.ex"))
    assert router =~ "Nebu.Matrix.HttpPublic.versions("
    refute router =~ ~r/v1\.1\b/, "router.ex holds no version literal"

    # a version LIST literal (~w(... v1.15 ...) or "v1.15" in a list), not prose in a moduledoc
    list_re = ~r/~w\([^)]*\bv1\.1[15]\b[^)]*\)|"v1\.1[15]"/
    holders = lib_files() |> Enum.filter(&(code(&1) =~ list_re)) |> Enum.map(&rel/1)
    assert holders == ["nebu/matrix/http_public.ex"], "the version lists live only in http_public.ex: #{inspect(holders)}"

    # exactly ONE on-list and ONE off-list: v1.15 / v1.12 occur once; v1.11 once (on = off ++ extra) or twice (two literals)
    hp = code(Path.join(@lib, "nebu/matrix/http_public.ex"))
    assert length(Regex.scan(~r/\bv1\.15\b/, hp)) == 1
    assert length(Regex.scan(~r/\bv1\.12\b/, hp)) == 1
    assert length(Regex.scan(~r/\bv1\.11\b/, hp)) in [1, 2]
  end

  # test review M3: the earlier literal check could never match (quoting); match the real shapes of an
  # unstable-feature entry (`"key" => true` / `key: true`) for every OAuth MSC or *oauth* key.
  @forbidden_key ~r/"(org\.matrix\.msc(2964|2965|2966|2967|3861|3824[^"]*|4191)|[^"]*oauth[^"]*)"\s*=>\s*(true|false)/i

  test "Must #5/V5: no OAuth MSC / *oauth* unstable-feature key literal next to unstable_features" do
    files = lib_files() |> Enum.filter(&(code(&1) =~ "unstable_features"))
    assert files != [], "the versions body must still be built somewhere"

    # Only the `unstable_features` map itself is inspected: `http_public.ex` also holds the GET /login SSO
    # flow keys (`"org.matrix.msc3824.delegated_oidc_compatibility" => true`, story 5 C3), which are NOT
    # unstable features. (Deliberate fix of the first draft, which scanned the whole file.)
    for f <- files, [map] <- Regex.scan(~r/"unstable_features"\s*=>\s*%\{[^}]*\}/, code(f)) do
      refute map =~ @forbidden_key, "#{rel(f)} advertises an OAuth MSC as an unstable feature"
    end
  end

  test "Must #5/V5 runtime guard: versions_body/1 carries exactly the msc2666 flag in both states" do
    for live <- [true, false] do
      body = apply(Nebu.Matrix.HttpPublic, :versions_body, [live])
      assert body["unstable_features"] == %{"uk.half-shot.msc2666.query_mutual_rooms" => true}
      refute Enum.any?(Map.keys(body["unstable_features"]), &(&1 =~ ~r/msc2964|msc2965|msc2966|msc2967|msc3861|msc3824|msc4191|oauth/i))
    end
  end

  # story oauth-hardening-hygiene HY1 (changed by design): the predicate path now has ONE per-node TTL cache of the
  # normalized switch state (`Nebu.OAuth.Config`, ETS table `:nebu_oauth_config_cache` owned by the supervised
  # `Nebu.OAuth.CacheOwner`, bounded staleness NEBU_OAUTH_CONFIG_CACHE_MS, ADR-020 note HY2). What still must not
  # exist: `:persistent_term` / process-dictionary state (nothing that outlives or hides from the TTL), and
  # any cache outside `Nebu.OAuth.Config` (the Matrix side asks `Nebu.OAuth.oauth_aware?/1` only).
  test "Must #19 (amended by HY1): no persistent_term / process-dictionary state in the predicate path; the only cache is Config's ETS TTL cache" do
    for f <- ["nebu/oauth/config.ex", "nebu/oauth.ex", "nebu/matrix/http_public.ex"] do
      src = code(Path.join(@lib, f))
      refute src =~ ":persistent_term", f
      refute src =~ "Process.put", f
    end

    for f <- ["nebu/oauth.ex", "nebu/matrix/http_public.ex"] do
      refute code(Path.join(@lib, f)) =~ ":ets.", "#{f}: the TTL cache lives in Nebu.OAuth.Config only"
    end
  end
end
