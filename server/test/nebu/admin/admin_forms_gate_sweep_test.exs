defmodule Nebu.Admin.AdminFormsGateSweepTest do
  @moduledoc """
  Story `admin-forms-gate-sweep` (follow-up `de`), AC1, AC3 (decisions D1, D3): every state-changing admin form post / DELETE except the bootstrap wizard needs the strict
  fetch metadata of a user-clicked form submit (Safari: the click proof) BEFORE anything else happens; the refusal and notice pages name the page the admin came from.

  Pinned API: `Nebu.Admin.OAuthAdminHelpers.click_gate/2` (a controller plug, level `:click`) and `Nebu.Admin.OAuthAdminHelpers.back_path/1` (the request path of a
  gated post -> the page the form lives on). The marker forms of the media settings page and the other criteria are in `media_settings_controller_test.exs`, `admin_reauth_test.exs`,
  `storage_config_test.exs`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.Admin.OAuthAdminHelpers, as: H

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-forms-gate-sweep-key-base", 3)
  # the only post / delete routes that are deliberately not gated: the bootstrap wizard (no admin, no IdP sign-in yet)
  @allow_list ["/admin/bootstrap/select-claim", "/admin/bootstrap/step/1", "/admin/bootstrap/step/2", "/admin/bootstrap/step/3"]

  # every writer seam of the gated controllers: a gate that runs AFTER the write would send {:wrote, label} (test-review M5)
  @write_seams [
    {:admin_device_renamer, 3}, {:admin_device_deleter, 2}, {:admin_auto_join_writer, 3}, {:admin_room_visibility_writer, 3}, {:admin_room_creator, 2},
    {:admin_room_archiver, 2}, {:admin_room_unarchiver, 2}, {:admin_member_adder, 3}, {:admin_member_remover, 3}, {:admin_spaces_creator, 2},
    {:admin_spaces_state_writer, 5}, {:admin_spaces_auto_join_writer, 3}, {:admin_logs_retention_writer, 1}, {:media_config_writer, 3}, {:media_storage_config_writer, 2}
  ]

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)

    for {key, arity} <- @write_seams do
      fun =
        case arity do
          1 -> fn _a -> notify(test_pid, key) end
          2 -> fn _a, _b -> notify(test_pid, key) end
          3 -> fn _a, _b, _c -> notify(test_pid, key) end
          5 -> fn _a, _b, _c, _d, _e -> notify(test_pid, key) end
        end

      Application.put_env(:nebu_http, key, fun)
    end

    Application.put_env(:nebu_http, :admin_config_tx, fn _changes, _audit -> notify(test_pid, :admin_config_tx) end)

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_config_tx | Enum.map(@write_seams, &elem(&1, 0))], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp refute_wrote, do: refute_received({:wrote, _})

  defp notify(pid, key) do
    send(pid, {:wrote, key})
    :ok
  end

  defp admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> Map.put(:body_params, %{})
    |> Map.put(:params, %{})
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp state_changing_routes do
    Nebu.Admin.Router
    |> Phoenix.Router.routes()
    |> Enum.filter(&(&1.verb in [:post, :delete, :put, :patch]))
    |> Enum.map(fn r -> {r.verb, r.path} end)
    |> Enum.reject(fn {_verb, path} -> path in @allow_list end)
  end

  defp concrete(path), do: Regex.replace(~r/:([a-z_]+)/, path, "x1")

  describe "AC1 — every state-changing admin route is behind the strict gate" do
    test "the router has the routes this story knows (a guard against a vacuous enumeration)" do
      paths = state_changing_routes() |> Enum.map(&elem(&1, 1))

      for p <- ["/admin/users/:user_id/devices/:device_id", "/admin/rooms", "/admin/rooms/:room_id/members", "/admin/spaces/:space_id/children", "/admin/logs/config/retention", "/admin/media/settings", "/admin/media/settings/storage", "/admin/media/settings/storage/test-connection", "/admin/config/scopes", "/admin/oauth/clients/:client_id/revoke"] do
        assert p in paths, p
      end

      assert length(paths) >= 30
    end

    test "every post / delete route (bootstrap excepted) answers a request WITHOUT fetch metadata with the 403 page and changes nothing" do
      for {verb, path} <- state_changing_routes() do
        conn = admin_conn(verb, concrete(path)) |> call()
        assert conn.status == 403, "#{verb} #{path}: #{conn.status}"
        assert conn.resp_body =~ ~s(data-error="fetch_metadata"), "#{verb} #{path}"
        refute_wrote()
      end
    end

    test "the browser path of a DELETE (POST + _method=DELETE through Plug.MethodOverride) is refused the same way" do
      conn = admin_conn(:post, "/admin/users/x1/devices/x1") |> Map.put(:params, %{"_method" => "DELETE"}) |> Map.put(:body_params, %{"_method" => "DELETE"}) |> call()
      assert conn.status == 403
      assert conn.resp_body =~ ~s(data-error="fetch_metadata")
      refute_wrote()
    end

    test "a fetch() (mode cors, empty destination) is refused on every route, also with a valid-looking set of the other headers" do
      for {verb, path} <- state_changing_routes() do
        conn =
          admin_conn(verb, concrete(path))
          |> put_req_header("sec-fetch-site", "same-origin")
          |> put_req_header("sec-fetch-mode", "cors")
          |> put_req_header("sec-fetch-dest", "empty")
          |> call()

        assert conn.status == 403, "#{verb} #{path}"
        refute_wrote()
      end
    end

    test "the bootstrap wizard stays ungated (the allow list is exactly these four routes, they exist, and a post without fetch metadata is not the gate's 403)" do
      all = Nebu.Admin.Router |> Phoenix.Router.routes() |> Enum.map(&{&1.verb, &1.path})
      for p <- @allow_list, do: assert({:post, p} in all, p)

      for p <- @allow_list, p != "/admin/bootstrap/select-claim" do
        conn = %{conn(:post, p) | secret_key_base: @secret_key_base} |> @endpoint.admin_session([]) |> fetch_session() |> Map.put(:body_params, %{"x" => "y"}) |> Map.put(:params, %{"x" => "y"}) |> call()
        refute conn.resp_body =~ ~s(data-error="fetch_metadata"), p
        refute conn.resp_body =~ "oauth-activation-unproven", p
      end

      # select-claim is excluded from the test CSRF bypass: the CSRF check answers first, the gate is not in front of it either
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        %{conn(:post, "/admin/bootstrap/select-claim") | secret_key_base: @secret_key_base} |> @endpoint.admin_session([]) |> fetch_session() |> call()
      end
    end

    test "require_admin comes first on EVERY route: an anonymous request never gets the gate's refusal or notice page" do
      for {verb, path} <- state_changing_routes() do
        conn = %{conn(verb, concrete(path)) | secret_key_base: @secret_key_base} |> @endpoint.admin_session([]) |> fetch_session() |> Map.put(:body_params, %{}) |> Map.put(:params, %{}) |> call()
        refute conn.resp_body =~ ~s(data-error="fetch_metadata"), "#{verb} #{path}"
        refute conn.resp_body =~ "oauth-activation-unproven", "#{verb} #{path}"
      end
    end

    test "WebKit (no Sec-Fetch-User) WITHOUT the click proof gets the notice page on EVERY route, never a change" do
      for {verb, path} <- state_changing_routes() do
        conn = admin_conn(verb, concrete(path)) |> T.put_safari_fetch_headers() |> call()
        assert conn.status == 200, "#{verb} #{path}: #{conn.status}"
        assert conn.resp_body =~ "oauth-activation-unproven", "#{verb} #{path}"
        refute_wrote()
      end
    end

    test "with the click proof the gate lets a Safari request through: the action runs (here: its validation answers 200 with its own message)" do
      params = T.with_click_proof(%{"info_enabled" => "true", "info_days" => "999"})
      conn = admin_conn(:post, "/admin/logs/config/retention") |> Map.put(:body_params, params) |> Map.put(:params, params) |> T.put_safari_fetch_headers() |> call()
      assert conn.status == 200
      refute conn.resp_body =~ "oauth-activation-unproven"
      refute conn.resp_body =~ ~s(data-error="fetch_metadata")
      assert conn.resp_body =~ "Retention days must be between 1 and 90"
      refute_wrote()
    end

    test "require_admin comes first: a non-admin never sees the gate's refusal page" do
      conn = admin_conn(:post, "/admin/rooms") |> put_session("current_user", %{"admin" => false, "sub" => "u"}) |> call()
      refute conn.resp_body =~ ~s(data-error="fetch_metadata")
      refute conn.status == 200
    end

    test "the gate is a controller plug of every gated controller (static): users, rooms, spaces, logs, media settings" do
      for file <- ["users_controller.ex", "rooms_controller.ex", "spaces_controller.ex", "logs_controller.ex", "media_settings_controller.ex"] do
        src = File.read!(Path.expand("../../../lib/nebu/admin/#{file}", __DIR__))
        assert src =~ ~r/plug :click_gate|plug\(:click_gate|OAuthAdminHelpers\.click_gate|import Nebu\.Admin\.OAuthAdminHelpers/, file
      end

      assert File.read!(Path.expand("../../../lib/nebu/admin/oauth_admin_helpers.ex", __DIR__)) =~ "def click_gate("
    end
  end

  describe "AC3 / D3 — the refusal pages name the page the admin came from" do
    # {method, request path, back link, sidebar key, back label}
    for {verb, path, back, nav, label} <- [
          {:post, "/admin/rooms/r1/members", "/admin/rooms/r1", "rooms", "room page"},
          {:post, "/admin/rooms/r1/auto-join", "/admin/rooms", "rooms", "rooms page"},
          {:post, "/admin/rooms", "/admin/rooms/new", "rooms", "create room form"},
          {:post, "/admin/spaces/s1/children", "/admin/spaces/s1", "spaces", "space page"},
          {:post, "/admin/spaces/s1/auto-join", "/admin/spaces", "spaces", "spaces page"},
          {:delete, "/admin/users/u1/devices/d1", "/admin/users/u1", "users", "user page"},
          {:post, "/admin/logs/config/retention", "/admin/logs/config", "logs-config", "log retention page"},
          {:post, "/admin/media/settings", "/admin/media/settings", "media-settings", "media settings page"},
          {:post, "/admin/media/settings/storage/test-connection", "/admin/media/settings", "media-settings", "media settings page"}
        ] do
      test "#{verb} #{path}: 403 page and Safari notice link back to #{back}, sidebar #{nav}" do
        for variant <- [:forbidden, :unproven] do
          conn = admin_conn(unquote(verb), unquote(path)) |> then(fn c -> if variant == :unproven, do: T.put_safari_fetch_headers(c), else: c end) |> call()
          {:ok, doc} = Floki.parse_document(conn.resp_body)
          assert [link] = Floki.find(doc, ~s(a[data-role="back-to-list"])), "#{variant}"
          assert Floki.attribute(link, "href") == [unquote(back)], "#{variant}"
          assert Floki.text(link) =~ Regex.compile!(unquote(label), "i"), "#{variant}"
          assert [_] = Floki.find(doc, ~s([data-navkey="#{unquote(nav)}"][aria-current="page"])), "#{variant}: sidebar entry"
        end
      end
    end

    test "H.back_path/1 maps the request path of every gated post to its page and never to anything off site" do
      assert H.back_path("/admin/rooms/r1/members/@u:x") == "/admin/rooms/r1"
      assert H.back_path("/admin/rooms/r1/archive") == "/admin/rooms/r1"
      assert H.back_path("/admin/rooms/r1/auto-join") == "/admin/rooms"
      assert H.back_path("/admin/rooms") == "/admin/rooms/new"
      assert H.back_path("/admin/spaces") == "/admin/spaces"
      assert H.back_path("/admin/spaces/s1") == "/admin/spaces/s1"
      assert H.back_path("/admin/spaces/s1/auto-join") == "/admin/spaces"
      assert H.back_path("/admin/users/u1/devices/d1/rename") == "/admin/users/u1"
      assert H.back_path("/admin/logs/config/retention") == "/admin/logs/config"
      assert H.back_path("/admin/media/settings/storage") == "/admin/media/settings"
      # an id that is not a plain path segment falls back to the list, never to an injected target
      assert H.back_path("/admin/rooms/..%2F..%2Fevil/members") == "/admin/rooms"
      assert H.back_path("/admin/rooms//members") == "/admin/rooms"
      assert H.back_path("/somewhere/else") |> String.starts_with?("/admin/")
    end
  end

  describe "AC3 — every form of the admin templates carries the click proof field (static)" do
    @template_dir Path.expand("../../../lib/nebu/admin/templates", __DIR__)
    # the bootstrap wizard is ungated by design (no click proof); the other templates with a csrf form are checked
    @templates for f <- Path.wildcard(Path.join(@template_dir, "**/*.heex")), not String.contains?(f, "/bootstrap/"), do: f

    defp forms(src), do: Regex.scan(~r/<form\b.*?<\/form>/s, src) |> Enum.map(&hd/1)

    test "the templates with forms are found (a guard against a vacuous glob)" do
      assert length(@templates) >= 15
      assert Enum.any?(@templates, &String.ends_with?(&1, "rooms/show.html.heex"))
    end

    for f <- Path.wildcard(Path.expand("../../../lib/nebu/admin/templates/**/*.heex", __DIR__)), not String.contains?(f, "/bootstrap/"), String.contains?(File.read!(f), "_csrf_token") do
      test "#{Path.relative_to(f, Path.expand("../../../lib/nebu/admin/templates", __DIR__))}: every posting form has exactly one _click_proof field" do
        forms = forms(File.read!(unquote(f)))
        posting = Enum.filter(forms, &String.contains?(&1, "_csrf_token"))
        assert posting != []

        for form <- posting do
          proofs = Regex.scan(~r/<input\b[^>]*name="_click_proof"[^>]*data-click-proof[^>]*>/s, form) |> length()
          assert proofs == 1, "a form with #{proofs} click proof fields: #{String.slice(form, 0, 160)}"
        end
      end
    end

    test "19 forms of the eight templates of this story" do
      total =
        for t <- ~w(users/show rooms/new rooms/index rooms/show spaces/index spaces/show logs_config/index media_settings/index), reduce: 0 do
          acc -> acc + (File.read!(Path.join(@template_dir, t <> ".html.heex")) |> forms() |> Enum.count(&String.contains?(&1, "_csrf_token")))
        end

      assert total == 19
    end
  end
end
