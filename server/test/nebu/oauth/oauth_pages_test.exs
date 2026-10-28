defmodule Nebu.OAuth.OAuthPagesTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-authorize-idp-delegation-code`, AC12 + AC13: the one
  renderer `Nebu.OAuth.Pages` for every non-redirect outcome of the authorize endpoint and the
  OAuth branch of the shared IdP callback.

  ## Contract pinned here (ATDD Decisions (story 2), story file)

      Nebu.OAuth.Pages.send_page(conn, status, error_code, opts \\\\ []) :: Plug.Conn.t()  (sent)
        opts: `client_host:` (only for client_pending / client_rejected; escaped, labelled
              unverified), `retry_after:` (seconds, rate_limited => `Retry-After`),
              `allow:` (method_not_allowed => `Allow`)

  Pure rendering on a `Plug.Test` conn (no DB). Fails today: the module does not exist.
  Crash/restart — NOT APPLICABLE.
  """
  use ExUnit.Case, async: true
  import Plug.Test

  alias Nebu.OAuth.TestSupport, as: T

  @pages Nebu.OAuth.Pages
  defp send_page(status, code, opts \\ []), do: apply(@pages, :send_page, [conn(:get, "/oauth2/authorize"), status, code, opts])

  @codes [
    {400, "unknown_client"},
    {400, "invalid_redirect_uri"},
    {400, "invalid_request"},
    {403, "client_pending"},
    {403, "client_rejected"},
    {400, "invalid_state"},
    {404, "unavailable"},
    {429, "rate_limited"},
    {405, "method_not_allowed"},
    {500, "server_error"},
    # story oauth-authorize-freshness (P3, FR11 / FR8): two new user pages of the consent step
    {403, "device_in_use"},
    {403, "forbidden"}
  ]

  for {status, code} <- @codes do
    describe "AC12 page #{code}" do
      test "accessible structure, hooks, no script/form/img, specific title" do
        conn = send_page(unquote(status), unquote(code), client_host: "client.example.com", retry_after: 60, allow: "GET")
        assert conn.status == unquote(status)
        body = conn.resp_body

        assert body =~ ~r/\A\s*<!doctype html>/i
        assert body =~ ~s(<html lang="en">)
        assert body =~ ~r/<meta charset="utf-8">/i
        assert body =~ ~r/<meta name="viewport"[^>]*width=device-width/i
        assert [_] = Regex.scan(~r/<main\b/, body), "exactly one <main>"
        assert [_] = Regex.scan(~r/<h1\b/, body), "exactly one <h1>"
        assert body =~ ~s(<main data-page="oauth-error" data-error="#{unquote(code)}">)
        [_, title] = Regex.run(~r/<title>([^<]+)<\/title>/, body)
        assert String.length(String.trim(title)) > 5, "specific <title> required"
        assert body =~ ~r/What you can do/i, "plain-language \"What you can do\" section"

        for forbidden <- [~r/<script/i, ~r/<form/i, ~r/<img/i, ~r/<iframe/i, ~r/\son\w+=/i, ~r/href="https?:/i] do
          refute body =~ forbidden, "#{inspect(forbidden)} must not appear on an OAuth page"
        end
      end

      test "AC12/AC13 headers: html content type, strict CSP with the inline style hash, no-store, no CORS" do
        conn = send_page(unquote(status), unquote(code), client_host: "client.example.com", retry_after: 60, allow: "GET")
        assert T.header(conn, "content-type") =~ ~r{^text/html;\s*charset=utf-8}i
        assert T.header(conn, "x-frame-options") == "DENY"
        assert T.header(conn, "cache-control") =~ "no-store"
        assert T.header(conn, "pragma") == "no-cache"
        assert T.header(conn, "referrer-policy") == "no-referrer"
        assert T.header(conn, "access-control-allow-origin") == nil
        assert T.header(conn, "location") == nil

        csp = T.header(conn, "content-security-policy")
        assert csp =~ ~r/^default-src 'none';/
        for d <- ["base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"], do: assert(csp =~ d)

        case Regex.scan(~r/<style>(.*?)<\/style>/s, conn.resp_body) do
          [] ->
            refute csp =~ "style-src", "no style block => no style-src source needed"

          [[_, css]] ->
            hash = :crypto.hash(:sha256, css) |> Base.encode64()
            assert csp =~ "style-src 'sha256-#{hash}'", "CSP must carry the hash of the ONE inline style block"

          many ->
            flunk("exactly one inline <style> block allowed, got #{length(many)}")
        end
      end
    end
  end

  describe "AC12 specific pages" do
    test "client_pending: waiting-for-approval heading, ONLY the escaped client_uri host, labelled unverified" do
      conn = send_page(403, "client_pending", client_host: "client.example.com")
      assert conn.resp_body =~ ~r/<h1[^>]*>\s*This app is waiting for approval\s*<\/h1>/
      assert conn.resp_body =~ "client.example.com"
      assert conn.resp_body =~ ~r/unverified/i
      assert conn.resp_body =~ ~r/administrator/i
    end

    test "client_rejected names the host as unverified, too" do
      conn = send_page(403, "client_rejected", client_host: "client.example.com")
      assert conn.resp_body =~ "client.example.com"
      assert conn.resp_body =~ ~r/unverified/i
    end

    test "the client host is HTML-escaped (Plug.HTML.html_escape/1)" do
      conn = send_page(403, "client_pending", client_host: ~s[<script>alert("x")</script>&])
      refute conn.resp_body =~ "<script>alert"
      assert conn.resp_body =~ "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;&amp;"
    end

    test "invalid_state explains the expired/used link and how to restart" do
      conn = send_page(400, "invalid_state")
      assert conn.resp_body =~ "This sign-in link has expired or was already used."
      assert conn.resp_body =~ "Start signing in again from your app."
    end

    test "device_in_use (FR11): says the app asked to take over a session another app uses, that this is not allowed, and to restart from the app; no client text, no link" do
      conn = send_page(403, "device_in_use", client_host: "evil.example.com")
      body = conn.resp_body
      assert body =~ "This app asked to take over a session that another app is using. This is not allowed."
      assert body =~ ~r/close this window/i
      assert body =~ ~r/start signing in again from your app/i
      refute body =~ "evil.example.com", "the page never renders request-derived values"
      refute body =~ ~r/<a[\s>]/i
      assert T.header(conn, "location") == nil
    end

    test "invalid_state (correction 11): also tells the user to close the window and restart from the app" do
      body = send_page(400, "invalid_state").resp_body
      assert body =~ ~r/close this window/i
    end

    test "rate_limited carries Retry-After; method_not_allowed carries Allow: GET" do
      assert T.header(send_page(429, "rate_limited", retry_after: 42), "retry-after") == "42"
      assert T.header(send_page(405, "method_not_allowed", allow: "GET"), "allow") == "GET"
    end

    test "an unknown error code is normalized to server_error, never rendered into data-error (UX advisory 3)" do
      conn = send_page(500, ~s(x" onload="evil))
      assert conn.resp_body =~ ~s(data-error="server_error")
      refute conn.resp_body =~ "evil"
    end

    test "method_not_allowed text and overflow-safe client host (UX advisories 1 + 8)" do
      assert send_page(405, "method_not_allowed", allow: "GET").resp_body =~
               "This page cannot be opened this way. Start signing in from your app."

      assert send_page(403, "client_pending", client_host: "a.example.com").resp_body =~ "overflow-wrap:anywhere"
    end

    test "pages without client_host never render a host" do
      conn = send_page(400, "unknown_client")
      refute conn.resp_body =~ "client.example.com"
    end
  end
end
