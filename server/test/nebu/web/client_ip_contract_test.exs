defmodule Nebu.Web.ClientIPContractTest do
  @moduledoc """
  Static contract test for story `oauth-trusted-proxy-client-ip` (P1), AC6.2 (+ AC6.1, AC6.3):
  `Nebu.Web.ClientIP` is the ONLY place that reads the peer address or `X-Forwarded-For`; every
  per-IP consumer calls `Nebu.Web.ClientIP.get/1` (stored data: `created_from_ip`, `last_seen_ip`) or
  `Nebu.Web.ClientIP.bucket/1` (rate-limit keys, IPv6 aggregated to /64). Scans `server/lib/**/*.ex` as text (no compilation, no DB).

  Scan rules (verbatim from the story):
    * the tokens `remote_ip`, `peer_data`, `get_peer_data` and `x_forwarded_for` occur ONLY in `lib/nebu/web/client_ip.ex` and
      `lib/nebu/web/plugs/client_ip.ex` (moduledocs elsewhere say "direct peer");
    * `x-forwarded-for` (case-insensitive) occurs only in those two files;
    * no `def`/`defp` named `ip_string`, `client_ip` or `ip_key` exists anywhere;
    * `:inet.ntoa` occurs only in `client_ip.ex`, `lib/nebu/media/http_fetch.ex` and `lib/nebu/media/pinned_http_client.ex` (outbound, allowlisted);
    * the string literals `"forwarded"` (RFC 7239) and `"x-real-ip"` occur nowhere.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  @client_ip_files ["nebu/web/client_ip.ex", "nebu/web/plugs/client_ip.ex"]
  @ntoa_allowed ["nebu/web/client_ip.ex", "nebu/media/http_fetch.ex", "nebu/media/pinned_http_client.ex"]

  defp sources do
    for path <- Path.wildcard(Path.join(@lib, "**/*.ex")), do: {Path.relative_to(path, @lib), File.read!(path)}
  end

  defp offenders(pred), do: for({rel, text} <- sources(), pred.(rel, text), do: rel)

  test "the scan sees the lib tree (guards against a silently empty scan)" do
    assert length(sources()) > 100
    assert File.exists?(Path.join(@lib, "nebu/web/router.ex"))
  end

  test "AC6.1: the helper and the plug exist" do
    for f <- @client_ip_files, do: assert(File.exists?(Path.join(@lib, f)), "lib/#{f} must exist")
  end

  test "AC6.2: the token `remote_ip` occurs only in the two client_ip files" do
    found = offenders(fn rel, text -> text =~ "remote_ip" and rel not in @client_ip_files end)
    assert found == [], "remote_ip must only be read by ClientIP (say \"direct peer\" in docs): #{inspect(found)}"
  end

  test "AC6.2: no other peer / forwarding-header access path (get_peer_data, peer_data, x_forwarded_for)" do
    re = ~r/get_peer_data|peer_data|x_forwarded_for|x-forwarded-host|:forwarded_for/i
    found = offenders(fn rel, text -> Regex.match?(re, text) and rel not in @client_ip_files end)
    assert found == [], "only ClientIP may read the peer or the forwarding header: #{inspect(found)}"
  end

  test "AC6.2: `x-forwarded-for` (case-insensitive) occurs only in the two client_ip files" do
    found = offenders(fn rel, text -> text =~ ~r/x-forwarded-for/i and rel not in @client_ip_files end)
    assert found == [], "X-Forwarded-For handling must live in ClientIP only: #{inspect(found)}"
  end

  test "AC6.2: no def/defp named ip_string, client_ip or ip_key exists anywhere" do
    re = ~r/^\s*defp?\s+(ip_string|client_ip|ip_key)\b/m
    found = offenders(fn _rel, text -> Regex.match?(re, text) end)
    assert found == [], "the duplicated per-IP helpers must be deleted: #{inspect(found)}"
  end

  test "AC6.2: `:inet.ntoa` occurs only in client_ip.ex, media/http_fetch.ex and media/pinned_http_client.ex (outbound)" do
    found = offenders(fn rel, text -> text =~ ":inet.ntoa" and rel not in @ntoa_allowed end)
    assert found == [], ":inet.ntoa string building for client IPs must live in ClientIP only: #{inspect(found)}"
  end

  test "AC6.2: the media allowlist entry is real (http_fetch.ex still uses :inet.ntoa for OUTBOUND targets)" do
    assert File.read!(Path.join(@lib, "nebu/media/http_fetch.ex")) =~ ":inet.ntoa"
  end

  test "AC6.2: the pinned client allowlist entry is real (pinned_http_client.ex still uses :inet.ntoa for the OUTBOUND pinned address)" do
    assert File.read!(Path.join(@lib, "nebu/media/pinned_http_client.ex")) =~ ":inet.ntoa"
  end

  test "AC6.2: the string literals \"forwarded\" (RFC 7239) and \"x-real-ip\" occur nowhere" do
    found = offenders(fn _rel, text -> text =~ ~r/"forwarded"|"x-real-ip"/i end)
    assert found == [], "Forwarded and X-Real-IP are ignored entirely (TP6): #{inspect(found)}"
  end

  describe "AC6.1/AC6.3 — every consumer calls ClientIP.bucket/1 (limits) or ClientIP.get/1 (stored data)" do
    # rate-limit keys: IPv6 aggregated to /64 (security review cycle 1)
    @bucket_consumers [
      {"nebu/web/plugs/rate_limit.ex", "RateLimit key"},
      {"nebu/oauth/authorize.ex", "{\"oauth_authorize\"|\"oauth_callback\", ip}"},
      {"nebu/oauth/http.ex", "jwks / register buckets"},
      {"nebu/oauth/token.ex", "{\"oauth_token\"|\"oauth_token_refresh\", ip}"},
      {"nebu/oauth/revoke.ex", "{\"oauth_revoke\", ip}"},
      {"nebu/oauth/account.ex", "{\"oauth_account\", ip}"}
    ]

    # stored data keeps the exact address
    @get_consumers [
      {"nebu/oauth/http.ex", "oauth_clients.created_from_ip (store/2)"},
      {"nebu/web/router/protected.ex", "devices.last_seen_ip (touch_device_last_seen/1)"},
      {"nebu/matrix/http_public.ex", "devices.last_seen_ip at login (register_device/4)"}
    ]

    for {rel, what} <- @bucket_consumers do
      test "#{rel} (#{what}) calls Nebu.Web.ClientIP.bucket/1" do
        text = File.read!(Path.join(@lib, unquote(rel)))

        assert text =~ ~r/\bClientIP\.bucket\(/,
               "#{unquote(rel)} must call Nebu.Web.ClientIP.bucket/1 (alias ClientIP or full name)"
      end
    end

    for {rel, what} <- @get_consumers do
      test "#{rel} (#{what}) calls Nebu.Web.ClientIP.get/1" do
        text = File.read!(Path.join(@lib, unquote(rel)))

        assert text =~ ~r/\bClientIP\.get\(/,
               "#{unquote(rel)} must call Nebu.Web.ClientIP.get/1 (alias ClientIP or full name)"
      end
    end

    test "no rate-limit key is built from the exact address: RateLimit.take(...) never takes ClientIP.get/1" do
      re = ~r/RateLimit\.take\(\{[^}]*ClientIP\.get\(/
      found = offenders(fn _rel, text -> Regex.match?(re, text) end)
      assert found == [], "per-IP limits must use ClientIP.bucket/1 (IPv6 /64): #{inspect(found)}"
    end

    test "the public FormPost.ip_string/1 is gone and no module still calls it" do
      found = offenders(fn _rel, text -> text =~ ~r/FormPost\.ip_string\b/ end)
      assert found == [], "FormPost.ip_string/1 must be deleted: #{inspect(found)}"
    end

    test "AC6.3: last_seen_ip writers take the value from ClientIP.get/1 (no inline peer string)" do
      for rel <- ["nebu/web/router/protected.ex", "nebu/matrix/http_public.ex"] do
        text = File.read!(Path.join(@lib, rel))
        assert text =~ "last_seen_ip", "#{rel} is expected to write devices.last_seen_ip"
        assert text =~ ~r/ClientIP\.get\(/, "#{rel}: last_seen_ip must come from ClientIP.get/1"
        refute text =~ ~r/defp?\s+client_ip\b/, "#{rel}: the private client_ip/1 copy must be deleted"
      end
    end
  end
end
