defmodule Nebu.OAuth.DeviceNamingChainTest do
  @moduledoc """
  ATDD for story `01-device-naming-chain` (REQ-2026-016) - Every OAuth device gets a clean, recognisable name.

  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"` (a few extra edge-case tests of the same scenario repeat the tag). Red until the
  story is implemented. Everything runs through the REAL flow (authorize -> IdP stub -> callback -> consent page -> Allow POST -> token endpoint) and the
  real Matrix device API, real database, `--include integration`. The pure sanitising table of `Nebu.OAuth.DeviceName` is in `device_name_test.exs`.

  ## Contract pinned here (names are the ATDD agent's; the dev may deviate only with a note in the story's `## Decisions`)

    * The consent page (`GET /oauth2/consent`, `data-page="oauth-consent"`) shows the name that WILL be given in ONE labelled line carrying
      `data-role="device-name"`, HTML-escaped. When Nebu derived a name (client_name, else the https host of client_uri) the page has NO name input.
    * When nothing can be derived, the page carries a text input `name="device_name"` that is `required`, has `maxlength="64"` and a `<label for=...>`.
      The consent POST carries the typed value in the form field `device_name` (next to `csrf_token` and `decision`).
    * An Allow without a usable name (field missing, empty, only invisible characters after sanitising) is refused by showing the consent page again
      (status 200, 400 or 422, never a redirect): nothing consumed (the consent row stays, the same cookie and CSRF token still work), no code, no device.
    * A typed name is stored exactly as typed after sanitising, WITHOUT a suffix. A `device_name` posted although a name was derived is ignored.
    * `remembered?/3` of `Nebu.OAuth.Authorize` fails towards asking: a remembered Allow does not skip the page when the device is new (or has a NULL
      name) and no name can be derived.
    * Neither the typed name nor the derived name appears in a log line.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Nebu.OAuth.ConsentGrantTestSupport, as: G
  alias Nebu.OAuth.DeviceNameTestSupport, as: D
  alias Nebu.OAuth.TestSupport, as: T

  setup do
    {:ok, D.setup_env!()}
  end

  # -- helpers -----------------------------------------------------------------

  defp client!(opts), do: T.oauth_client!([D.redirect()], opts)

  # a client from which no name can be derived: no client_name, no client_uri
  defp nameless_client!, do: client!(client_name: nil, client_uri: nil)

  # authorize -> IdP stub -> callback; asserts the consent page is asked for
  defp ask!(cid, priv, device, opts \\ []) do
    login = G.login(cid, priv, Keyword.get_lazy(opts, :sub, &T.unique_sub/0), [device: device] ++ Keyword.take(opts, [:prompt]))
    G.assert_consent!(login)
  end

  defp page!(login) do
    page = T.consent_get(login.cb)
    assert page.status == 200, "the consent page must render, got #{G.describe(page)}"
    assert page.resp_body =~ ~r/<main[^>]*data-page="oauth-consent"/
    page
  end

  defp esc(text), do: text |> Plug.HTML.html_escape() |> IO.iodata_to_binary()

  defp name_input(page), do: page.resp_body |> then(&Regex.run(~r/<input\b[^>]*\bname="device_name"[^>]*>/s, &1)) |> then(&(&1 && hd(&1)))

  defp asks_for_name?(page), do: name_input(page) != nil

  # the page names the device that WILL be created, in the labelled line
  defp assert_shows_name!(page, name) do
    assert page.resp_body =~ ~r/data-role="device-name"/, "the consent page has no device-name line (data-role=\"device-name\")"
    assert String.contains?(page.resp_body, esc(name)), "the consent page must show the device name #{inspect(name)}"
  end

  defp assert_asks_for_name!(page) do
    input = name_input(page) || flunk("the consent page must ask for a device name (input name=\"device_name\")")
    assert input =~ ~r/\brequired\b/, "the name input must be required: #{input}"
    assert input =~ ~r/maxlength="64"/, "the name input must be bounded to 64 characters: #{input}"
    [_, id] = Regex.run(~r/\bid="([^"]+)"/, input) || flunk("the name input needs an id for its label: #{input}")
    assert page.resp_body =~ ~r/<label\b[^>]*\bfor="#{Regex.escape(id)}"/, "the name input needs a <label for=\"#{id}\">"
  end

  defp refute_name_input!(page), do: refute(asks_for_name?(page), "a derived name must not be asked for again")

  defp allow(login, page, fields \\ []) do
    T.consent_post([{"csrf_token", T.csrf_from(page)}, {"decision", "allow"}] ++ fields, cookie: login.cb)
  end

  # the user clicks Allow; asserts the 303 to the client and redeems the code. Returns the token body.
  defp allowed!(login, conn) do
    assert conn.status == 303, "Allow must 303 to the client, got #{G.describe(conn)}"
    {_base, _mode, params, _names} = T.client_redirect(conn)
    code = params["code"] || flunk("no code after Allow: #{inspect(params)}")
    T.redeem!(%{client_id: login.cid, code: code, redirect_uri: login.redirect, verifier: login.verifier})
  end

  # an Allow that must be REFUSED: the page again, nothing consumed, no code, no device
  defp assert_refused!(login, conn, why) do
    assert conn.status in [200, 400, 422], "#{why}: expected the page again, got #{G.describe(conn)}"
    assert T.location(conn) == nil, "#{why}: no redirect when the name is missing"
    assert conn.resp_body =~ ~r/<main[^>]*data-page="oauth-consent"/, "#{why}: the consent page must be shown again"
    assert asks_for_name?(conn), "#{why}: the shown page must ask for a name again"
    assert T.consent_row_of(login.cb) != nil, "#{why}: the consent request must not be consumed"
    assert T.count_for("oauth_codes", login.cid) == 0, "#{why}: no code may be issued"
    assert D.device_row(login.user_id, login.device) == nil, "#{why}: no device may be created"
  end

  defp suffix_of(device), do: String.slice(device, -8, 8)

  # -- scenario 1 --------------------------------------------------------------

  # Scenario: A usable client name is shown on the Allow page and given to the device
  #   Given an approved client named "FluffyChat" and a new device with id "ABCD1234"
  #   When the user opens the Allow page and allows
  #   Then the page shows the device name "FluffyChat (ABCD1234)" and the device is created with exactly that display name
  @tag ac: "a-usable-client-name-is-shown-on-the-allow-page-and-given-to-the"
  test "Scenario: A usable client name is shown on the Allow page and given to the device", %{cid: cid, priv: priv} do
    login = ask!(cid, priv, "ABCD1234")
    page = page!(login)

    assert_shows_name!(page, "FluffyChat (ABCD1234)")
    refute_name_input!(page)
    refute page.resp_body =~ "client.example.com (", "the client name wins over the website host"

    token = allowed!(login, allow(login, page))

    assert D.name_of(login.user_id, "ABCD1234") == "FluffyChat (ABCD1234)"
    assert [%{"device_id" => "ABCD1234", "display_name" => "FluffyChat (ABCD1234)"}] = D.list_devices!(token["access_token"])
  end

  @tag ac: "a-usable-client-name-is-shown-on-the-allow-page-and-given-to-the"
  test "the shown name is the sanitised client name, HTML-escaped; a forged device_name field does not override a derived name", %{priv: priv} do
    cid = client!(client_name: "<b>Evil\u0007Client</b>")
    login = ask!(cid, priv, "ABCD1234")
    page = page!(login)

    assert_shows_name!(page, "EvilClient (ABCD1234)")
    refute page.resp_body =~ "Evil\u0007Client"
    refute page.resp_body =~ "<b>Evil"

    _token = allowed!(login, allow(login, page, [{"device_name", "Forged name"}]))
    assert D.name_of(login.user_id, "ABCD1234") == "EvilClient (ABCD1234)"
  end

  # -- scenario 2 --------------------------------------------------------------

  # Scenario: Without a usable client name the website host names the device
  #   Given an approved client whose client_name is "App" (generic) and whose client_uri is "https://chat.acme.example/web"
  #   When the user opens the Allow page and allows
  #   Then the page shows the device name "chat.acme.example (<suffix>)" and the device is created with that display name
  @tag ac: "without-a-usable-client-name-the-website-host-names-the-device"
  test "Scenario: Without a usable client name the website host names the device", %{priv: priv} do
    cid = client!(client_name: "App", client_uri: "https://chat.acme.example/web")
    dev = D.device_id()
    login = ask!(cid, priv, dev)
    page = page!(login)

    expected = "chat.acme.example (#{suffix_of(dev)})"
    assert_shows_name!(page, expected)
    refute_name_input!(page)

    _token = allowed!(login, allow(login, page))
    assert D.name_of(login.user_id, dev) == expected
  end

  @tag ac: "without-a-usable-client-name-the-website-host-names-the-device"
  test "every generic client name (case-insensitive, trimmed) and a missing or invisible name falls through to the host; host is lower case without port", %{priv: priv} do
    for client_name <- ["OAuth client", "client", " APP ", "Application", "unknown", "Test", "\u3164", "<b></b>", nil] do
      cid = client!(client_name: client_name, client_uri: "https://Chat.Acme.Example:8443/web?x=1")
      dev = D.device_id()
      login = ask!(cid, priv, dev)
      page = page!(login)

      assert_shows_name!(page, "chat.acme.example (#{suffix_of(dev)})")
      refute_name_input!(page)
      _ = allowed!(login, allow(login, page))
      assert D.name_of(login.user_id, dev) == "chat.acme.example (#{suffix_of(dev)})", "for client_name #{inspect(client_name)}"
    end
  end

  @tag ac: "without-a-usable-client-name-the-website-host-names-the-device"
  test "a usable client name still wins over the host when it merely looks similar to a generic word", %{priv: priv} do
    cid = client!(client_name: "Test Chat", client_uri: "https://chat.acme.example")
    dev = D.device_id()
    login = ask!(cid, priv, dev)
    assert_shows_name!(page!(login), "Test Chat (#{suffix_of(dev)})")
  end

  # -- scenario 3 --------------------------------------------------------------

  # Scenario: When nothing usable exists the user is asked for a name
  #   Given an approved client without a usable client_name and without a usable client_uri
  #   When the user opens the Allow page
  #   Then the page asks for a device name, an Allow without a name is refused with the page shown again and nothing consumed, and an Allow with "Anna's phone" creates the device named exactly "Anna's phone"
  @tag ac: "when-nothing-usable-exists-the-user-is-asked-for-a-name"
  test "Scenario: When nothing usable exists the user is asked for a name", %{priv: priv} do
    dev = D.device_id()
    login = ask!(nameless_client!(), priv, dev)
    page = page!(login)

    assert_asks_for_name!(page)

    # no field at all, then an empty field: refused, the page again, nothing consumed
    assert_refused!(login, allow(login, page), "no device_name field")
    assert_refused!(login, allow(login, page, [{"device_name", ""}]), "empty device_name")

    # the SAME consent request (cookie and CSRF token) still works with a name
    token = allowed!(login, allow(login, page, [{"device_name", "Anna's phone"}]))

    assert D.name_of(login.user_id, dev) == "Anna's phone", "stored exactly as typed, without a suffix"
    assert [%{"device_id" => ^dev, "display_name" => "Anna's phone"}] = D.list_devices!(token["access_token"])
    assert T.consent_row_of(login.cb) == nil, "the successful Allow consumes the consent request"
  end

  @tag ac: "when-nothing-usable-exists-the-user-is-asked-for-a-name"
  test "a generic name without a host, a non-https client_uri and an unparsable client_uri all lead to the question", %{priv: priv} do
    for {client_name, client_uri} <- [
          {"App", nil},
          {"unknown", "http://chat.acme.example"},
          {nil, "ftp://chat.acme.example"},
          {nil, "https://"},
          {"test", "not a uri"}
        ] do
      cid = client!(client_name: client_name, client_uri: client_uri)
      login = ask!(cid, priv, D.device_id())
      assert_asks_for_name!(page!(login))
      refute page!(login).resp_body =~ ~r/data-role="device-name"[^>]*>[^<]*\(/, "no derived name line for #{inspect({client_name, client_uri})}"
    end
  end

  @tag ac: "when-nothing-usable-exists-the-user-is-asked-for-a-name"
  test "neither the typed name nor the question leaves a trace in the logs", %{priv: priv} do
    probe = "LeakProbeName" <> String.upcase(T.rand(4))
    dev = D.device_id()
    original = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original) end)

    log =
      capture_log([level: :debug], fn ->
        login = ask!(nameless_client!(), priv, dev)
        page = page!(login)
        _refused = allow(login, page)
        token = allowed!(login, allow(login, page, [{"device_name", probe}]))
        assert D.name_of(login.user_id, dev) == probe
        assert is_binary(token["access_token"])
      end)

    assert log =~ "OAuth consent: allowed", "control: the capture saw the consent lines"
    leaked = log |> String.split("\n") |> Enum.filter(&String.contains?(&1, probe))
    assert leaked == [], "the typed device name must not be logged, found: #{inspect(leaked)}"
  end

  # -- scenario 4 --------------------------------------------------------------

  # Scenario: A remembered Allow does not skip the question when a new device has no name
  #   Given the user has a remembered Allow for a client from which no name can be derived, and the device id is new
  #   When the client starts a new sign-in
  #   Then the Allow page is shown and asks for a device name, whereas a remembered Allow for a client with a derivable name, or a re-login of a device that already has a name, is still skipped as before
  @tag ac: "a-remembered-allow-does-not-skip-the-question-when-a-new-device-has"
  test "Scenario: A remembered Allow does not skip the question when a new device has no name", %{priv: priv, cid: named_cid} do
    nameless = nameless_client!()
    sub = T.unique_sub()
    user_id = T.user_id_for(%{"sub" => sub})
    :ok = G.insert_grant!(user_id, nameless)
    :ok = G.insert_grant!(user_id, named_cid)
    on_exit(fn -> G.cleanup_grants([user_id]) end)

    # control: a derivable name is still skipped as before
    skipped = G.login(named_cid, priv, sub, device: D.device_id())
    G.assert_skipped!(skipped)

    # the new device of a client without a name: the page is shown and asks
    dev = D.device_id()
    login = G.login(nameless, priv, sub, device: dev) |> G.assert_consent!()
    page = page!(login)
    assert_asks_for_name!(page)
    assert D.device_row(user_id, dev) == nil

    token = allowed!(login, allow(login, page, [{"device_name", "Anna's phone"}]))
    assert D.name_of(user_id, dev) == "Anna's phone"
    assert is_binary(token["access_token"])
  end

  @tag ac: "a-remembered-allow-does-not-skip-the-question-when-a-new-device-has"
  test "a re-login of a device that already has a name is skipped as before; a device with a NULL name asks again", %{priv: priv} do
    cid = nameless_client!()
    sub = T.unique_sub()
    dev = D.device_id()

    # first login: the user is asked, types a name, the Allow is remembered
    first = ask!(cid, priv, dev, sub: sub)
    token = allowed!(first, allow(first, page!(first), [{"device_name", "Anna's phone"}]))
    assert D.name_of(first.user_id, dev) == "Anna's phone"
    on_exit(fn -> G.cleanup_grants([first.user_id]) end)

    # the same device logs in again: it has a name, so the remembered Allow skips the page
    G.assert_skipped!(G.login(cid, priv, sub, device: dev))
    assert D.name_of(first.user_id, dev) == "Anna's phone", "a skipped re-login never touches the name"

    # the client cleared the name (PUT with display_name null = NULL): a nameless device is asked again
    D.clear_name!(token["access_token"], dev)
    assert D.name_of(first.user_id, dev) == nil
    again = G.login(cid, priv, sub, device: dev) |> G.assert_consent!()
    assert_asks_for_name!(page!(again))
  end

  # -- scenario 5 --------------------------------------------------------------

  # Scenario: A typed name is sanitised and a name of only invisible characters counts as empty
  #   Given the Allow page asks for a device name
  #   When the user submits "<b>Work\u0007 laptop</b>" or a name that consists only of invisible characters
  #   Then the device is named "Work laptop" in the first case, and in the second case the page asks again without creating anything
  @tag ac: "a-typed-name-is-sanitised-and-a-name-of-only-invisible-characters"
  test "Scenario: A typed name is sanitised and a name of only invisible characters counts as empty", %{priv: priv} do
    dev = D.device_id()
    login = ask!(nameless_client!(), priv, dev)
    page = page!(login)
    assert_asks_for_name!(page)

    # only invisible characters, markup without text, whitespace: counts as empty, asks again, creates nothing
    for typed <- ["\u3164\u2800\u200B", "   ", "\u0007", "<b></b>", "\u0301\uFE0F", "\t\n"] do
      assert_refused!(login, allow(login, page, [{"device_name", typed}]), "device_name #{inspect(typed)}")
    end

    # the story's example
    _token = allowed!(login, allow(login, page, [{"device_name", "<b>Work\u0007 laptop</b>"}]))
    assert D.name_of(login.user_id, dev) == "Work laptop"
  end

  @tag ac: "a-typed-name-is-sanitised-and-a-name-of-only-invisible-characters"
  test "a hostile typed name never reaches the device row as markup or control text, and an overlong name is bounded", %{priv: priv} do
    cid = nameless_client!()

    for typed <- ["<script>alert(1)</script>Home", "\u202Eevil", "Zero\u200Bwidth", "line\nbreak\r\nand\ttab", "<img src=x onerror=alert(1)>Desk"] do
      dev = D.device_id()
      login = ask!(cid, priv, dev)
      _ = allowed!(login, allow(login, page!(login), [{"device_name", typed}]))
      stored = D.name_of(login.user_id, dev)
      refute D.hostile?(stored), "stored #{inspect(stored)} for the typed name #{inspect(typed)}"
      assert stored != "", "a name with visible text must not be emptied"
    end

    # at most 64 characters: refused or cut, never stored longer, never a server error
    dev = D.device_id()
    login = ask!(cid, priv, dev)
    conn = allow(login, page!(login), [{"device_name", String.duplicate("a", 300)}])
    assert conn.status < 500, "an overlong name must not crash the page, got #{conn.status}"

    if conn.status == 303 do
      _ = allowed!(login, conn)
      assert D.codepoints(D.name_of(login.user_id, dev)) <= 64
    else
      assert D.device_row(login.user_id, dev) == nil
    end
  end

  @tag ac: "a-typed-name-is-sanitised-and-a-name-of-only-invisible-characters"
  test "a typed name is a default like any other: the client's later PUT /devices replaces it", %{priv: priv} do
    dev = D.device_id()
    login = ask!(nameless_client!(), priv, dev)
    token = allowed!(login, allow(login, page!(login), [{"device_name", "Work laptop"}]))
    assert D.name_of(login.user_id, dev) == "Work laptop"

    D.put_name!(token["access_token"], dev, "Renamed by the client")
    assert D.name_of(login.user_id, dev) == "Renamed by the client"
  end
end
