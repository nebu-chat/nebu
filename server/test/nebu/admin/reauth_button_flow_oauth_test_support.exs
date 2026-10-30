defmodule Nebu.Admin.ReauthButtonFlowSupport do
  @moduledoc """
  Shared helpers of the story `admin-reauth-button-flow` tests (the `admin_reauth_button_flow_*_test.exs` files).

  ## The contract the tests pin (the story, section "Scope" and "Constraints")

  Every marker-gated admin form renders, decided by the SERVER at render time through `Nebu.Admin.Auth.reauth_fresh(conn, <marker path>)`:

    * STALE (no marker, a marker of another page / subject, an expired marker): INSIDE the form an `<a href>` styled as a button (class `btn`),
      exact text "Sign in again to save" ("... to approve", "... to revoke"), `href` exactly `Nebu.Admin.Auth.reauth_start_path(<marker path>)`,
      `aria-describedby` resolving to existing ids (the reauth hint of the form, for the two mappings also the lock-out hint). NO submit
      control with the normal text of the form (the only submit left is a second, ungated one such as "Test Connection").
    * FRESH: the normal submit button with its normal text, `aria-describedby` resolving to the same hint element(s), and in the hint element a
      text line saying the fresh sign-in is valid, for how many whole minutes (floor, "less than a minute" below 60 s) and for one save. No
      "Sign in again to ..." link inside the form.

  The hint element keeps its id in BOTH states (`#sso-schemes-reauth-hint`, ..., on the confirm pages the element `[data-role="reauth-state"]`, which
  needs an id for `aria-describedby`). The wording of the hints is not pinned beyond key phrases (see `assert_stale_hint/2`, `assert_fresh_hint/3`).
  """
  import ExUnit.Assertions
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth
  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-reauth-button-flow-key-base", 3)
  @sub "reauth-flow-sub-93"

  @config "/admin/config"
  @claim "/admin/config/claim-mapping"
  @role "/admin/config/role-mapping"
  @media "/admin/media/settings"

  # the claims of the fresh sign-in the role mapping marker carries a fingerprint of (what the callback writes)
  @role_token_values ["admins", "groups", "ops-admins"]

  def secret_key_base, do: @secret_key_base
  def sub, do: @sub
  def config_path, do: @config
  def claim_path, do: @claim
  def role_path, do: @role
  def media_path, do: @media
  def approve_path(id), do: "/admin/oauth/registrations/#{id}/approve"
  def revoke_path(id), do: "/admin/oauth/clients/#{id}/revoke"
  def role_token_values, do: @role_token_values

  @doc "The only element of `list` (the failure names `what` and how many there were)."
  def one!(list, what) do
    assert length(list) == 1, "#{what} (found #{length(list)})"
    hd(list)
  end

  # ── the nine forms ────────────────────────────────────────────────────────

  @doc "The seven forms on the four pages that need no database (id, selector, marker path, normal submit text, hint, ids the control must be described by)."
  def forms do
    [
      %{key: :sso_schemes, page: @config, selector: "form#sso-schemes-form", path: @config, normal: "Save SSO schemes", link: "Sign in again to save", hint: "sso-schemes-reauth-hint", describedby: ["sso-schemes-reauth-hint"], keep: []},
      %{key: :sso_origins, page: @config, selector: "form#sso-origins-form", path: @config, normal: "Save SSO origins", link: "Sign in again to save", hint: "sso-origins-reauth-hint", describedby: ["sso-origins-reauth-hint"], keep: []},
      %{key: :oauth_switch, page: @config, selector: "form#oauth-switch-form", path: @config, normal: "Save OAuth settings", link: "Sign in again to save", hint: "oauth-switch-reauth-hint", describedby: ["oauth-switch-reauth-hint"], keep: []},
      %{
        key: :claim_mapping,
        page: @claim,
        selector: ~s(form[action="/admin/config/claim-mapping"]),
        path: @claim,
        normal: "Save",
        link: "Sign in again to save",
        hint: "claim-mapping-reauth-hint",
        describedby: ["claim-mapping-reauth-hint", "claim-mapping-lockout-hint"],
        keep: []
      },
      %{
        key: :role_mapping,
        page: @role,
        selector: ~s(form[action="/admin/config/role-mapping"]),
        path: @role,
        normal: "Save",
        link: "Sign in again to save",
        hint: "role-mapping-reauth-hint",
        describedby: ["role-mapping-reauth-hint", "role-mapping-lockout-hint"],
        keep: []
      },
      %{key: :media_policy, page: @media, selector: "form#media-settings-form", path: @media, normal: "Save", link: "Sign in again to save", hint: "media-policy-reauth-hint", describedby: ["media-policy-reauth-hint"], keep: []},
      %{key: :media_storage, page: @media, selector: "form#media-storage-form", path: @media, normal: "Save", link: "Sign in again to save", hint: "media-storage-reauth-hint", describedby: ["media-storage-reauth-hint"], keep: ["Test Connection"]}
    ]
  end

  def form(key), do: Enum.find(forms(), &(&1.key == key))
  def forms_of(page), do: Enum.filter(forms(), &(&1.page == page))

  @doc "The approve confirm page form (8) of the client `id`."
  def approve_form(id) do
    %{key: :approve, page: approve_path(id), selector: ~s(form[data-role="approve-confirm-form"]), path: approve_path(id), normal: "Approve client", link: "Sign in again to approve", hint: :state, describedby: [], keep: []}
  end

  @doc "The revoke confirm page form (9) of the client `id`."
  def revoke_form(id) do
    %{key: :revoke, page: revoke_path(id), selector: ~s(form[data-role="revoke-confirm-form"]), path: revoke_path(id), normal: "Revoke client", link: "Sign in again to revoke", hint: :state, describedby: [], keep: []}
  end

  # ── requests ──────────────────────────────────────────────────────────────

  def admin_conn(method, path, params \\ nil) do
    conn = %{conn(method, path) | secret_key_base: @secret_key_base}

    conn
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => @sub, "matrix_user_id" => "@admin:test.local"})
    |> then(fn c -> if params, do: c |> Map.put(:body_params, params) |> Map.put(:params, params), else: c end)
  end

  @doc "Puts the `admin_reauth` marker of `path` (opts: `:ago` seconds, `:sub`, `:kind`) into the session; the role mapping page gets the fingerprint the callback writes."
  def with_marker(conn, path, opts \\ []) do
    marker = T.fresh_marker(Keyword.get(opts, :sub, @sub), Keyword.get(opts, :ago, 0), Keyword.get(opts, :kind, "auth_time"), path)
    marker = if path == @role, do: Map.merge(marker, Auth.role_claim_fingerprint(%{"groups" => @role_token_values})), else: marker
    put_session(conn, "admin_reauth", marker)
  end

  def call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  @doc "GET of `path`; `marker`: `nil` or the options of `with_marker/3` (`path:` defaults to `path`)."
  def get(path, marker \\ nil) do
    conn = admin_conn(:get, path)

    conn =
      case marker do
        nil -> conn
        opts -> with_marker(conn, Keyword.get(opts, :path, path |> URI.parse() |> Map.fetch!(:path)), opts)
      end

    call(conn)
  end

  @doc "A user-clicked, form-encoded POST (strict fetch metadata), with the marker of `marker_path` when given (opts of `with_marker/3`)."
  def post(path, params, marker_path \\ :none, opts \\ []) do
    conn = admin_conn(:post, path, params)
    conn = if marker_path == :none, do: conn, else: with_marker(conn, marker_path, opts)
    conn |> T.put_strict_fetch_headers() |> call()
  end

  @doc "The page requested next with the session cookie the response `prev` set (the real cookie round trip)."
  def next_get(prev, path) do
    %{conn(:get, path) | secret_key_base: @secret_key_base} |> recycle_cookies(prev) |> call()
  end

  def doc(conn), do: Floki.parse_document!(conn.resp_body)

  def norm(nodes), do: nodes |> Floki.text(sep: " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  # ── assertions ────────────────────────────────────────────────────────────

  defp the_form(doc, form) do
    f = one!(Floki.find(doc, form.selector), "#{form.key}: exactly one form #{form.selector}")
    f
  end

  defp submit_controls(f) do
    Floki.find(f, "button, input[type=submit], input[type=image]")
    |> Enum.filter(fn n -> Floki.attribute(n, "type") in [[], ["submit"], ["image"]] end)
  end

  defp control_text(node), do: if(Floki.attribute(node, "value") != [] and Floki.attribute(node, "type") == ["submit"], do: hd(Floki.attribute(node, "value")), else: norm(node))

  defp resolved_describedby(doc, control, label) do
    describedby = one!(Floki.attribute(control, "aria-describedby"), "#{label}: the control keeps aria-describedby")
    ids = String.split(describedby)
    assert ids != [], "#{label}: aria-describedby is not empty"

    for id <- ids do
      _ = one!(Floki.find(doc, ~s([id="#{id}"])), "#{label}: aria-describedby #{inspect(id)} resolves to exactly one element")
    end

    ids
  end

  defp hint_id(doc, %{hint: :state} = form) do
    state = one!(Floki.find(doc, ~s([data-role="reauth-state"])), "#{form.key}: one reauth-state element")
    id = one!(Floki.attribute(state, "id"), "#{form.key}: the reauth-state element has an id (aria-describedby needs it)")
    id
  end

  defp hint_id(_doc, form), do: form.hint

  defp hint_text(doc, id) do
    assert [hint] = Floki.find(doc, ~s([id="#{id}"]))
    norm(hint)
  end

  @doc """
  The form is in the STALE state: a link styled as a button replaces the submit, keeps `aria-describedby`; inputs stay editable. Returns the link.
  """
  def assert_stale!(doc, form) do
    f = the_form(doc, form)
    label = "#{form.key} (stale)"

    links = f |> Floki.find("a") |> Enum.filter(&(norm(&1) == form.link))
    link = one!(links, "#{label}: exactly one link with the text #{inspect(form.link)} inside the form")
    assert Floki.attribute(link, "href") == [Auth.reauth_start_path(form.path)], "#{label}: href is reauth_start_path of the page path"
    assert Enum.any?(String.split(hd(Floki.attribute(link, "class") ++ [""])), &(&1 == "btn")), "#{label}: styled as a button (class btn)"
    assert Floki.attribute(link, "onclick") == [], "#{label}: no script"
    assert Floki.attribute(link, "target") == [], "#{label}: same tab"
    refute Floki.attribute(link, "role") == ["button"], "#{label}: a link stays a link for assistive technology"
    # keyboard reachable and visible: not removed from the tab order, not disabled, not hidden
    refute Floki.attribute(link, "tabindex") == ["-1"], "#{label}: the link stays in the tab order (no tabindex=-1)"
    refute Floki.attribute(link, "aria-disabled") in [["true"], [""]], "#{label}: the link is not aria-disabled"
    assert Floki.attribute(link, "hidden") == [], "#{label}: the link is not hidden"
    refute hidden_class?(link), "#{label}: the link is not hidden / sr-only by class"

    case Floki.attribute(link, "aria-label") do
      [] -> :ok
      [name] -> assert String.contains?(name, form.link), "#{label}: an aria-label must contain the visible text (WCAG 2.5.3)"
    end

    ids = resolved_describedby(doc, link, label)
    assert hint_id(doc, form) in ids, "#{label}: the link is described by the reauth hint"
    for id <- form.describedby, do: assert(id in ids, "#{label}: still described by #{id}")

    controls = submit_controls(f) |> Enum.map(&control_text/1) |> Enum.sort()
    assert controls == Enum.sort(form.keep), "#{label}: no submit control left but #{inspect(form.keep)}, got #{inspect(controls)}"
    refute form.normal in controls, "#{label}: no submit with the normal text"

    assert_inputs_editable!(f, label)
    assert_gate_fields!(f, label)
    assert_stale_hint!(doc, form)
    assert_state_attr!(doc, form, "needed")
    link
  end

  @doc "The form is in the FRESH state: the normal submit button, the validity line. `minutes`: `:any`, `:less` or an integer (see `assert_fresh_hint!/3`). Returns the button."
  def assert_fresh!(doc, form, minutes \\ :any) do
    f = the_form(doc, form)
    label = "#{form.key} (fresh)"

    buttons = submit_controls(f) |> Enum.filter(&(control_text(&1) == form.normal))
    button = one!(buttons, "#{label}: exactly one submit button with the text #{inspect(form.normal)}")
    assert Floki.attribute(button, "type") in [["submit"], []], "#{label}: a real submit"
    refute f |> Floki.find("a") |> Enum.any?(&(norm(&1) =~ ~r/sign in again to /i)), "#{label}: no sign-in link in the form"

    ids = resolved_describedby(doc, button, label)
    assert hint_id(doc, form) in ids, "#{label}: the button is described by the validity line"
    for id <- form.describedby, do: assert(id in ids, "#{label}: still described by #{id}")

    others = submit_controls(f) |> Enum.map(&control_text/1) |> Enum.sort()
    assert others == Enum.sort([form.normal | form.keep]), "#{label}: submits are the normal one plus #{inspect(form.keep)}, got #{inspect(others)}"

    assert_gate_fields!(f, label)
    assert_fresh_hint!(doc, form, minutes)
    assert_state_attr!(doc, form, "fresh")
    button
  end

  @doc "True when the node itself carries `hidden`, `sr-only`, `invisible` or `display:none` styling."
  def hidden_class?(node) do
    classes = node |> Floki.attribute("class") |> Enum.join(" ") |> String.split()
    style = node |> Floki.attribute("style") |> Enum.join(" ")
    Floki.attribute(node, "hidden") != [] or Enum.any?(classes, &(&1 in ["hidden", "sr-only", "invisible"])) or style =~ ~r/display\s*:\s*none|visibility\s*:\s*hidden/i
  end

  # the strict fetch metadata / Safari click proof of the submit forms is unchanged: the hidden fields stay in the form in both states
  defp assert_gate_fields!(f, label) do
    _ = one!(Floki.find(f, ~s(input[type="hidden"][name="_csrf_token"])), "#{label}: the CSRF field stays")
    click = one!(Floki.find(f, ~s(input[type="hidden"][name="_click_proof"])), "#{label}: the click proof field stays")
    assert Floki.attribute(click, "data-click-proof") != [], "#{label}: the click proof marker attribute stays"
  end

  defp assert_inputs_editable!(f, label) do
    for input <- Floki.find(f, "input:not([type=hidden]), select, textarea") do
      assert Floki.attribute(input, "disabled") == [], "#{label}: inputs stay editable (no disabled)"
      assert Floki.attribute(input, "readonly") == [], "#{label}: inputs stay editable (no readonly)"
    end
  end

  # the confirm pages carry data-reauth="fresh" | "needed" on the reauth-state element, unchanged
  defp assert_state_attr!(doc, %{hint: :state} = form, expected) do
    assert [state] = Floki.find(doc, ~s([data-role="reauth-state"]))
    assert Floki.attribute(state, "data-reauth") == [expected], "#{form.key}: data-reauth=#{expected}"
  end

  defp assert_state_attr!(_doc, _form, _expected), do: :ok

  @doc "The stale hint is reworded to the new flow: sign in FIRST (no 'If you are asked to sign in again'); the storage hint keeps naming the keys."
  def assert_stale_hint!(doc, form) do
    text = hint_text(doc, hint_id(doc, form))
    refute text =~ ~r/if you are asked to sign in again/i, "#{form.key}: the old hint wording is gone: #{text}"
    refute text =~ ~r/must enter your change again/i, "#{form.key}: the old hint wording is gone: #{text}"
    assert text =~ ~r/sign[ -]?in/i, "#{form.key}: the hint talks about the sign-in: #{text}"
    assert text =~ ~r/\b(first|before)\b/i, "#{form.key}: the hint says to sign in FIRST (or before): #{text}"

    # the confirm pages (story Decision): nothing was typed before the sign-in, so the hint does not say "type ... again"
    if form.hint == :state, do: refute(text =~ ~r/\btype\b[^.]*\bagain\b/i, "#{form.key}: the hint must not say 'type ... again': #{text}")

    # the other forms are editable in the stale state: what is typed before the sign-in round trip is lost (nothing is replayed)
    if form.hint != :state, do: assert(text =~ ~r/\b(typed?|enter(ed)?)\b[^.]*\bbefore\b[^.]*\blost\b/i, "#{form.key}: the hint says that input typed before the sign-in is lost: #{text}")

    if form.key == :media_storage, do: assert_keys_sentence!(form, text)

    text
  end

  # the storage target hint, in BOTH states: the access key and the secret key are never filled in, Test Connection needs no sign-in
  defp assert_keys_sentence!(form, text) do
    assert text =~ ~r/access key/i and text =~ ~r/secret key/i and text =~ ~r/never/i, "#{form.key}: the keys are never pre-filled: #{text}"
    assert text =~ ~r/test connection (needs no new sign-in|does not use up the sign-in)/i, "#{form.key}: Test Connection needs no sign-in / does not use up the sign-in: #{text}"
  end

  @doc """
  The validity line in the hint element: the fresh sign-in is valid (`valid`), for N whole minutes (floor; `1 minute` singular; `less than a minute` below
  60 s) and for one save. `minutes`: an integer, `:less`, or `:any` (a number of minutes or less than a minute).
  """
  def assert_fresh_hint!(doc, form, minutes \\ :any) do
    text = hint_text(doc, hint_id(doc, form))
    assert text =~ ~r/\bvalid\b/i, "#{form.key}: the line says the sign-in is valid: #{text}"
    assert text =~ ~r/\bone (save|approval|decision|revocation|action|change)\b/i, "#{form.key}: the line says it is for one save: #{text}"
    refute text =~ ~r/if you are asked to sign in again/i, "#{form.key}: the old wording is gone: #{text}"
    # the minutes are those left when the page was RENDERED (no countdown): the line says so, so a page left open does not claim time it no longer has
    assert text =~ ~r/when this page was opened/i, "#{form.key}: the minutes are as of the page load: #{text}"
    if form.key == :media_storage, do: assert_keys_sentence!(form, text)

    id = hint_id(doc, form)
    [hint] = Floki.find(doc, ~s([id="#{id}"]))
    refute hidden_class?(hint), "#{form.key}: the validity line is visible (not hidden / sr-only)"

    case minutes do
      :any ->
        assert text =~ ~r/\b\d+ (more )?minutes?\b|less than a minute/i, "#{form.key}: remaining minutes: #{text}"

      :less ->
        assert text =~ ~r/less than a minute/i, "#{form.key}: less than a minute: #{text}"
        refute text =~ ~r/\b\d+ (more )?minutes?\b/i, "#{form.key}: no number of minutes below 60 s: #{text}"

      1 ->
        assert text =~ ~r/\b1 (more )?minute\b/i, "#{form.key}: 1 minute: #{text}"
        refute text =~ ~r/\b1 (more )?minutes\b/i, "#{form.key}: 1 minute is singular: #{text}"

      n when is_integer(n) ->
        assert text =~ ~r/\b#{n} (more )?minutes\b/i, "#{form.key}: #{n} minutes: #{text}"
        refute text =~ ~r/less than a minute/i, "#{form.key}: not 'less than a minute': #{text}"
    end

    text
  end

  @doc """
  After a REFUSED (expired marker) POST: nothing of the form survives. The session the refused request ends with and its flash hold no `canaries`, and the page the admin
  gets next (`page`, requested with the same session: `marker` = the options of `with_marker/3`, `nil` for none) renders no canary anywhere (no prefill, no echo),
  and no flash that says a change was refused.
  """
  def assert_no_replay!(post, page, canaries, marker) do
    session = inspect(post.private[:plug_session] || %{}, limit: :infinity, printable_limit: :infinity)
    flash = inspect(post.assigns[:flash] || %{})

    for canary <- canaries do
      refute session =~ canary, "the session after the refused POST holds #{canary}"
      refute flash =~ canary, "the flash after the refused POST holds #{canary}"
    end

    # a refusal that set a cookie (a flash, a stored form) is followed through that cookie, else with the same session as the refused POST had
    next = if get_resp_header(post, "set-cookie") == [], do: get(page, marker), else: next_get(post, page)
    assert next.status == 200, "the next page after the refusal renders (#{next.status})"

    for canary <- canaries do
      refute next.resp_body =~ canary, "the next GET of #{page} must not echo or prefill #{canary}"
    end

    flashes = doc(next) |> Floki.find(~s(p.alert-success, p.alert-error, [data-role="toast"])) |> norm()
    refute flashes =~ ~r/refused|not saved yet|enter (it|your change) again/i, "no flash that talks about a refused change: #{flashes}"
    next
  end

  @doc "No link of the page leaves /admin and no sign-in link carries anything but the page path (`mode=reauth`, `return_to`): no form value, secret or marker content."
  def assert_clean_links!(doc, allowed_paths) do
    allowed = Enum.map(allowed_paths, &Auth.reauth_start_path/1)

    for a <- Floki.find(doc, "a"), [href] <- [Floki.attribute(a, "href")], String.starts_with?(href, "/admin/login/start") do
      assert href in allowed, "a sign-in link may only be reauth_start_path of the page path: #{inspect(href)}"
    end

    :ok
  end

  @doc "The sign-in links (hrefs starting with /admin/login/start) of the page."
  def signin_hrefs(doc) do
    for a <- Floki.find(doc, "a"), [href] <- [Floki.attribute(a, "href")], String.starts_with?(href, "/admin/login/start"), do: href
  end

  @doc "True when the 'plain submit' control of a form that is NOT marker-gated is unchanged: a real submit button with this text and no sign-in link in the form."
  def assert_plain_submit!(doc, selector, text) do
    f = one!(Floki.find(doc, selector), "one form #{selector}")
    button = one!(submit_controls(f) |> Enum.filter(&(control_text(&1) == text)), "#{selector}: the plain submit #{inspect(text)}")
    assert Floki.attribute(button, "type") in [["submit"], []]
    refute f |> Floki.find("a") |> Enum.any?(&(norm(&1) =~ ~r/sign in again/i)), "#{selector}: never a sign-in link"
    assert Floki.find(f, ~s([id$="-reauth-hint"], [data-role="reauth-state"])) == [], "#{selector}: no reauth hint element (it is not a marker-gated form)"
    button
  end
end
