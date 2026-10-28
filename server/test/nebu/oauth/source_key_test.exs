defmodule Nebu.OAuth.SourceKeyTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-dcr-abuse-hardening`, AC3 (AH3): the pure module
  `Nebu.OAuth.SourceKey` — a fixed-length, pseudonymous grouping key of the resolved client
  address (IPv4 /32, IPv6 /64, lowercase hex SHA-256 over `"nebu-oauth-source-v1|" <> normalised`).

  `from_ip/1` takes the address STRING (what `Nebu.Web.ClientIP.get/1` returns); `for_conn/1` is
  `from_ip(ClientIP.get(conn))`. Calls go through `apply/3` so this file compiles before the
  module exists.
  """
  # async: false: the for_conn/1 block writes the global :persistent_term of Nebu.Web.ClientIP
  use ExUnit.Case, async: false

  import Plug.Test

  @sk Nebu.OAuth.SourceKey

  # sha256("nebu-oauth-source-v1|v4:203.0.113.7") and sha256("nebu-oauth-source-v1|v6:20010db800010002")
  @vector_v4 "fd7e6fc6113701777ee65eeed649b12aded704f78930b619b9b45fdb9426da0f"
  @vector_v6 "706b9644140d71d17deec05704f1e7d975790ea8b22b1655794389154d22b7d6"

  defp key(ip), do: apply(@sk, :from_ip, [ip])

  describe "AC3.1 — determinism and format" do
    test "deterministic, 64 lowercase hex characters" do
      assert key("203.0.113.7") == key("203.0.113.7")
      assert key("203.0.113.7") =~ ~r/\A[0-9a-f]{64}\z/
      assert key("2001:db8:1:2::1") =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "IPv4 is per full address (/32)" do
      refute key("203.0.113.7") == key("203.0.113.8")
    end
  end

  describe "AC3.2 — IPv6 is per /64, IPv4-mapped is IPv4" do
    test "the same /64 shares a key, another /64 does not" do
      assert key("2001:db8:1:2::1") == key("2001:db8:1:2:ffff:ffff:ffff:ffff")
      assert key("2001:db8:1:2::1") == key("2001:0DB8:0001:0002:0000:0000:0000:0001"), "case and zero padding do not matter"
      refute key("2001:db8:1:2::1") == key("2001:db8:1:3::1")
    end

    test "an IPv4-mapped IPv6 address equals its IPv4 form" do
      assert key("::ffff:203.0.113.7") == key("203.0.113.7")
    end

    test "an IPv6 address never collides with an IPv4 address by construction (v4:/v6: tags)" do
      refute key("2001:db8:1:2::1") == key("32.1.13.184")
    end
  end

  describe "AC3.3 — unparseable input, bounds, static" do
    test "garbage yields a key and never raises" do
      for input <- ["garbage", "", " ", "999.999.999.999", "::g", <<255, 254, 253>>, String.duplicate("x", 5000)] do
        assert key(input) =~ ~r/\A[0-9a-f]{64}\z/, "no key for #{inspect(input, limit: 20)}"
      end
    end

    test "distinct garbage stays distinct (raw: prefix + input)" do
      refute key("garbage") == key("garbage2")
    end

    test "unparseable input is truncated to 64 bytes" do
      assert key(String.duplicate("a", 200)) == key(String.duplicate("a", 64))
      refute key(String.duplicate("a", 200)) == key(String.duplicate("a", 63))
    end

    test "the module never reads the socket peer or the forwarding header itself" do
      path = Path.expand("../../../lib/nebu/oauth/source_key.ex", __DIR__)
      assert File.exists?(path), "server/lib/nebu/oauth/source_key.ex is missing"
      src = File.read!(path)
      refute src =~ "remote_ip"
      refute src =~ ~r/x-forwarded-for/i
      assert src =~ "ClientIP", "for_conn/1 goes through Nebu.Web.ClientIP.get/1 (P1 contract)"
    end
  end

  describe "AC3.4 — vectors" do
    test "pins the keys of 203.0.113.7 and 2001:db8:1:2::1" do
      assert key("203.0.113.7") == @vector_v4
      assert key("2001:db8:1:2::1") == @vector_v6
      assert key("2001:db8:1:2:aaaa:bbbb:cccc:dddd") == @vector_v6
    end
  end

  describe "AC3 — for_conn/1 goes through the P1 resolver" do
    setup do
      prior = Nebu.Web.ClientIP.trusted()
      Nebu.Web.ClientIP.configure(nil)
      # restore what was configured before this block (not a blind reset to "no proxy")
      on_exit(fn -> :persistent_term.put({Nebu.Web.ClientIP, :trusted}, prior) end)
      :ok
    end

    test "an untrusted peer is the source; X-Forwarded-For is ignored" do
      conn = %{conn(:get, "/") | remote_ip: {203, 0, 113, 7}} |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.9")
      assert apply(@sk, :for_conn, [conn]) == @vector_v4
    end

    test "a conn that never passed the ClientIP plug falls back to the normalised peer (TP10)" do
      conn = %{conn(:get, "/") | remote_ip: {0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}}
      assert apply(@sk, :for_conn, [conn]) == @vector_v6
    end

    test "a conn resolved by the plug (trusted proxy + XFF) is keyed by the forwarded client" do
      Nebu.Web.ClientIP.configure("10.0.0.0/8")

      conn =
        %{conn(:get, "/") | remote_ip: {10, 0, 0, 5}}
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7")
        |> Nebu.Web.Plugs.ClientIP.call([])

      assert apply(@sk, :for_conn, [conn]) == @vector_v4
    end
  end
end
