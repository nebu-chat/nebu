defmodule Nebu.Matrix.SsoRedirectClassifyTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (epic SEC gate 3, G3-3), AC1 and
  the D5 origin-list normalizer (the admin form and the callback allowlist share it).

  `Nebu.Matrix.SsoRedirect.classify/1` (D1, D2) is the ONE function that decides what a legacy
  `redirectUrl` is: `{:reject, reason_atom}` | `:direct` | `{:confirmable, %{origin:, host:, port:, path:}}`.
  The rules are evaluated on the RAW string (the string that is stored in the SSO state and later used
  for the `Location`), never through `URI.parse/1`, so there is no parser differential between the checked
  and the used value. `SsoLogin.redirect_url_allowed?/1` stays a boolean and must agree with `classify/1`.

  Every row names the browser interpretation that makes a rejected shape dangerous. Table-driven; no DB.

  The module is reached through `apply/3` so the file compiles without it.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.SsoLogin

  @mod Nebu.Matrix.SsoRedirect

  setup do
    prior = Application.fetch_env(:nebu_http, :sso_redirect_schemes_reader)
    Application.put_env(:nebu_http, :sso_redirect_schemes_reader, fn -> ["myorg-matrix"] end)

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:nebu_http, :sso_redirect_schemes_reader, v)
        :error -> Application.delete_env(:nebu_http, :sso_redirect_schemes_reader)
      end
    end)

    :ok
  end

  defp classify(raw), do: apply(@mod, :classify, [raw])

  defp normalize(raw), do: apply(@mod, :normalize_origin_list, [raw])

  # ════════════════════════════════════════════════════════════════════════════
  # AC1.1 / AC1.4 — rejected shapes (each row: the browser reads something else than the parser)
  # ════════════════════════════════════════════════════════════════════════════

  # {raw, browser interpretation}
  @rejected [
    # backslash: WHATWG treats `\` as `/` in special-scheme URLs
    {"https://evil.example\\@listed.example/", "browser: host evil.example (the backslash ends the authority); Elixir URI.parse sees host listed.example"},
    {"http://evil.example\\@localhost/", "browser goes to evil.example over plain http with the loginToken; URI.parse sees loopback host localhost"},
    {"https:\\\\evil.example", "WHATWG: https://evil.example/ (both backslashes read as slashes)"},
    {"https://example.com/a\\b", "any backslash anywhere is refused, also in the path"},
    {"element://vector\\x", "the backslash rule is a whole-URL rule, also for deep-link schemes"},
    # scheme not followed by exactly `//`
    {"https:evil.example", "WHATWG accepts it as https://evil.example/; URI.parse sees no host"},
    {"https:/evil.example", "WHATWG accepts a single slash as https://evil.example/"},
    {"https:///evil.example", "empty authority then path: WHATWG skips the extra slashes and uses evil.example as host"},
    {"https:////evil.example", "four slashes: WHATWG still yields host evil.example"},
    {"https://", "empty host"},
    # userinfo (display trick)
    {"https://element.example.com@evil/", "the part before @ is userinfo, the browser visits evil"},
    {"http://127.0.0.1@evil/", "looks like loopback, is userinfo for host evil"},
    {"http://x@localhost/", "any userinfo on http is refused"},
    {"https://user:pw@example.com/", "userinfo with a password"},
    {"https://evil.example%2f@listed.example/", "percent-encoded slash inside the authority plus userinfo"},
    # percent-encoded host
    {"https://%65vil.example/", "browsers percent-decode hosts: the visited host is evil.example"},
    # control bytes
    {"https://example.com\t/", "browsers strip tab silently: https://example.com/"},
    {"https://example.com\r\nX: y", "CR/LF: header injection into Location"},
    {"https://example.com/ x", "space"},
    {"https://example.com/a\u0000b", "NUL"},
    {"https://example.com/a\u007Fb", "DEL"},
    {"element://vector/webapp/\n", "control bytes are refused for every scheme"},
    # non-ASCII
    {"https://bücher.example/", "browsers convert the host to punycode (xn--bcher-kva.example): the page and the allowlist must see ASCII"},
    {"https://example.com/é", "any byte above 0x7F in an http(s) URL is refused (clients send serialized ASCII URLs)"},
    # host syntax
    {"https://evil.example./", "trailing dot: a different host name for the allowlist, no valid CSP host-source"},
    {"https://x_y.example/", "underscore is not a valid CSP host-source character"},
    {"https://.example/", "empty first label"},
    {"https://a..b/", "empty label"},
    {"https://[::1]:8443/", "IPv6 literal: not a valid CSP host-source for form-action"},
    {"https://[2001:db8::1]/", "IPv6 literal"},
    # numeric-looking hosts (WHATWG parses these as IPv4)
    {"https://0x7f.0.0.1/", "hex label: 127.0.0.1"},
    {"https://0X7F.0.0.1/", "upper-case hex label: 127.0.0.1"},
    {"https://2130706433/", "single decimal number: 127.0.0.1"},
    {"https://10.1/", "fewer than four parts: 10.0.0.1"},
    {"https://010.0.0.1/", "leading zero: octal 8.0.0.1"},
    {"https://1.2.3.256/", "out-of-range label (WHATWG: invalid IPv4 host, the displayed host would differ)"},
    {"https://1.2.3.4.5/", "five numeric labels"},
    {"https://1.2.3/", "three numeric labels: 1.2.0.3"},
    # ports
    {"https://example.com:0/", "port 0"},
    {"https://example.com:99999/", "port above 65535"},
    {"https://example.com:65536/", "port above 65535"},
    {"https://example.com:/", "empty port"},
    {"https://example.com:80a/", "non-digit port"},
    {"https://example.123/", "last label all digits: WHATWG parses a numeric host, not canonical dotted-decimal IPv4"},
    # http: loopback lookalikes
    {"http://localhost.evil.example/", "http host is not loopback"},
    {"http://127.1/", "WHATWG: 127.0.0.1, but not the literal loopback the allowlist names"},
    {"http://0x7f000001/", "hex IPv4"},
    {"http://0x7f.0.0.1/", "hex label"},
    {"http://2130706433/", "decimal IPv4"},
    {"http://localhost./", "trailing dot"},
    {"http://[::1]:8080/", "IPv6 loopback is NOT added by this story (follow-up cd)"},
    {"http://localhost:0/", "loopback with port 0"},
    {"http://localhost:/", "loopback with an empty port"},
    {"http://localhost%2f@evil/", "percent-encoded slash plus userinfo: the browser visits evil"},
    {"http://localhost:99999/", "loopback with an invalid port"},
    {"http://evil.example/steal", "plain http to a non-loopback host"},
    # denylisted / unknown schemes, relative
    {"javascript:alert(1)", "denylisted scheme"},
    {"data:text/html,<script>1</script>", "denylisted scheme"},
    {"file:///etc/passwd", "denylisted scheme"},
    {"vbscript:msgbox(1)", "denylisted scheme"},
    {"blob:https://example.com/uuid", "denylisted scheme"},
    {"evilscheme://x", "unknown scheme"},
    {"/relative/path", "relative URL"},
    {"example.com", "no scheme"},
    {"", "empty"}
  ]

  describe "AC1.1/AC1.4 — rejected: {:reject, reason} and redirect_url_allowed?/1 == false" do
    for {raw, why} <- @rejected do
      test "rejects #{inspect(raw, limit: 70, printable_limit: 70)} (#{String.slice(why, 0, 60)})" do
        assert {:reject, reason} = classify(unquote(raw))
        assert is_atom(reason), "the rejection reason is an atom"
        refute SsoLogin.redirect_url_allowed?(unquote(raw)), "redirect_url_allowed?/1 must agree with classify/1"
      end
    end

    test "a non-binary value is rejected too (a list from `redirectUrl[]=`, nil)" do
      assert {:reject, _} = classify(nil)
      assert {:reject, _} = classify(["https://a.example/"])
      assert {:reject, _} = classify(%{"x" => "y"})
      refute SsoLogin.redirect_url_allowed?(nil)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1.1 / AC1.5 — :direct (unchanged behaviour: loopback http, default and operator deep-link schemes)
  # ════════════════════════════════════════════════════════════════════════════

  @direct [
    "http://localhost:7070/#/home",
    "http://127.0.0.1:9000/cb",
    "http://localhost",
    "http://localhost:3001//login",
    "http://LOCALHOST:3001/cb",
    "http://127.0.0.1",
    "element://vector/webapp/",
    "element://vector/webapp/?element-desktop-ssoid=abc#/login",
    "ELEMENT://vector/webapp/",
    "schildichat://login",
    "im.fluffychat.auth://login",
    "myorg-matrix://login?token=x"
  ]

  describe "AC1.1/AC1.5 — :direct" do
    for raw <- @direct do
      test "classifies as :direct #{inspect(raw, limit: 70, printable_limit: 70)}" do
        assert classify(unquote(raw)) == :direct
        assert SsoLogin.redirect_url_allowed?(unquote(raw))
      end
    end

    test "an operator extra scheme is :direct only while it is configured; a denylisted scheme never is" do
      Application.put_env(:nebu_http, :sso_redirect_schemes_reader, fn -> [] end)
      assert {:reject, _} = classify("myorg-matrix://login")

      Application.put_env(:nebu_http, :sso_redirect_schemes_reader, fn -> ["javascript", "myorg-matrix"] end)
      assert classify("myorg-matrix://login") == :direct
      assert {:reject, _} = classify("javascript:alert(1)")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1.2 / AC1.5 — {:confirmable, target}: normalization
  # ════════════════════════════════════════════════════════════════════════════

  # {raw, origin, host, port, path}
  @confirmable [
    {"https://Example.COM:443/a?b#c", "https://example.com", "example.com", nil, "/a"},
    {"https://example.com:8443", "https://example.com:8443", "example.com", 8443, ""},
    {"https://example.com:0443/", "https://example.com", "example.com", nil, "/"},
    {"HTTPS://HOST/", "https://host", "host", nil, "/"},
    {"https://example.com:443", "https://example.com", "example.com", nil, ""},
    {"https://xn--bcher-kva.example/", "https://xn--bcher-kva.example", "xn--bcher-kva.example", nil, "/"},
    # oracle m1: real client shapes that the stricter rules must NOT break
    {"https://app.ex/#/user/@bob:ex.org", "https://app.ex", "app.ex", nil, "/"},
    {"https://app.ex/#/room/#a:ex.org", "https://app.ex", "app.ex", nil, "/"},
    {"https://app.ex/p%20q?x=%2F", "https://app.ex", "app.ex", nil, "/p%20q"},
    {"https://app.ex?x=1#/login", "https://app.ex", "app.ex", nil, ""},
    {"https://app.example.com/#/home", "https://app.example.com", "app.example.com", nil, "/"},
    {"https://app.example.com/?updated=1#/login", "https://app.example.com", "app.example.com", nil, "/"},
    {"https://10.0.0.5:8443/", "https://10.0.0.5:8443", "10.0.0.5", 8443, "/"},
    {"https://255.255.255.255/x", "https://255.255.255.255", "255.255.255.255", nil, "/x"},
    # the internal UIA marker is never classified by the server, a CLIENT-supplied one is an ordinary target
    {"https://uia.local/complete", "https://uia.local", "uia.local", nil, "/complete"},
    # `@` outside the authority is NOT userinfo (oracle m1): query, fragment and path of a real client URL
    {"https://app.ex?next=a@b/c", "https://app.ex", "app.ex", nil, ""},
    {"https://app.ex#@x/y", "https://app.ex", "app.ex", nil, ""},
    {"https://app.ex/p@q", "https://app.ex", "app.ex", nil, "/p@q"},
    {"https://app.ex/?e=a@b", "https://app.ex", "app.ex", nil, "/"},
    # digits in a NON-last label, and a canonical IPv4 with zero labels, are ordinary hosts
    {"https://1.example/", "https://1.example", "1.example", nil, "/"},
    {"https://10.0.0.0/", "https://10.0.0.0", "10.0.0.0", nil, "/"},
    {"https://a-1.example/", "https://a-1.example", "a-1.example", nil, "/"},
    # a label that merely STARTS with `0x` only matters for an all-numeric-looking host: this is a normal host name
    {"https://0xample.example/", "https://0xample.example", "0xample.example", nil, "/"}
  ]

  describe "AC1.2/AC1.5 — {:confirmable, target} with a normalized origin" do
    for {raw, origin, host, port, path} <- @confirmable do
      test "classifies as confirmable #{inspect(raw, limit: 70, printable_limit: 70)}" do
        assert {:confirmable, target} = classify(unquote(raw))
        assert target.origin == unquote(origin)
        assert target.host == unquote(host)
        assert target.port == unquote(port)
        assert target.path == unquote(path)
        assert SsoLogin.redirect_url_allowed?(unquote(raw))
      end
    end

    test "the target carries exactly the four documented fields" do
      assert {:confirmable, target} = classify("https://app.example.com:8443/cb?x=1#f")
      assert target |> Map.keys() |> Enum.sort() == [:host, :origin, :path, :port]
    end

    test "the query and the fragment never reach the target (path stops at ? and #)" do
      assert {:confirmable, %{path: "/cb"}} = classify("https://app.example.com/cb?secret=q1#frag1")
      assert {:confirmable, %{path: ""}} = classify("https://app.example.com#frag1")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1.3 — 2048 byte cap
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1.3 — length cap (bytes)" do
    test "an https URL of exactly 2048 bytes is accepted, 2049 is rejected" do
      base = "https://example.com/"
      ok = base <> String.duplicate("a", 2048 - byte_size(base))
      too_long = ok <> "a"
      assert byte_size(ok) == 2048 and byte_size(too_long) == 2049
      assert {:confirmable, _} = classify(ok)
      assert {:reject, _} = classify(too_long)
      refute SsoLogin.redirect_url_allowed?(too_long)
    end

    test "a deep-link URL of exactly 2048 bytes is accepted, 2049 is rejected" do
      base = "element://vector/"
      ok = base <> String.duplicate("a", 2048 - byte_size(base))
      assert byte_size(ok) == 2048
      assert classify(ok) == :direct
      assert {:reject, _} = classify(ok <> "a")
    end

    test "a loopback URL over 2048 bytes is rejected as well" do
      long = "http://localhost:7070/" <> String.duplicate("a", 2100)
      assert {:reject, _} = classify(long)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # D5 — Nebu.Matrix.SsoRedirect.normalize_origin_list/1 (one validator for the admin form and the callback)
  # ════════════════════════════════════════════════════════════════════════════

  @normalized_ok [
    {"https://Chat.Example.com:443/, https://web.example.com:8443, https://chat.example.com", "https://chat.example.com, https://web.example.com:8443"},
    {"", ""},
    {"https://a.example", "https://a.example"},
    {" https://a.example\t", "https://a.example"},
    {"https://b.example, https://a.example, https://B.example", "https://b.example, https://a.example"},
    {"HTTPS://A.EXAMPLE", "https://a.example"},
    {"https://xn--bcher-kva.example", "https://xn--bcher-kva.example"},
    {"https://10.0.0.5:8443/", "https://10.0.0.5:8443"},
    {"https://a.example/", "https://a.example"},
    {"https://a.example:443", "https://a.example"}
  ]

  describe "D5 — normalize_origin_list/1 accepts and normalizes" do
    for {raw, expected} <- @normalized_ok do
      test "normalizes #{inspect(raw, limit: 70, printable_limit: 70)}" do
        assert normalize(unquote(raw)) == {:ok, unquote(expected)}
      end
    end

    test "50 origins are accepted (the documented maximum)" do
      list = Enum.map_join(1..50, ", ", &"https://h#{&1}.example")
      assert {:ok, normalized} = normalize(list)
      assert String.split(normalized, ", ") |> length() == 50
    end
  end

  @normalized_bad [
    {"http://x.example", "http scheme"},
    {"https://*.example", "wildcard"},
    {"https://x.example/path", "path"},
    {"https://x.example/?q", "query"},
    {"https://x.example#f", "fragment"},
    {"https://u@x.example", "userinfo"},
    {"https://bücher.example", "non-ASCII (the message names the xn-- form)"},
    {"https://x.example.", "trailing dot"},
    {"https://[::1]", "IPv6 literal"},
    {"https://x.example:0", "port 0"},
    {"https://x.example:70000", "port above 65535"},
    {"https://x_y.example", "underscore"},
    {"a,,b", "empty token"},
    {"https://a.example, ,https://b.example", "whitespace-only token"},
    {"https://a.example,", "trailing comma (empty token)"},
    {"https://x.example\n", "trailing newline (the regex is \\z-anchored, only space and tab are trimmed)"},
    {"https://x.example\r", "trailing carriage return"},
    {"x.example", "no scheme"},
    {"https://", "empty host"},
    {"https://1.2.3.256", "out-of-range numeric host"},
    {"https://0x7f.0.0.1", "hex numeric host"},
    {"https://%65vil.example", "percent in the authority"},
    {"https://x.example\\y", "backslash"},
    {"https://a.example//", "more than a single trailing slash is a path"}
  ]

  describe "D5 — normalize_origin_list/1 rejects (nothing is persisted on an error)" do
    for {raw, why} <- @normalized_bad do
      test "normalizer rejects #{inspect(raw, limit: 70, printable_limit: 70)} (#{why})" do
        assert {:error, message} = normalize(unquote(raw))
        assert is_binary(message) and message != ""
      end
    end

    test "51 origins are rejected" do
      list = Enum.map_join(1..51, ", ", &"https://h#{&1}.example")
      assert {:error, _} = normalize(list)
    end

    test "a value over 4096 characters is rejected even with at most 50 origins" do
      host = String.duplicate("a", 60) <> "." <> String.duplicate("b", 60) <> ".example"
      list = Enum.map_join(1..40, ", ", &"https://#{&1}#{host}")
      assert String.length(list) > 4096
      assert {:error, _} = normalize(list)
    end

    test "the message names the offending token truncated to 80 characters" do
      token = "https://x.example/" <> String.duplicate("p", 120)
      assert {:error, message} = normalize("https://ok.example, " <> token)
      assert message =~ String.slice(token, 0, 80)
      refute message =~ String.slice(token, 0, 81), "the token is cut at 80 characters"
    end

    test "the message of a non-ASCII host names the xn-- form" do
      assert {:error, message} = normalize("https://bücher.example")
      assert message =~ "xn--"
    end

    test "a valid list before an invalid token is rejected as a whole (no partial result)" do
      assert {:error, _} = normalize("https://ok.example, http://bad.example")
    end
  end

  describe "D5 — one implementation, reached through the Matrix facade" do
    test "Nebu.Matrix.normalize_sso_redirect_origins/1 delegates to SsoRedirect.normalize_origin_list/1" do
      assert {:module, Nebu.Matrix} = Code.ensure_loaded(Nebu.Matrix)
      assert function_exported?(Nebu.Matrix, :normalize_sso_redirect_origins, 1)

      for raw <- ["", "https://A.example:443/", "http://nope.example", "a,,b"] do
        assert apply(Nebu.Matrix, :normalize_sso_redirect_origins, [raw]) == normalize(raw)
      end
    end
  end

  describe "code review MIN-3 — SsoRedirect.valid_https_host?/1 is the ONE https host validator" do
    test "valid ASCII hosts, IDN in its xn-- form, canonical IPv4" do
      for host <- ["example.com", "a-1.example", "xn--bcher-kva.example", "localhost", "10.0.0.5", "0xample.example", "a.b.c.d.example"] do
        assert apply(@mod, :valid_https_host?, [host]) == true, host
      end
    end

    test "everything the D2 host rule rejects is invalid, and a non-binary never raises" do
      for host <- ["", "exa mple.com", "a..b", "evil.example.", ".example", "x_y.example", "bücher.example", "[::1]", "a@b", "a:80", "a/b", "0x7f.0.0.1", "2130706433", "1.2.3.256", "A\n"] do
        assert apply(@mod, :valid_https_host?, [host]) == false, inspect(host)
      end

      for other <- [nil, 5, :host, ["a.example"]], do: assert(apply(@mod, :valid_https_host?, [other]) == false)
    end

    test "a host of 254 characters or more is invalid (the CSP host-source limit used by the page)" do
      long = String.duplicate("a", 251) <> ".ex"
      assert apply(@mod, :valid_https_host?, [long]) == false
    end
  end
end
