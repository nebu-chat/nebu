defmodule Nebu.Matrix.UiaAuthdoneElseIfTest do
  @moduledoc """
  Regression for bugfix `matrix-uia-authdone-else-if` (found by the retro Oracle review of `04-sso-confirm-and-result-pages`).

  Matrix spec v1.18, User-Interactive Authentication > Fallback, prescribes for the completion page:

      if (window.onAuthDone) { window.onAuthDone(); } else if (window.opener && window.opener.postMessage) { window.opener.postMessage("authDone", "*"); }

  `Nebu.Matrix.SsoLogin.send_uia_result(conn, :complete)` (the seam `complete_uia/3` calls) ran two independent `if`s, so a client
  that defines `onAuthDone` AND has an opener was notified twice. The inline script is allowed by `script-src 'sha256-...'` in the page
  CSP; the hash is computed at compile time from the same text, and one test here recomputes it over the SERVED script, so a future
  script edit that does not move the hash (or the other way round) fails.

  Pure rendering on a `Plug.Test` conn: no database, no IdP, no JS engine (the page is a fixed string, asserted byte-for-byte).
  Crash/restart: NOT APPLICABLE (no process state).
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoLogin
  alias Nebu.Web.PageShell

  @path "/_matrix/client/v3/login/sso/redirect/oidc?code=SECRETCODE&state=abc123"

  # The spec text, verbatim (Matrix v1.18, UIA > Fallback), on one line.
  @spec_script ~s|if (window.onAuthDone) { window.onAuthDone(); } else if (window.opener && window.opener.postMessage) { window.opener.postMessage("authDone", "*"); }|

  defp complete_page, do: SsoLogin.send_uia_result(conn(:get, @path), :complete)

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  defp served_script(conn) do
    assert length(Regex.scan(~r/<script\b/, conn.resp_body)) == 1, "exactly one script element"
    assert [[script]] = Regex.scan(~r/<script>(.*?)<\/script>/s, conn.resp_body, capture: :all_but_first), "a plain <script> without attributes"
    script
  end

  defp directive(csp, name) do
    csp
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn d -> if d == name or String.starts_with?(d, name <> " "), do: d |> String.trim_leading(name) |> String.trim() end)
  end

  # Scenario: The completion script notifies the client through exactly one path
  #   Given a user who completed the UIA SSO fallback
  #   When the "Authentication complete" page is served
  #   Then its one inline script is `if (window.onAuthDone) { ... } else if (window.opener && window.opener.postMessage) { ... }`
  #   And "authDone" is posted with the target origin "*" exactly as the spec prescribes
  @tag ac: "the-completion-script-notifies-the-client-through-exactly-one-path"
  test "Scenario: The completion script notifies the client through exactly one path" do
    conn = complete_page()
    assert conn.status == 200
    script = served_script(conn)

    # the spec script, byte for byte
    assert script == @spec_script

    # single notification path: the opener branch is an `else if` of the onAuthDone branch, never a second top-level `if`
    assert script =~ "} else if (window.opener && window.opener.postMessage) {"
    assert length(Regex.scan(~r/\bif \(/, script)) == 2, "exactly the `if` and the `else if`"
    refute script =~ ~r/\}\s*\n\s*if \(/, "no second independent `if`"
    refute script =~ ~r/\}\s+if \(/, "no second independent `if`"
    assert length(Regex.scan(~r/window\.onAuthDone\(\)/, script)) == 1
    assert length(Regex.scan(~r/postMessage\(/, script)) == 1, "exactly one postMessage call (the other mention is the guard)"
    assert length(Regex.scan(~r/\.postMessage\("authDone"/, script)) == 1

    # the spec-prescribed wildcard target origin is kept (the client checks ev.origin itself)
    assert script =~ ~s|window.opener.postMessage("authDone", "*");|
  end

  # Scenario: The CSP hash matches the served script exactly
  #   When the "Authentication complete" page is served
  #   Then the script-src hash in the Content-Security-Policy header equals the SHA-256 (base64) of the inline script text of the response body
  @tag ac: "the-csp-hash-matches-the-served-script-exactly"
  test "Scenario: The CSP hash matches the served script exactly" do
    conn = complete_page()
    script = served_script(conn)

    expected = "'sha256-" <> Base.encode64(:crypto.hash(:sha256, script)) <> "'"
    csp = header(conn, "content-security-policy")

    assert directive(csp, "script-src") == expected, "script-src is exactly the hash of the served script, nothing else"
    assert csp == PageShell.csp_with_script(script)

    # the hash is NOT the one of the old two-`if` script
    old = ~s|if (window.onAuthDone) { window.onAuthDone(); }\n| <> ~s|if (window.opener && window.opener.postMessage) { window.opener.postMessage("authDone", "*"); }|
    refute directive(csp, "script-src") == "'sha256-" <> Base.encode64(:crypto.hash(:sha256, old)) <> "'"
  end

  # Scenario: Framing protection and the rest of the policy are unchanged
  #   When the "Authentication complete" page is served
  #   Then the CSP still contains frame-ancestors 'none', default-src 'none', base-uri 'none', form-action 'none', and no COOP header is set
  @tag ac: "framing-protection-and-the-rest-of-the-policy-are-unchanged"
  test "Scenario: Framing protection and the rest of the policy are unchanged" do
    conn = complete_page()
    csp = header(conn, "content-security-policy")

    assert directive(csp, "frame-ancestors") == "'none'"
    assert directive(csp, "default-src") == "'none'"
    assert directive(csp, "base-uri") == "'none'"
    assert directive(csp, "form-action") == "'none'"
    assert directive(csp, "style-src") == "'sha256-#{Base.encode64(:crypto.hash(:sha256, PageShell.css()))}'"
    refute csp =~ "unsafe"
    refute csp =~ "nonce"

    assert header(conn, "cache-control") == "no-store"
    assert header(conn, "cross-origin-opener-policy") == nil, "popup clients need window.opener"
  end
end
