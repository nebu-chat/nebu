defmodule Nebu.Admin.BootstrapController do
  @moduledoc """
  Plain HTTP controller for the Bootstrap Wizard (device-management story,
  fix-bootstrap-wizard-liveview-bugs).

  Replaces the LiveView `Nebu.Admin.BootstrapLive` for the wizard steps 1-3.
  Fixes three bugs:

    1. Infinite redirect — the old live route was inside `live_session :admin` with
       `on_mount: {Nebu.Admin.Auth, :require_admin}`. Before bootstrap is complete
       there is no admin session, so the gate redirected to /admin/login, which
       redirected to /admin/bootstrap → infinite loop.

    2. Form fields clearing — LiveView reconnects remount and clear socket assigns
       (and thus form input values). Plain HTML POST forms + server-side redirects
       are not affected.

    3. JWKS URI field — the wizard used to require operators to enter the JWKS URI
       manually. The controller now auto-discovers it from the issuer's
       `/.well-known/openid-configuration` via `Nebu.Matrix.OidcMetadata.fetch/1`.

  ## ADR-018

  All draft reads/writes are inline SQL against `Nebu.Repo` (same SQL module attrs as
  `BootstrapLive`), honouring the same `:admin_bootstrap_store` injectable seam.

  ## ADR-019

  Single OTP app, no umbrella.

  ## Encryption

  `encrypt_secret/1` and `decrypt_secret/1` live in `Nebu.Admin.BootstrapLive` and are
  referenced by `Nebu.Admin.Auth`. The controller delegates to those functions.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :bootstrap_gate

  @steps [1, 2, 3]
  @step_labels %{1 => "Instance", 2 => "OIDC", 3 => "Claim Mapping"}

  @default_claim_mapping %{
    "oidc_user_id_claim" => "name",
    "oidc_displayname_claim" => "name",
    "oidc_email_claim" => "email"
  }

  @refresh_mode_defaults %{
    "matrix_oidc_refresh_mode" => "offline",
    "admin_oidc_refresh_mode" => "online"
  }

  # ── GET /admin/bootstrap ─────────────────────────────────────────────────────

  @doc """
  Renders the Bootstrap Wizard. No admin session required — accessible before
  bootstrap is complete (the `:bootstrap_gate` plug allows it).
  """
  def index(conn, params) do
    draft = load_draft()
    step = resolve_step(params, draft)

    conn
    |> assign(:step, step)
    |> assign(:steps, @steps)
    |> assign(:step_labels, @step_labels)
    |> assign(:draft, draft)
    |> assign(:error, nil)
    |> assign(:completed, false)
    |> assign(:bootstrap_completed, false)
    |> assign(:page_title, "Bootstrap")
    |> assign(:active_nav, "bootstrap")
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  # ── POST /admin/bootstrap/step/1 ─────────────────────────────────────────────

  @doc """
  Saves the instance name (step 1) and redirects to step 2.
  """
  def save_step1(conn, params) do
    name = String.trim(params["instance_name"] || "")

    if name == "" do
      draft = load_draft()

      conn
      |> assign(:step, 1)
      |> assign(:steps, @steps)
      |> assign(:step_labels, @step_labels)
      |> assign(:draft, draft)
      |> assign(:error, "Instance name must not be empty.")
      |> assign(:completed, false)
      |> assign(:bootstrap_completed, false)
      |> assign(:page_title, "Bootstrap")
      |> assign(:active_nav, "bootstrap")
      |> put_layout(html: {Nebu.Admin.Layouts, :live})
      |> put_status(200)
      |> render(:index)
    else
      put_draft("instance_name", name)
      redirect(conn, to: "/admin/bootstrap")
    end
  end

  # ── POST /admin/bootstrap/step/2 ─────────────────────────────────────────────

  @doc """
  Saves the OIDC config (step 2) and redirects to step 3.
  JWKS URI is auto-discovered from `{issuer}/.well-known/openid-configuration`.
  Operators do NOT provide it manually.
  """
  def save_step2(conn, params) do
    issuer = String.trim(params["oidc_issuer"] || "")
    client_id = String.trim(params["oidc_client_id"] || "")
    client_secret = params["oidc_client_secret"] || ""
    audience = String.trim(params["oidc_audience"] || "")

    cond do
      issuer == "" or client_id == "" or client_secret == "" ->
        render_step2_error(conn, params, "Issuer, client ID and client secret are required.")

      audience == "" ->
        render_step2_error(conn, params, "OIDC audience is required.")

      URI.parse(issuer).scheme not in ["http", "https"] ->
        render_step2_error(conn, params, "OIDC Issuer URL must use http:// or https://.")

      String.length(issuer) > 2048 ->
        render_step2_error(conn, params, "OIDC Issuer URL is too long.")

      true ->
        # Auto-discover JWKS URI from the issuer's well-known document (Bug 3 fix).
        # On failure: show an inline error without crashing.
        case discover_jwks_uri(issuer) do
          {:ok, jwks_uri} ->
            put_draft("oidc_issuer", issuer)
            put_draft("oidc_client_id", client_id)
            put_draft("oidc_client_secret", Nebu.Admin.BootstrapLive.encrypt_secret(client_secret))
            put_draft("oidc_audience", audience)
            put_draft("oidc_jwks_uri", jwks_uri)
            redirect(conn, to: "/admin/bootstrap")

          {:error, _reason} ->
            render_step2_error(
              conn,
              params,
              "Could not discover JWKS URI from issuer. Check the OIDC Issuer URL."
            )
        end
    end
  end

  # ── POST /admin/bootstrap/step/3 ─────────────────────────────────────────────

  @doc """
  Saves the claim mapping (step 3) and redirects to the bootstrap-mode OIDC login.
  """
  def save_step3(conn, params) do
    save_claim_mapping(params)
    redirect(conn, to: "/admin/login/start?mode=bootstrap")
  end

  # ── JWKS auto-discovery ───────────────────────────────────────────────────────

  defp discover_jwks_uri(issuer) do
    with {:ok, body} <- Nebu.Matrix.OidcMetadata.fetch(issuer),
         {:ok, doc} <- Jason.decode(body),
         jwks_uri when is_binary(jwks_uri) and jwks_uri != "" <- doc["jwks_uri"] do
      {:ok, jwks_uri}
    else
      _ -> {:error, :jwks_discovery_failed}
    end
  end

  # ── Claim mapping persistence ─────────────────────────────────────────────────

  defp save_claim_mapping(params) do
    Enum.each(@default_claim_mapping, fn {key, default} ->
      value = params[key] |> to_string() |> String.trim()
      put_draft(key, if(value == "", do: default, else: value))
    end)

    Enum.each(@refresh_mode_defaults, fn {key, default} ->
      value = params[key] |> to_string()
      put_draft(key, if(value in ["offline", "online"], do: value, else: default))
    end)
  end

  # ── Re-render helpers ─────────────────────────────────────────────────────────

  defp render_step2_error(conn, params, error) do
    draft = load_draft()
    # Merge submitted params back into draft so the operator does not lose their
    # input on JWKS discovery failure. oidc_client_secret is intentionally excluded
    # — password fields cannot be pre-filled by the browser.
    display_draft =
      draft
      |> Map.put("oidc_issuer", params["oidc_issuer"] || draft["oidc_issuer"])
      |> Map.put("oidc_client_id", params["oidc_client_id"] || draft["oidc_client_id"])
      |> Map.put("oidc_audience", params["oidc_audience"] || draft["oidc_audience"])

    conn
    |> assign(:step, 2)
    |> assign(:steps, @steps)
    |> assign(:step_labels, @step_labels)
    |> assign(:draft, display_draft)
    |> assign(:error, error)
    |> assign(:completed, false)
    |> assign(:bootstrap_completed, false)
    |> assign(:page_title, "Bootstrap")
    |> assign(:active_nav, "bootstrap")
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> put_status(200)
    |> render(:index)
  end

  # ── Step resume ───────────────────────────────────────────────────────────────

  # Honours ?step= URL param on a completely empty draft (fresh instance). Parity with
  # BootstrapLive.parse_step/1 so e2e tests can preview step 3 selectors on a fresh DB.
  # Once any draft data exists, clamp to resume_step so operators can't skip ahead.
  defp resolve_step(params, draft) do
    max_step = resume_step(draft)

    case Integer.parse(params["step"] || "") do
      {n, ""} when n in 1..3 ->
        if map_size(draft) == 0, do: n, else: min(n, max_step)

      _ ->
        max_step
    end
  end

  # Resume at the first incomplete step (parity with BootstrapLive.resume_step/1).
  defp resume_step(draft) do
    cond do
      draft["instance_name"] in [nil, ""] -> 1
      draft["oidc_issuer"] in [nil, ""] -> 2
      true -> 3
    end
  end

  # ── Inline SQL (ADR-018) ──────────────────────────────────────────────────────

  @sql_load_draft "SELECT key, value FROM bootstrap_draft"
  @sql_put_draft """
  INSERT INTO bootstrap_draft (key, value, set_at) VALUES ($1, $2, $3)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at
  """

  # Honours the same `:admin_bootstrap_store` injectable seam as BootstrapLive and
  # Nebu.Admin.Auth — lets the acceptance tests inject a fake store without Postgres.

  defp load_draft do
    case store(:load_draft, []) do
      {:ok, %{} = draft} ->
        draft

      :default ->
        if running_repo?() do
          case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_load_draft, []) do
            {:ok, %{rows: rows}} -> Map.new(rows, fn [k, v] -> {k, v} end)
            _ -> %{}
          end
        else
          %{}
        end
    end
  end

  defp put_draft(key, value) do
    case store(:put_draft, [key, value]) do
      :default ->
        if running_repo?() do
          Ecto.Adapters.SQL.query(Nebu.Repo, @sql_put_draft, [key, value, now_ms()])
        end

      _ ->
        :ok
    end

    :ok
  end

  defp store(op, args) do
    case Application.get_env(:nebu_http, :admin_bootstrap_store) do
      fun when is_function(fun, 2) -> fun.(op, args)
      _ -> :default
    end
  end

  defp running_repo?, do: Process.whereis(Nebu.Repo) != nil
  defp now_ms, do: System.system_time(:millisecond)
end
