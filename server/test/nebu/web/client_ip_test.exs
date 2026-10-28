defmodule Nebu.Web.ClientIPTest do
  @moduledoc """
  Acceptance tests (unit, no DB) for story `oauth-trusted-proxy-client-ip` (P1, gate item 1):

    * AC1 — `Nebu.Web.ClientIP.parse_cidrs/1` (TP1-TP3)
    * AC2 — boot configuration `load_config/0` / `configure/1` / `trusted/0` and the log lines
    * AC3 — the pure resolver `resolve/3` (TP4-TP7), incl. a property-style loop
    * AC4 — the plug `Nebu.Web.Plugs.ClientIP` and the helpers `Nebu.Web.ClientIP.get/1` / `bucket/1` (TP8-TP10)

  `async: false`: the trusted set lives in `:persistent_term` (TP11) and `configure/1` is a
  global writer. Every test that configures resets to "no trusted proxy" in `on_exit`.

  Security review cycle 1 additions: `Nebu.Web.ClientIP.bucket/1` (IPv6 aggregated to its /64 for
  rate-limit keys, `get/1` stays exact) and the property-loop lower bound for `:forwarded` results.

  ## ATDD decisions
    * AC4.1 plug order: asserted by SOURCE inspection of `lib/nebu/web/router.ex` (the
      `plug Nebu.Web.Plugs.ClientIP` line sits between `RequestId` and `RequestLogger`); the
      end-to-end effect through the router is proven in `client_ip_integration_test.exs`.
    * The `:persistent_term` key `{Nebu.Web.ClientIP, :trusted}` is taken from the story's
      implementation sketch and is only used for AC2.4 (key absent => `[]`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias Nebu.Web.ClientIP
  alias Nebu.Web.Plugs.ClientIP, as: ClientIPPlug

  @pt_key {Nebu.Web.ClientIP, :trusted}

  setup do
    # start from "no trusted proxy" (a leaked set of another module must not matter) and restore
    # the previous Logger level instead of a hard-coded one
    previous_level = Logger.level()
    prev_env = Application.fetch_env(:nebu_http, :trusted_proxy_cidrs)
    ClientIP.configure(nil)

    on_exit(fn ->
      ClientIP.configure(nil)

      case prev_env do
        {:ok, v} -> Application.put_env(:nebu_http, :trusted_proxy_cidrs, v)
        :error -> Application.delete_env(:nebu_http, :trusted_proxy_cidrs)
      end

      Logger.configure(level: previous_level)
    end)

    :ok
  end

  # The trusted set used by the resolver cases (story AC3 preamble).
  defp trusted(spec \\ "10.0.0.0/8, 2001:db8:1::/48") do
    {trusted, invalid} = ClientIP.parse_cidrs(spec)
    assert invalid == [], "fixture CIDRs must be valid: #{inspect(invalid)}"
    trusted
  end

  defp ip!(s) do
    {:ok, ip} = :inet.parse_strict_address(String.to_charlist(s))
    ip
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — CIDR parsing
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — parse_cidrs/1 accepts" do
    for {entry, prefix} <- [
          {"10.0.0.0/8", 8},
          {"172.18.0.0/16", 16},
          {"192.0.2.10", 32},
          {"0.0.0.0/0", 0},
          {"2001:db8::/32", 32},
          {"2001:DB8::/32", 32},
          {"::1", 128},
          {"::/0", 0}
        ] do
      test "#{entry} (prefix #{prefix})" do
        assert {[{_family, _net, unquote(prefix)}], []} = ClientIP.parse_cidrs(unquote(entry))
      end
    end

    test "the network integer of 10.0.0.0/8 is 10 <<< 24 and of 192.0.2.10 is the address as 32-bit int" do
      assert {[{_, 167_772_160, 8}], []} = ClientIP.parse_cidrs("10.0.0.0/8")
      assert {[{_, 3_221_225_994, 32}], []} = ClientIP.parse_cidrs("192.0.2.10")
    end

    test "upper and lower case IPv6 give the identical entry" do
      assert ClientIP.parse_cidrs("2001:db8::/32") == ClientIP.parse_cidrs("2001:DB8::/32")
    end

    test "IPv4 and IPv6 entries carry different families" do
      {[{f4, _, _}], []} = ClientIP.parse_cidrs("10.0.0.0/8")
      {[{f6, _, _}], []} = ClientIP.parse_cidrs("2001:db8::/32")
      refute f4 == f6
    end

    test "mixed separators (comma and/or whitespace) keep all three entries" do
      assert {trusted, []} = ClientIP.parse_cidrs("10.0.0.0/8, 192.0.2.1  2001:db8::/48")
      assert length(trusted) == 3
    end

    test "an empty entry between separators is skipped, not an error" do
      assert {[_], []} = ClientIP.parse_cidrs("10.0.0.0/8,,")
      assert {[_], []} = ClientIP.parse_cidrs(",10.0.0.0/8, ,")
    end
  end

  describe "AC1 — parse_cidrs/1 rejects (each alone => trusted == [])" do
    for bad <- [
          "*",
          "all",
          "any",
          "yes",
          "true",
          "0/0",
          "10.1",
          "1.2.3",
          "0x7f.0.0.1",
          "010.0.0.1",
          "10.0.0.0/33",
          "10.0.0.0/-1",
          "10.0.0.0/8a",
          "10.0.0.0/",
          "10.0.0.1/8",
          "2001:db8::1/32",
          "2001:db8::/129",
          "fe80::1%eth0",
          "[::1]",
          "10.0.0.1:80",
          "::ffff:10.0.0.0/104",
          "::ffff:10.0.0.5",
          "::ffff:a00:0/104",
          "ALL",
          "TRUE",
          "Any",
          <<0xC3, 0x28>>,
          "10.0.0.0/8" <> <<0>>,
          <<0>> <> "10.0.0.0/8",
          "10.0.0.0/" <> <<0xFF>>,
          "10.0.0.0/08",
          "10.0.0.0/008"
        ] do
      test "#{inspect(bad)}" do
        assert {[], invalid} = ClientIP.parse_cidrs(unquote(bad))
        assert invalid != [], "the rejected entry must be reported"
      end
    end

    test "host bits set are rejected, NOT masked (10.0.0.1/8 does not become 10.0.0.0/8)" do
      assert {[], [_]} = ClientIP.parse_cidrs("10.0.0.1/8")
    end

    test "mixed valid + invalid keeps the valid ones and reports the invalid ones" do
      assert {trusted, invalid} = ClientIP.parse_cidrs("10.0.0.0/8, *, 192.0.2.1, 10.0.0.1/8, 2001:db8::/32")
      assert length(trusted) == 3
      assert length(invalid) == 2
    end

    test "65 valid entries => the WHOLE variable is ignored" do
      spec = Enum.map_join(1..65, ",", fn i -> "10.0.#{i}.0/24" end)
      assert {[], invalid} = ClientIP.parse_cidrs(spec)
      assert invalid != []
    end

    test "64 valid entries are still accepted (boundary)" do
      spec = Enum.map_join(1..64, ",", fn i -> "10.0.#{i}.0/24" end)
      assert {trusted, []} = ClientIP.parse_cidrs(spec)
      assert length(trusted) == 64
    end

    test "a value longer than 4096 bytes => the WHOLE variable is ignored" do
      spec = "10.0.0.0/8" <> String.duplicate(" ", 4097 - 10)
      assert byte_size(spec) == 4097
      assert {[], invalid} = ClientIP.parse_cidrs(spec)
      assert invalid != []
    end
  end

  describe "AC1 — parse_cidrs/1 empty input" do
    for empty <- [nil, "", "   ", "\t\n "] do
      test "#{inspect(empty)} => {[], []}" do
        assert ClientIP.parse_cidrs(unquote(empty)) == {[], []}
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — boot configuration and log lines
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2 — trusted/0, configure/1, load_config/0" do
    test "AC2.4: with no configuration ever loaded (persistent_term key absent) the trusted set is []" do
      :persistent_term.erase(@pt_key)
      assert ClientIP.trusted() == []
    end

    test "AC2.3: configure/1 stores the parsed set; configure(nil) restores 'no trusted proxy'" do
      assert :ok = ClientIP.configure("10.0.0.0/8")
      assert length(ClientIP.trusted()) == 1
      assert :ok = ClientIP.configure(nil)
      assert ClientIP.trusted() == []
    end

    test "AC2.3: configure/1 replaces (does not accumulate) the previous set" do
      ClientIP.configure("10.0.0.0/8, 192.0.2.1")
      ClientIP.configure("172.18.0.0/16")
      assert [{_, _, 16}] = ClientIP.trusted()
    end

    test "AC2.2: load_config/0 reads :nebu_http, :trusted_proxy_cidrs (raw string) and parses it" do
      Application.put_env(:nebu_http, :trusted_proxy_cidrs, "10.0.0.0/8 192.0.2.1")
      assert :ok = ClientIP.load_config()
      assert length(ClientIP.trusted()) == 2

      Application.put_env(:nebu_http, :trusted_proxy_cidrs, nil)
      assert :ok = ClientIP.load_config()
      assert ClientIP.trusted() == []

      Application.delete_env(:nebu_http, :trusted_proxy_cidrs)
      assert :ok = ClientIP.load_config()
      assert ClientIP.trusted() == []
    end

    test "AC2.2: invalid entries never widen the set; an all-invalid value trusts nobody" do
      ClientIP.configure("*, all, true, 0/0")
      assert ClientIP.trusted() == []
    end
  end

  describe "AC2.2 — log lines (capture_log)" do
    setup do
      # the test env logs at :warning; the info line needs :info (restored in on_exit above)
      Logger.configure(level: :info)
      :ok
    end

    defp proxy_lines(log) do
      log |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/proxy|trusted|forwarded/i))
    end

    # number of boot lines of one level (only lines about this feature count, so unrelated log
    # noise of other processes cannot break the exactly-one assertions)
    defp count_level(log, level), do: Enum.count(proxy_lines(log), &(&1 =~ "[#{level}]"))

    test "an empty / unset value logs NOTHING" do
      for v <- [nil, "", "   "] do
        log = capture_log([level: :info], fn -> ClientIP.configure(v) end)
        assert proxy_lines(log) == [], "no log line expected for #{inspect(v)}, got: #{log}"
      end
    end

    test "a valid set logs ONE info line with the number of CIDRs, not the list" do
      log = capture_log([level: :info], fn -> ClientIP.configure("10.0.0.0/8, 192.0.2.1") end)
      lines = proxy_lines(log)
      assert length(lines) == 1, "exactly one line expected, got: #{log}"
      assert hd(lines) =~ "[info]"
      assert hd(lines) =~ ~r/\b2\b/
      refute log =~ "10.0.0.0/8"
      refute log =~ "192.0.2.1"
      assert count_level(log, "warning") == 0
    end

    test "invalid entries log exactly ONE warning: count + at most 5 entries" do
      bad = for i <- 1..8, do: "bad-entry-#{i}"
      log = capture_log([level: :info], fn -> ClientIP.configure("10.0.0.0/8 " <> Enum.join(bad, " ")) end)

      assert count_level(log, "warning") == 1, "exactly ONE warning expected, got: #{log}"
      assert log =~ ~r/\b8\b/, "the warning names the number of invalid entries"
      shown = Enum.count(bad, &String.contains?(log, &1))
      assert shown >= 1 and shown <= 5, "between 1 and 5 offending entries are shown, got #{shown}"
    end

    test "each offending entry is truncated to 64 bytes" do
      long = String.duplicate("a", 200)
      log = capture_log([level: :info], fn -> ClientIP.configure(long) end)
      assert log =~ "[warning]"
      assert log =~ String.duplicate("a", 10)
      refute log =~ String.duplicate("a", 65), "entries must be truncated to 64 bytes"
    end

    test "a /0 entry logs ONE additional loud warning (and the info line)" do
      log = capture_log([level: :info], fn -> ClientIP.configure("0.0.0.0/0") end)
      assert count_level(log, "warning") == 1, "got: #{log}"
      assert log =~ ~r/every peer/i
      assert log =~ ~r/X-Forwarded-For/i
      assert log =~ ~r/choose its rate-limit bucket/i
      assert log =~ "[info]"
    end

    test "two /0 entries still produce exactly ONE catch-all warning" do
      log = capture_log([level: :info], fn -> ClientIP.configure("0.0.0.0/0, ::/0") end)
      assert count_level(log, "warning") == 1, "got: #{log}"
    end

    test "invalid entry AND /0 => exactly two warnings" do
      log = capture_log([level: :info], fn -> ClientIP.configure("::/0, nonsense") end)
      assert count_level(log, "warning") == 2, "got: #{log}"
    end

    test "65 valid entries: exactly ONE warning, no entry list dump" do
      spec = Enum.map_join(1..65, ",", fn i -> "10.0.#{i}.0/24" end)
      log = capture_log([level: :info], fn -> ClientIP.configure(spec) end)
      assert count_level(log, "warning") == 1, "got: #{log}"
      assert count_level(log, "info") == 0, "an ignored variable trusts nobody and logs no info line"
      refute log =~ "10.0.65.0/24", "the oversize value must not be dumped whole"
      refute log =~ "10.0.3.0/24"
      assert ClientIP.trusted() == []
    end

    test "a value over 4096 bytes: exactly ONE warning, truncated to 64 bytes, never dumped whole" do
      spec = "10.0.0.0/8" <> String.duplicate(" ", 4090) <> "marker-at-the-end"
      assert byte_size(spec) > 4096
      log = capture_log([level: :info], fn -> ClientIP.configure(spec) end)
      assert count_level(log, "warning") == 1, "got: #{log}"
      refute log =~ "marker-at-the-end"
      refute log =~ String.duplicate(" ", 100)
      assert ClientIP.trusted() == []
    end

    # Amended by story client-ip-misconfiguration-warnings (D6, AC7). Why the old "logs NOTHING" test had to
    # change: it sends an UNTRUSTED peer (198.51.100.9) with X-Forwarded-For while trusting 10.0.0.0/8, which is
    # exactly the case W1 (D1) now reports with ONE throttled warning. What stays pinned: trusted-peer requests
    # log nothing, and no line ever carries a peer address or a header value (TP13).
    test "TP13: the plug logs no address and at most the throttled untrusted-forwarding warning" do
      ClientIP.configure("10.0.0.0/8")

      trusted_log =
        capture_log([level: :debug], fn ->
          for xff <- ["203.0.113.7", "garbage", "", "10.0.0.9"] do
            ClientIPPlug.call(req({10, 0, 0, 5}, xff), [])
          end
        end)

      assert proxy_lines(trusted_log) == [], "trusted-peer requests log nothing, got: #{trusted_log}"

      untrusted_log =
        capture_log([level: :debug], fn ->
          ClientIPPlug.call(req({198, 51, 100, 9}, "203.0.113.7"), [])
        end)

      lines = proxy_lines(untrusted_log)
      assert length(lines) == 1, "exactly one W1 line expected for the untrusted call, got: #{untrusted_log}"
      assert hd(lines) =~ "client IP: a request carried X-Forwarded-For"

      for log <- [trusted_log, untrusted_log], addr <- ["203.0.113.7", "198.51.100.9", "10.0.0.5"] do
        refute log =~ addr, "no line may contain #{addr}"
      end
    end

    test "a /8 set is silent apart from the info line (no catch-all warning)" do
      log = capture_log([level: :info], fn -> ClientIP.configure("10.0.0.0/8") end)
      assert count_level(log, "warning") == 0
    end
  end

  describe "AC2.1/AC2.2 — wiring (static)" do
    test "config/runtime.exs copies the raw env into :nebu_http, :trusted_proxy_cidrs (no parsing there)" do
      src = File.read!(Path.expand("../../../config/runtime.exs", __DIR__))
      assert src =~ "NEBU_TRUSTED_PROXY_CIDRS"
      assert src =~ "trusted_proxy_cidrs"
      refute src =~ "parse_cidrs", "runtime.exs must not parse the value"
    end

    test "Nebu.Application.start/2 calls ClientIP.load_config() before the Bandit child starts" do
      src = File.read!(Path.expand("../../../lib/nebu/application.ex", __DIR__))
      assert src =~ ~r/ClientIP\.load_config\(\)/, "application.ex must call Nebu.Web.ClientIP.load_config/0"
      {load_at, _} = :binary.match(src, "ClientIP.load_config()")
      {bandit_at, _} = :binary.match(src, "Bandit")
      assert load_at < bandit_at, "load_config/0 must run before the Bandit child is started"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — the pure resolver
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3.1/AC3.2 — trust gate on the direct peer" do
    test "untrusted peer + XFF => the peer (spoof refused)" do
      assert ClientIP.resolve({198, 51, 100, 9}, ["203.0.113.7"], trusted()) == {:peer, {198, 51, 100, 9}}
    end

    test "trusted peer + XFF => the forwarded client" do
      assert ClientIP.resolve({10, 0, 0, 5}, ["203.0.113.7"], trusted()) == {:forwarded, {203, 0, 113, 7}}
    end

    test "an empty trusted set never honours the header (default behaviour)" do
      assert ClientIP.resolve({10, 0, 0, 5}, ["203.0.113.7"], []) == {:peer, {10, 0, 0, 5}}
    end
  end

  describe "AC3.3-AC3.5 — right-to-left walk" do
    test "trusted hops are skipped; the rightmost untrusted element wins; client-written left side ignored" do
      xff = ["198.51.100.1, 203.0.113.7, 10.0.0.9, 10.1.2.3"]
      assert ClientIP.resolve({10, 0, 0, 5}, xff, trusted()) == {:forwarded, {203, 0, 113, 7}}
    end

    test "multiple header lines are joined in request order" do
      assert ClientIP.resolve({10, 0, 0, 5}, ["203.0.113.7", "10.0.0.9"], trusted()) ==
               {:forwarded, {203, 0, 113, 7}}

      assert ClientIP.resolve({10, 0, 0, 5}, ["198.51.100.1", "203.0.113.7"], trusted()) ==
               {:forwarded, {203, 0, 113, 7}}
    end

    test "elements are trimmed" do
      assert ClientIP.resolve({10, 0, 0, 5}, ["  203.0.113.7  ,\t10.0.0.9 "], trusted()) ==
               {:forwarded, {203, 0, 113, 7}}
    end

    test "garbage LEFT of the client is never parsed and cannot influence the result" do
      assert ClientIP.resolve({10, 0, 0, 5}, ["foo, <script>, 203.0.113.7"], trusted()) ==
               {:forwarded, {203, 0, 113, 7}}
    end

    test "invalid UTF-8 LEFT of the client is never parsed (never raises)" do
      assert ClientIP.resolve({10, 0, 0, 5}, [<<0xC3, 0x28>> <> ", 203.0.113.7"], trusted()) ==
               {:forwarded, {203, 0, 113, 7}}

      assert ClientIP.resolve({10, 0, 0, 5}, [<<0xFF, 0xFE, 0>>, "203.0.113.7"], trusted()) ==
               {:forwarded, {203, 0, 113, 7}}
    end

    test "invalid UTF-8 as an intermediate hop REACHED by the walk falls back to the peer" do
      assert ClientIP.resolve({10, 0, 0, 5}, ["203.0.113.7, " <> <<0xC3, 0x28>> <> ", 10.0.0.9"], trusted()) ==
               {:peer, {10, 0, 0, 5}}

      assert ClientIP.resolve({10, 0, 0, 5}, ["203.0.113.7, 1.2.3.4" <> <<0>> <> ", 10.0.0.9"], trusted()) ==
               {:peer, {10, 0, 0, 5}}
    end

    test "the leftmost element is never preferred over the rightmost untrusted one" do
      assert ClientIP.resolve({10, 0, 0, 5}, ["1.1.1.1, 2.2.2.2"], trusted()) == {:forwarded, {2, 2, 2, 2}}
    end
  end

  describe "AC3.6 — fallback to the peer (never the leftmost element)" do
    for {label, xff} <- [
          {"no header", []},
          {"empty value", [""]},
          {"only separators", [" , "]},
          {"unknown", ["unknown"]},
          {"ip with port", ["203.0.113.7:443"]},
          {"bracketed IPv6", ["[2001:db8::1]"]},
          {"IPv6 with zone", ["fe80::1%eth0"]},
          {"obfuscated identifier", ["_hidden"]},
          {"shorthand ipv4", ["203.0.113"]},
          {"leading-zero octet", ["203.0.113.007"]},
          {"empty element reached by the walk", ["10.0.0.9, , 10.0.0.8"]},
          {"malformed element reached by the walk", ["203.0.113.7, garbage, 10.0.0.8"]},
          {"all elements trusted", ["10.0.0.9, 10.0.0.8"]}
        ] do
      test "#{label}: #{inspect(xff)}" do
        assert ClientIP.resolve({10, 0, 0, 5}, unquote(xff), trusted()) == {:peer, {10, 0, 0, 5}}
      end
    end

    test "joined length 2049 bytes => peer (cap checked before any splitting)" do
      xff = "203.0.113.7" <> String.duplicate(" ", 2049 - 11)
      assert byte_size(xff) == 2049
      assert ClientIP.resolve({10, 0, 0, 5}, [xff], trusted()) == {:peer, {10, 0, 0, 5}}
    end

    test "joined length exactly 2048 bytes is still honoured (boundary)" do
      xff = "203.0.113.7" <> String.duplicate(" ", 2048 - 11)
      assert byte_size(xff) == 2048
      assert ClientIP.resolve({10, 0, 0, 5}, [xff], trusted()) == {:forwarded, {203, 0, 113, 7}}
    end

    test "the joined length counts all header lines" do
      lines = ["203.0.113.7" <> String.duplicate(" ", 1500), String.duplicate(" ", 600) <> "10.0.0.9"]
      assert ClientIP.resolve({10, 0, 0, 5}, lines, trusted()) == {:peer, {10, 0, 0, 5}}
    end

    test "21 trusted elements and nothing untrusted within the cap => peer" do
      xff = [Enum.join(List.duplicate("10.0.0.9", 21), ", ")]
      assert ClientIP.resolve({10, 0, 0, 5}, xff, trusted()) == {:peer, {10, 0, 0, 5}}
    end

    test "a 25-element header whose untrusted element is the 21st from the right => peer (hop cap)" do
      xff = [Enum.join(List.duplicate("198.51.100.2", 4) ++ ["203.0.113.7"] ++ List.duplicate("10.0.0.9", 20), ", ")]
      assert ClientIP.resolve({10, 0, 0, 5}, xff, trusted()) == {:peer, {10, 0, 0, 5}}
    end

    test "hop cap boundary: the untrusted element is the 20th from the right => honoured" do
      xff = [Enum.join(["203.0.113.7"] ++ List.duplicate("10.0.0.9", 19), ", ")]
      assert ClientIP.resolve({10, 0, 0, 5}, xff, trusted()) == {:forwarded, {203, 0, 113, 7}}
    end

    test "10 000 commas do not raise and fall back to the peer" do
      assert ClientIP.resolve({10, 0, 0, 5}, [String.duplicate(",", 10_000)], trusted()) == {:peer, {10, 0, 0, 5}}
    end
  end

  describe "AC3.7 — IPv6" do
    test "peer inside the /48 + IPv6 XFF => forwarded" do
      assert ClientIP.resolve(ip!("2001:db8:1::5"), ["2001:db8:2::7"], trusted()) ==
               {:forwarded, {0x2001, 0xDB8, 2, 0, 0, 0, 0, 7}}
    end

    test "peer outside the /48 => peer" do
      peer = ip!("2001:db8:2::5")
      assert ClientIP.resolve(peer, ["2001:db8:3::7"], trusted()) == {:peer, peer}
    end

    test "mixed families: a trusted IPv6 peer with an IPv4 client" do
      assert ClientIP.resolve(ip!("2001:db8:1::5"), ["203.0.113.7"], trusted()) == {:forwarded, {203, 0, 113, 7}}
    end

    test "get/1 stays the EXACT address (last_seen_ip / created_from_ip): two addresses of one /64 stay distinct" do
      a = ClientIPPlug.call(req(ip!("2001:db8:5::1")), []) |> ClientIP.get()
      b = ClientIPPlug.call(req(ip!("2001:db8:5::2")), []) |> ClientIP.get()
      assert a == "2001:db8:5::1"
      assert b == "2001:db8:5::2"

      ClientIP.configure("2001:db8:1::/48")
      c = ClientIPPlug.call(req(ip!("2001:db8:1::5"), "2a00:1450::1"), []) |> ClientIP.get()
      d = ClientIPPlug.call(req(ip!("2001:db8:1::5"), "2a00:1450::2"), []) |> ClientIP.get()
      assert {c, d} == {"2a00:1450::1", "2a00:1450::2"}
    end
  end

  describe "AC3.8 — IPv4-mapped IPv6 normalisation" do
    test "a mapped peer is trusted by the IPv4 CIDR and a mapped XFF element resolves to IPv4" do
      assert ClientIP.resolve(ip!("::ffff:10.0.0.5"), ["::ffff:203.0.113.7"], trusted()) ==
               {:forwarded, {203, 0, 113, 7}}
    end

    test "an untrusted mapped peer is returned as plain IPv4" do
      assert ClientIP.resolve(ip!("::ffff:198.51.100.9"), ["203.0.113.7"], trusted()) == {:peer, {198, 51, 100, 9}}
    end

    test "a trusted mapped peer without usable XFF falls back to the IPv4 peer" do
      assert ClientIP.resolve(ip!("::ffff:10.0.0.5"), [], trusted()) == {:peer, {10, 0, 0, 5}}
    end

    test "a mapped XFF element that is trusted (10.x) is skipped like its IPv4 form" do
      assert ClientIP.resolve({10, 0, 0, 5}, ["203.0.113.7, ::ffff:10.0.0.9"], trusted()) ==
               {:forwarded, {203, 0, 113, 7}}
    end

    test "an IPv4 CIDR never matches a native IPv6 address (even one that looks like 10.0.0.5)" do
      native = {0, 0, 0, 0, 0, 0, 0x0A00, 5}
      assert ClientIP.resolve(native, ["203.0.113.7"], trusted("10.0.0.0/8")) == {:peer, native}
    end

    test "an IPv6 CIDR never matches an IPv4 address" do
      assert ClientIP.resolve({10, 0, 0, 5}, ["203.0.113.7"], trusted("::/0")) == {:peer, {10, 0, 0, 5}}
    end
  end

  describe "AC3.9 — CIDR boundaries" do
    test "10.0.0.0/8 matches 10.255.255.255 and 10.0.0.0, not 11.0.0.0 nor 9.255.255.255" do
      t = trusted("10.0.0.0/8")
      assert {:forwarded, _} = ClientIP.resolve({10, 255, 255, 255}, ["203.0.113.7"], t)
      assert {:forwarded, _} = ClientIP.resolve({10, 0, 0, 0}, ["203.0.113.7"], t)
      assert {:peer, {11, 0, 0, 0}} = ClientIP.resolve({11, 0, 0, 0}, ["203.0.113.7"], t)
      assert {:peer, {9, 255, 255, 255}} = ClientIP.resolve({9, 255, 255, 255}, ["203.0.113.7"], t)
    end

    test "a /32 matches only the exact address" do
      t = trusted("192.0.2.10")
      assert {:forwarded, _} = ClientIP.resolve({192, 0, 2, 10}, ["203.0.113.7"], t)
      assert {:peer, _} = ClientIP.resolve({192, 0, 2, 11}, ["203.0.113.7"], t)
      assert {:peer, _} = ClientIP.resolve({192, 0, 2, 9}, ["203.0.113.7"], t)
    end

    test "a /128 matches only the exact address" do
      t = trusted("::1")
      assert {:forwarded, _} = ClientIP.resolve({0, 0, 0, 0, 0, 0, 0, 1}, ["203.0.113.7"], t)
      assert {:peer, _} = ClientIP.resolve({0, 0, 0, 0, 0, 0, 0, 2}, ["203.0.113.7"], t)
    end

    test "0.0.0.0/0 matches every IPv4 address and no IPv6 address" do
      t = trusted("0.0.0.0/0")
      # every IPv4 peer is trusted; an IPv6 client element is NOT trusted by an IPv4 /0 and is returned
      assert {:forwarded, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 7}} = ClientIP.resolve({198, 51, 100, 9}, ["2001:db8::7"], t)
      assert {:forwarded, _} = ClientIP.resolve({255, 255, 255, 255}, ["2001:db8::7"], t)
      # ... and every IPv4 element is trusted too, so nothing identifies a client => the peer
      assert ClientIP.resolve({198, 51, 100, 9}, ["203.0.113.7"], t) == {:peer, {198, 51, 100, 9}}
      # an IPv6 peer is not matched by an IPv4 CIDR at all => the header is not honoured
      v6 = ip!("2001:db8::1")
      assert ClientIP.resolve(v6, ["2001:db8::7"], t) == {:peer, v6}
    end

    test "::/0 matches every IPv6 address and no IPv4 address" do
      t = trusted("::/0")
      assert {:forwarded, _} = ClientIP.resolve(ip!("2001:db8::1"), ["203.0.113.7"], t)
      assert {:peer, {198, 51, 100, 9}} = ClientIP.resolve({198, 51, 100, 9}, ["203.0.113.7"], t)
    end

    test "a /30 splits correctly at the block edge" do
      t = trusted("192.0.2.4/30")
      for last <- 4..7, do: assert({:forwarded, _} = ClientIP.resolve({192, 0, 2, last}, ["203.0.113.7"], t))
      for last <- [3, 8], do: assert({:peer, _} = ClientIP.resolve({192, 0, 2, last}, ["203.0.113.7"], t))
    end
  end

  describe "AC3.10 — property-style loop (>= 200 random cases, no new dependency)" do
    @garbage ["unknown", "", "foo", "1.2.3.4:80", "[::1]", "999.1.1.1", "010.0.0.1", "1.2", "<script>", "fe80::1%eth0", "-"]

    defp rand_public(rng_fun) do
      a = Enum.random([11, 12, 44, 100, 150, 198, 203, 223])
      "#{a}.#{rng_fun.(256)}.#{rng_fun.(256)}.#{rng_fun.(256)}"
    end

    defp rand_element do
      case :rand.uniform(10) do
        n when n <= 4 -> rand_public(&:rand.uniform(&1))
        n when n <= 7 -> "10.#{:rand.uniform(255)}.#{:rand.uniform(255)}.#{:rand.uniform(255)}"
        _ -> Enum.random(@garbage)
      end
    end

    defp rand_header do
      elements = for _ <- 1..:rand.uniform(30), do: rand_element()
      joined = Enum.join(elements, Enum.random([",", ", ", " ,  "]))
      # split into 1-3 header lines at element boundaries
      case :rand.uniform(3) do
        1 -> [joined]
        2 -> [joined, rand_element()]
        3 -> [rand_element(), joined, rand_element()]
      end
    end

    defp trusted_v4?(s) do
      case :inet.parse_strict_address(String.to_charlist(s)) do
        {:ok, {10, _, _, _}} -> not Regex.match?(~r/(^|\.)0\d/, s)
        _ -> false
      end
    end

    defp valid_v4?(s) do
      match?({:ok, {_, _, _, _}}, :inet.parse_strict_address(String.to_charlist(s))) and
        not Regex.match?(~r/(^|\.)0\d/, s)
    end

    test "untrusted peer: the result is ALWAYS the peer, whatever XFF contains" do
      :rand.seed(:exsss, {11, 22, 33})
      t = trusted("10.0.0.0/8")

      for _ <- 1..250 do
        peer = {Enum.random([11, 44, 100, 198, 203]), :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
        xff = rand_header()
        assert ClientIP.resolve(peer, xff, t) == {:peer, peer}, "peer #{inspect(peer)} xff #{inspect(xff)}"
      end
    end

    test "trusted peer: the result is the peer or an untrusted element with only valid trusted elements to its right" do
      :rand.seed(:exsss, {44, 55, 66})
      t = trusted("10.0.0.0/8")
      peer = {10, 9, 9, 9}

      forwarded_count =
        Enum.count(1..250, fn _ ->
          xff = rand_header()
          forwarded_checked?(peer, xff, t)
        end)

      # a vacuous loop (always :peer) must not pass: the generator yields a real share of :forwarded
      assert forwarded_count >= 20, "only #{forwarded_count}/250 cases resolved a forwarded client"
    end

    # true when the resolver returned (and we verified) a forwarded client, false for the peer
    defp forwarded_checked?(peer, xff, t) do
      case ClientIP.resolve(peer, xff, t) do
        {:peer, ^peer} ->
          false

        {:forwarded, ip} ->
          elements = xff |> Enum.join(",") |> String.split(",") |> Enum.map(&String.trim/1)
          ip_s = ip |> :inet.ntoa() |> to_string()

          ok? =
            elements
            |> Enum.with_index()
            |> Enum.any?(fn {el, idx} ->
              right = Enum.drop(elements, idx + 1)
              el == ip_s and valid_v4?(el) and not trusted_v4?(el) and Enum.all?(right, &(valid_v4?(&1) and trusted_v4?(&1)))
            end)

          assert ok?, "forwarded #{ip_s} is not the rightmost untrusted element of #{inspect(xff)}"
          true

        other ->
          flunk("unexpected resolver result #{inspect(other)}")
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — the plug and the helper
  # ════════════════════════════════════════════════════════════════════════════

  defp req(peer, xff \\ nil) do
    c = %{conn(:get, "/anything") | remote_ip: peer}
    if xff, do: put_req_header(c, "x-forwarded-for", xff), else: c
  end

  describe "AC4.1 — Nebu.Web.Plugs.ClientIP" do
    test "is a Plug: init/1 returns the opts, call/2 never halts and never touches remote_ip" do
      opts = ClientIPPlug.init([])
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, "203.0.113.7"), opts)
      refute conn.halted
      assert conn.remote_ip == {10, 0, 0, 5}, "conn.remote_ip keeps the real TCP peer (TP9)"
    end

    test "default config: stores the peer string and source :peer, even with an XFF header" do
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, "203.0.113.7"), [])
      assert conn.private[:nebu_client_ip] == "10.0.0.5"
      assert conn.private[:nebu_client_ip_source] == :peer
    end

    test "trusted peer: stores the forwarded client (string, :inet.ntoa) and source :forwarded" do
      ClientIP.configure("10.0.0.0/8")
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, "203.0.113.7"), [])
      assert conn.private[:nebu_client_ip] == "203.0.113.7"
      assert conn.private[:nebu_client_ip_source] == :forwarded
      assert conn.remote_ip == {10, 0, 0, 5}
    end

    test "untrusted peer under a configured set: spoof refused, source :peer" do
      ClientIP.configure("10.0.0.0/8")
      conn = ClientIPPlug.call(req({198, 51, 100, 9}, "203.0.113.7"), [])
      assert conn.private[:nebu_client_ip] == "198.51.100.9"
      assert conn.private[:nebu_client_ip_source] == :peer
    end

    test "IPv6 results are lowercase and compressed (:inet.ntoa), mapped peers are IPv4" do
      ClientIP.configure("2001:db8:1::/48")
      conn = ClientIPPlug.call(req(ip!("2001:db8:1::5"), "2001:DB8:2:0:0:0:0:7"), [])
      assert conn.private[:nebu_client_ip] == "2001:db8:2::7"

      ClientIP.configure(nil)
      mapped = ClientIPPlug.call(req(ip!("::ffff:198.51.100.9")), [])
      assert mapped.private[:nebu_client_ip] == "198.51.100.9"
    end

    test "default peers keep today's key string byte for byte (IPv4 and native IPv6)" do
      assert ClientIPPlug.call(req({127, 0, 0, 1}), []).private[:nebu_client_ip] == "127.0.0.1"
      assert ClientIPPlug.call(req(ip!("2001:db8::1")), []).private[:nebu_client_ip] == "2001:db8::1"
    end

    test "Forwarded and X-Real-IP are ignored entirely (TP6), also when XFF is absent" do
      ClientIP.configure("10.0.0.0/8")

      conn =
        req({10, 0, 0, 5})
        |> put_req_header("forwarded", "for=203.0.113.7")
        |> put_req_header("x-real-ip", "203.0.113.8")

      assert ClientIPPlug.call(conn, []).private[:nebu_client_ip] == "10.0.0.5"
    end

    test "multiple x-forwarded-for header lines are honoured in request order" do
      ClientIP.configure("10.0.0.0/8")
      conn = %{req({10, 0, 0, 5}) | req_headers: [{"x-forwarded-for", "203.0.113.7"}, {"x-forwarded-for", "10.0.0.9"}]}
      assert ClientIPPlug.call(conn, []).private[:nebu_client_ip] == "203.0.113.7"
    end

    test "the plug is registered in Nebu.Web.Router right after RequestId (before RequestLogger)" do
      src = File.read!(Path.expand("../../../lib/nebu/web/router.ex", __DIR__))
      idx = fn name ->
        case Regex.run(Regex.compile!("^\\s*plug Nebu\\.Web\\.Plugs\\." <> name <> "\\s*$", "m"), src, return: :index) do
          [{at, _}] -> at
          nil -> flunk("`plug Nebu.Web.Plugs.#{name}` not found in router.ex")
        end
      end

      rid = idx.("RequestId")
      cip = idx.("ClientIP")
      rlog = idx.("RequestLogger")
      assert rid < cip and cip < rlog, "ClientIP must sit between RequestId and RequestLogger"

      between = binary_part(src, rid, cip - rid)
      assert length(Regex.scan(~r/^\s*plug\s/m, between)) == 1,
             "no other plug between RequestId and ClientIP (only the RequestId line itself)"
    end
  end

  describe "AC4.2 — Nebu.Web.ClientIP.get/1" do
    test "returns the private value when the plug ran" do
      conn = Plug.Conn.put_private(req({10, 0, 0, 5}), :nebu_client_ip, "203.0.113.7")
      assert ClientIP.get(conn) == "203.0.113.7"
    end

    test "without the plug: the normalised PEER string, even with XFF and a trusted peer (bypass = no spoof)" do
      ClientIP.configure("10.0.0.0/8")
      assert ClientIP.get(req({10, 0, 0, 5}, "203.0.113.7")) == "10.0.0.5"
    end

    test "without the plug: a mapped peer is normalised to IPv4" do
      assert ClientIP.get(req(ip!("::ffff:10.0.0.5"))) == "10.0.0.5"
    end

    test "without the plug: native IPv6 peer string equals today's key (:inet.ntoa)" do
      assert ClientIP.get(req(ip!("2001:DB8::1"))) == "2001:db8::1"
    end

    test "a non-tuple remote_ip is converted with to_string/1 (parity with the old ip_key/1)" do
      assert ClientIP.get(%{conn(:get, "/") | remote_ip: "weird"}) == "weird"
    end

    test "the plug result and get/1 agree for a full plug pass" do
      ClientIP.configure("10.0.0.0/8")
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, "203.0.113.7"), [])
      assert ClientIP.get(conn) == "203.0.113.7"
    end
  end

  describe "AC4.2 — Nebu.Web.ClientIP.bucket/1 (rate-limit key, TP8)" do
    test "IPv4 is the unchanged get/1 string" do
      assert ClientIP.bucket(req({198, 51, 100, 9})) == "198.51.100.9"
      assert ClientIP.bucket(ClientIPPlug.call(req({198, 51, 100, 9}), [])) == "198.51.100.9"
    end

    test "a mapped IPv6 peer is IPv4 (already normalised), not a /64" do
      assert ClientIP.bucket(req(ip!("::ffff:198.51.100.9"))) == "198.51.100.9"
    end

    test "native IPv6 is aggregated to its /64 network in canonical form (with and without the plug)" do
      assert ClientIP.bucket(req(ip!("2001:DB8:1:2:aaaa:bbbb:cccc:dddd"))) == "2001:db8:1:2::/64"
      assert ClientIP.bucket(ClientIPPlug.call(req(ip!("2001:db8:1:2::7")), [])) == "2001:db8:1:2::/64"
      assert ClientIP.bucket(req(ip!("2001:db8::1"))) == "2001:db8::/64"
    end

    test "two addresses in one /64 share a bucket key, a different /64 does not" do
      a = ClientIP.bucket(ClientIPPlug.call(req(ip!("2001:db8:1:2::1")), []))
      b = ClientIP.bucket(ClientIPPlug.call(req(ip!("2001:db8:1:2:ffff::9")), []))
      c = ClientIP.bucket(ClientIPPlug.call(req(ip!("2001:db8:1:3::1")), []))
      assert a == b
      refute a == c
    end

    test "behind a trusted proxy the FORWARDED IPv6 client is aggregated, the exact address stays in get/1" do
      ClientIP.configure("10.0.0.0/8")
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, "2a00:1450:4001:81::200e"), [])
      assert ClientIP.get(conn) == "2a00:1450:4001:81::200e"
      assert ClientIP.bucket(conn) == "2a00:1450:4001:81::/64"
    end

    test "a bypassed plug can never be spoofed through bucket/1 either (peer only)" do
      ClientIP.configure("10.0.0.0/8")
      assert ClientIP.bucket(req({10, 0, 0, 5}, "203.0.113.7")) == "10.0.0.5"
    end

    test "a non-IP peer string is returned unchanged" do
      assert ClientIP.bucket(%{conn(:get, "/") | remote_ip: "weird"}) == "weird"
    end
  end

  describe "AC4.3 — crash-free guarantee" do
    setup do
      ClientIP.configure("10.0.0.0/8")
      :ok
    end

    test "binary garbage in the header yields a conn with the peer, never a raise" do
      garbage = <<0, 255, 254, 1, 2, 3, 128, 200>> <> <<0xC3, 0x28>> <> "\n\r\0"
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, garbage), [])
      refute conn.halted
      assert conn.private[:nebu_client_ip] == "10.0.0.5"
    end

    test "10 000 commas yield a conn with the peer" do
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, String.duplicate(",", 10_000)), [])
      refute conn.halted
      assert conn.private[:nebu_client_ip] == "10.0.0.5"
    end

    test "a 1 MB header yields a conn with the peer (the 2048-byte cap precedes the split)" do
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, String.duplicate("10.0.0.9, ", 100_000)), [])
      assert conn.private[:nebu_client_ip] == "10.0.0.5"
    end

    test "invalid UTF-8 left of the client: the plug resolves the client, never raises" do
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, <<0xC3, 0x28>> <> ", 203.0.113.7"), [])
      assert conn.private[:nebu_client_ip] == "203.0.113.7"
    end

    test "invalid UTF-8 as the hop reached first yields the peer" do
      conn = ClientIPPlug.call(req({10, 0, 0, 5}, "203.0.113.7, " <> <<0xC3, 0x28>>), [])
      assert conn.private[:nebu_client_ip] == "10.0.0.5"
    end

    test "an empty x-forwarded-for header yields the peer" do
      assert ClientIPPlug.call(req({10, 0, 0, 5}, ""), []).private[:nebu_client_ip] == "10.0.0.5"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Story client-ip-misconfiguration-warnings, W1 (D1, AC1-AC8): throttled WARNING when a request carries
  # X-Forwarded-For but its direct peer is not trusted. Seam (compile-guarded, test builds only, zero-arity,
  # returns seconds): `Application.get_env(:nebu_http, :client_ip_warn_clock_fn)`. Set the seam BEFORE the
  # `ClientIP.configure/1` call that must use it (configure initialises the throttle slot to `now_s - 600`).
  # ════════════════════════════════════════════════════════════════════════════

  @w1_prefix "client IP: a request carried X-Forwarded-For"
  @w1_clock_key :client_ip_warn_clock_fn

  defp w1_count(log), do: length(String.split(log, @w1_prefix)) - 1

  # Installs a fake clock (seconds) and returns the atomics ref that moves it: `set_clock(ref, s)`.
  defp install_clock!(start_s) do
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, 1, start_s)
    previous = Application.fetch_env(:nebu_http, @w1_clock_key)
    Application.put_env(:nebu_http, @w1_clock_key, fn -> :atomics.get(ref, 1) end)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:nebu_http, @w1_clock_key, v)
        :error -> Application.delete_env(:nebu_http, @w1_clock_key)
      end
    end)

    ref
  end

  defp set_clock(ref, seconds), do: :atomics.put(ref, 1, seconds)

  # Source scans must look at CODE only: drop @moduledoc / @doc heredocs and comments (m3 of the test review).
  defp code_only(src) do
    src
    |> String.replace(~r/@(?:moduledoc|doc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s, "")
    |> String.replace(~r/^\s*#[^\n]*$/m, "")
    |> String.replace(~r/\s#(?!\{)\s[^\n]*$/m, "")
  end

  defp atomics?(ref) do
    :atomics.info(ref)
    true
  rescue
    _ -> false
  end

  # every persistent_term entry whose value is an atomics ref (key shape intentionally not assumed)
  defp atomics_entries, do: for({k, v} <- :persistent_term.get(), is_reference(v), atomics?(v), into: %{}, do: {k, v})

  # one untrusted request with the header, returns the captured log
  defp untrusted_xff_log(peer \\ {198, 51, 100, 9}, xff \\ "203.0.113.7") do
    capture_log(fn -> ClientIPPlug.call(req(peer, xff), []) end)
  end

  describe "W1 AC1 - untrusted peer with X-Forwarded-For (no trusted proxy configured)" do
    test "logs exactly ONE warning with the static text and no address; the resolution is unchanged" do
      ClientIP.configure(nil)
      parent = self()

      log =
        capture_log(fn ->
          send(parent, {:conn, ClientIPPlug.call(req({198, 51, 100, 9}, "203.0.113.7"), [])})
        end)

      assert_received {:conn, conn}
      assert w1_count(log) == 1, "exactly one W1 line expected, got: #{log}"
      assert log =~ ~r/\[warning\]\s+#{Regex.escape(@w1_prefix)}/
      assert log =~ "NEBU_TRUSTED_PROXY_CIDRS"
      assert log =~ "ONE rate-limit bucket"
      assert log =~ "07-deployment"
      refute log =~ "198.51.100.9"
      refute log =~ "203.0.113.7"
      refute log =~ "/anything", "no request path"
      refute log =~ ~r/\{\s*198/, "no tuple peer"

      assert conn.private[:nebu_client_ip] == "198.51.100.9"
      assert conn.private[:nebu_client_ip_source] == :peer
      assert conn.private[:nebu_client_bucket] == "198.51.100.9"
      refute conn.halted
    end
  end

  describe "W1 AC2 - which requests warn" do
    test "a configured set and an untrusted peer: one line, resolution unchanged" do
      ClientIP.configure("10.0.0.0/8")
      parent = self()

      log =
        capture_log(fn ->
          send(parent, {:conn, ClientIPPlug.call(req({198, 51, 100, 9}, "203.0.113.7"), [])})
        end)

      assert_received {:conn, conn}
      assert w1_count(log) == 1, "got: #{log}"
      refute log =~ "198.51.100.9"
      refute log =~ "203.0.113.7"
      assert conn.private[:nebu_client_ip] == "198.51.100.9"
      assert conn.private[:nebu_client_ip_source] == :peer
      assert conn.private[:nebu_client_bucket] == "198.51.100.9"
      assert conn.remote_ip == {198, 51, 100, 9}
      refute conn.halted
    end

    test "the line carries no header length: a 1234-byte header from an untrusted peer logs the static text only" do
      ClientIP.configure(nil)
      log = untrusted_xff_log({198, 51, 100, 9}, String.duplicate("a", 1234))
      assert w1_count(log) == 1
      refute log =~ ~r/\b1234\b/
      refute log =~ "aaaa"
      refute log =~ "/anything"
    end

    test "a TRUSTED peer never warns, whatever the header holds (valid, garbage, empty, oversized, binary)" do
      ClientIP.configure("10.0.0.0/8")

      headers = [
        "203.0.113.7",
        "garbage",
        "",
        String.duplicate("10.0.0.9, ", 100_000),
        String.duplicate(",", 10_000),
        <<0xC3, 0x28, 0, 255>>
      ]

      log =
        capture_log(fn ->
          for xff <- headers, do: ClientIPPlug.call(req({10, 0, 0, 5}, xff), [])
        end)

      assert w1_count(log) == 0, "a trusted peer must never produce the W1 line, got: #{log}"
    end

    test "a request WITHOUT the header never warns, trusted or not" do
      ClientIP.configure("10.0.0.0/8")

      log =
        capture_log(fn ->
          ClientIPPlug.call(req({10, 0, 0, 5}), [])
          ClientIPPlug.call(req({198, 51, 100, 9}), [])
        end)

      assert w1_count(log) == 0, "got: #{log}"

      # control: the same untrusted peer WITH the header does warn (the test fails if W1 is missing)
      assert w1_count(untrusted_xff_log()) == 1
    end

    test "an untrusted IPv6 peer behaves like the IPv4 case: one line, no address of any form" do
      ClientIP.configure("10.0.0.0/8")
      log = untrusted_xff_log({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert w1_count(log) == 1, "got: #{log}"
      refute log =~ ~r/2001:db8/i
      refute log =~ "203.0.113.7"
    end

    test "an untrusted IPv4-mapped IPv6 peer behaves like the IPv4 case: one line, no address of any form" do
      ClientIP.configure("10.0.0.0/8")
      log = untrusted_xff_log(ip!("::ffff:198.51.100.9"))
      assert w1_count(log) == 1, "got: #{log}"
      refute log =~ ~r/198\.51\.100|ffff|c633/i
      refute log =~ "203.0.113.7"
    end

    test "an empty or oversized header from an untrusted peer warns too (only the header's presence counts)" do
      for xff <- ["", String.duplicate("a", 100_000)] do
        ClientIP.configure(nil)
        log = untrusted_xff_log({198, 51, 100, 9}, xff)
        assert w1_count(log) == 1, "header #{byte_size(xff)} bytes: got #{String.slice(log, 0, 300)}"
      end
    end

    test "the non-tuple peer clause neither warns nor raises" do
      ClientIP.configure(nil)
      conn = %{req({198, 51, 100, 9}, "203.0.113.7") | remote_ip: "weird"}
      log = capture_log(fn -> assert ClientIPPlug.call(conn, []).private[:nebu_client_ip] == "weird" end)
      assert w1_count(log) == 0
    end
  end

  describe "W1 AC3 - throttle: one line per node and 600 s (fake clock seam)" do
    test "100 requests at one instant log ONE line; +599 s nothing; +600 s exactly one more" do
      clock = install_clock!(1_000_000)
      ClientIP.configure(nil)

      log1 = capture_log(fn -> for _ <- 1..100, do: ClientIPPlug.call(req({198, 51, 100, 9}, "203.0.113.7"), []) end)
      assert w1_count(log1) == 1, "100 requests at the same instant: exactly one line, got #{w1_count(log1)}"

      set_clock(clock, 1_000_599)
      assert w1_count(untrusted_xff_log()) == 0, "+599 s is still inside the window"

      set_clock(clock, 1_000_600)
      assert w1_count(untrusted_xff_log()) == 1, "+600 s opens the next window"
      assert w1_count(untrusted_xff_log()) == 0, "and only one line per window"
    end

    test "the first occurrence after configure/1 logs immediately, also with a NEGATIVE monotonic clock" do
      install_clock!(-5_000)
      ClientIP.configure(nil)
      assert w1_count(untrusted_xff_log()) == 1
      assert w1_count(untrusted_xff_log()) == 0
    end

    test "200 concurrent requests released by a start barrier produce exactly ONE line per window, in 3 rounds (compare_exchange)" do
      clock = install_clock!(2_000_000)
      ClientIP.configure(nil)
      assert w1_count(untrusted_xff_log()) == 1

      for round <- 1..3 do
        set_clock(clock, 2_000_000 + round * 1_200)
        parent = self()

        log =
          capture_log(fn ->
            tasks =
              for _ <- 1..200 do
                Task.async(fn ->
                  send(parent, {:ready, self()})

                  receive do
                    :go -> ClientIPPlug.call(req({198, 51, 100, 9}, "203.0.113.7"), [])
                  end
                end)
              end

            for _ <- 1..200, do: assert_receive({:ready, _}, 5_000)
            for t <- tasks, do: send(t.pid, :go)
            Task.await_many(tasks, 10_000)
          end)

        assert w1_count(log) == 1, "round #{round}: exactly one winner expected, got #{w1_count(log)}"
      end
    end
  end

  describe "W1 AC4 - the throttle is independent of the rate-limit switch" do
    test "with :rate_limit_disabled and NEBU_RATE_LIMIT_DISABLED set, 10 requests still log exactly one line" do
      prev_app = Application.fetch_env(:nebu_http, :rate_limit_disabled)
      prev_sys = System.get_env("NEBU_RATE_LIMIT_DISABLED")
      Application.put_env(:nebu_http, :rate_limit_disabled, true)
      System.put_env("NEBU_RATE_LIMIT_DISABLED", "true")

      on_exit(fn ->
        case prev_app do
          {:ok, v} -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
          :error -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        end

        if prev_sys, do: System.put_env("NEBU_RATE_LIMIT_DISABLED", prev_sys), else: System.delete_env("NEBU_RATE_LIMIT_DISABLED")
      end)

      ClientIP.configure(nil)
      log = capture_log(fn -> for _ <- 1..10, do: ClientIPPlug.call(req({198, 51, 100, 9}, "203.0.113.7"), []) end)
      assert w1_count(log) == 1, "got #{w1_count(log)}"
    end
  end

  describe "W1 AC5 - configure/1 resets the throttle; no slot means no log and no crash" do
    test "a fresh configure/1 makes the next occurrence log immediately" do
      install_clock!(3_000_000)
      ClientIP.configure(nil)
      assert w1_count(untrusted_xff_log()) == 1
      assert w1_count(untrusted_xff_log()) == 0

      ClientIP.configure("10.0.0.0/8")
      assert w1_count(untrusted_xff_log()) == 1, "configure/1 must re-create the throttle slot"
    end

    test "configure/1 itself logs no W1 line (the throttle setup is silent)" do
      log = capture_log([level: :debug], fn -> ClientIP.configure("10.0.0.0/8") end)
      assert w1_count(log) == 0
    end

    test "without any throttle slot in :persistent_term the plug neither logs nor raises" do
      # the slot is whatever configure/1 (re)creates: an atomics ref that is new after the call, under any key
      before = atomics_entries()
      ClientIP.configure(nil)
      slots = for {k, v} <- atomics_entries(), Map.get(before, k) != v, do: {k, v}
      assert slots != [], "configure/1 must store a (new) atomics ref in :persistent_term as the throttle slot (D1)"

      on_exit(fn -> for {key, value} <- slots, do: :persistent_term.put(key, value) end)
      for {key, _} <- slots, do: :persistent_term.erase(key)

      parent = self()

      log =
        capture_log(fn ->
          send(parent, {:conn, ClientIPPlug.call(req({198, 51, 100, 9}, "203.0.113.7"), [])})
        end)

      assert_received {:conn, conn}
      assert conn.private[:nebu_client_ip] == "198.51.100.9"
      refute conn.halted
      assert w1_count(log) == 0
    end
  end

  describe "W1 AC6 - Forwarded and X-Real-IP stay ignored (TP6)" do
    test "only `forwarded` or only `x-real-ip` from an untrusted peer logs nothing" do
      ClientIP.configure(nil)

      only_forwarded = put_req_header(req({198, 51, 100, 9}), "forwarded", "for=203.0.113.7")
      only_real_ip = put_req_header(req({198, 51, 100, 9}), "x-real-ip", "203.0.113.7")

      log =
        capture_log(fn ->
          ClientIPPlug.call(only_forwarded, [])
          ClientIPPlug.call(only_real_ip, [])
        end)

      assert w1_count(log) == 0, "got: #{log}"

      # control: the actual header does warn (this test fails while W1 is missing)
      assert w1_count(untrusted_xff_log()) == 1
    end
  end

  describe "W1 AC8 - static: the untrusted path is cheap and the log call lives in client_ip.ex" do
    @lib Path.expand("../../../lib", __DIR__)

    test "the plug uses List.keymember?/3, calls get_req_header at most once (trusted branch), logs nothing itself" do
      code = code_only(File.read!(Path.join(@lib, "nebu/web/plugs/client_ip.ex")))
      assert code =~ ~r/List\.keymember\?\(\s*conn\.req_headers,\s*"x-forwarded-for",\s*0\s*\)/
      assert code =~ "note_untrusted_forwarding"
      assert length(String.split(code, "get_req_header")) - 1 <= 1, "no get_req_header call on the untrusted branch"
      refute code =~ "Logger.", "the W1 log call must not sit in the plug"
    end

    test "the throttle and the W1 log call live in lib/nebu/web/client_ip.ex only (no third file)" do
      helper = code_only(File.read!(Path.join(@lib, "nebu/web/client_ip.ex")))
      assert helper =~ ~r/@doc false\s+def note_untrusted_forwarding/
      assert helper =~ ":atomics.compare_exchange"

      third =
        for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
            rel = Path.relative_to(path, @lib),
            rel not in ["nebu/web/client_ip.ex"],
            code_only(File.read!(path)) =~ "note_untrusted_forwarding" or code_only(File.read!(path)) =~ "a request carried X-Forwarded-For",
            rel != "nebu/web/plugs/client_ip.ex",
            do: rel

      assert third == [], "the W1 log line must exist only in client_ip.ex (the plug only calls it): #{inspect(third)}"
    end

    test "the clock seam is read only under Mix.env() == :test, never through RateLimit.take/3" do
      helper = code_only(File.read!(Path.join(@lib, "nebu/web/client_ip.ex")))
      assert helper =~ "client_ip_warn_clock_fn"
      assert helper =~ "Mix.env() == :test"
      refute helper =~ "RateLimit.take"
    end
  end
end
