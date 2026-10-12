defmodule Nebu.Media.SSRFTest do
  # async: false — mutates the :media_storage_allow_private_endpoints app env.
  use ExUnit.Case, async: false

  alias Nebu.Media.SSRF

  # Literal IPs only — no live DNS lookup needed.
  @private_urls [
    "https://10.0.0.5/iam",
    "https://172.16.0.1/iam",
    "https://192.168.1.1/iam",
    # CGNAT — what UpCloud's *-private.upcloudobjects.com resolves to.
    "https://100.126.127.4:4443/iam",
    "https://[fd00::1]/iam"
  ]

  @always_blocked_urls [
    "https://127.0.0.1/iam",
    "https://0.0.0.0/iam",
    "https://169.254.169.254/iam",
    "https://224.0.0.1/iam",
    "https://[::1]/iam",
    "https://[fe80::1]/iam",
    "https://[::ffff:127.0.0.1]/iam",
    "https://[::ffff:169.254.169.254]/iam"
  ]

  setup do
    previous = Application.get_env(:nebu_http, :media_storage_allow_private_endpoints)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:nebu_http, :media_storage_allow_private_endpoints)
        value -> Application.put_env(:nebu_http, :media_storage_allow_private_endpoints, value)
      end
    end)

    :ok
  end

  describe "checked_target/2 default (strict)" do
    test "blocks private, CGNAT and always-blocked addresses" do
      for url <- @private_urls ++ @always_blocked_urls do
        assert {:error, :blocked_address} = SSRF.checked_target(url), "expected #{url} blocked"
      end
    end

    test "allows a public address" do
      assert {:ok, %{host: "93.184.216.34"}} = SSRF.checked_target("https://93.184.216.34/iam")
    end
  end

  describe "checked_target/2 with allow_private: true" do
    test "allows RFC1918, CGNAT and unique-local addresses" do
      for url <- @private_urls do
        assert {:ok, _} = SSRF.checked_target(url, allow_private: true), "expected #{url} allowed"
      end
    end

    test "still blocks loopback, link-local, metadata, unspecified and multicast" do
      for url <- @always_blocked_urls do
        assert {:error, :blocked_address} = SSRF.checked_target(url, allow_private: true),
               "expected #{url} to stay blocked"
      end
    end

    test "still rejects bad scheme / missing host" do
      assert {:error, :bad_scheme} = SSRF.checked_target("ftp://10.0.0.1/x", allow_private: true)
      assert {:error, :no_host} = SSRF.checked_target("https:///x", allow_private: true)
    end
  end

  describe "allow_private_storage?/0" do
    test "defaults to false, true only when explicitly enabled" do
      Application.delete_env(:nebu_http, :media_storage_allow_private_endpoints)
      refute SSRF.allow_private_storage?()

      Application.put_env(:nebu_http, :media_storage_allow_private_endpoints, true)
      assert SSRF.allow_private_storage?()

      Application.put_env(:nebu_http, :media_storage_allow_private_endpoints, "true")
      refute SSRF.allow_private_storage?()
    end
  end

  describe "describe_error/1" do
    test "names the real reason" do
      assert SSRF.describe_error(:blocked_address) =~ "NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS"
      assert SSRF.describe_error(:nxdomain) =~ "DNS"
      assert SSRF.describe_error(:bad_scheme) =~ "scheme"
    end
  end
end
