defmodule Nebu.Admin.BootstrapLive do
  @moduledoc """
  Bootstrap Wizard LiveView (admin-ui-migration, AC6).

  Ports the Go admin Bootstrap Wizard (gateway/internal/admin/bootstrap.go) to Phoenix
  LiveView. The wizard's multi-step state lives in socket assigns; each completed step
  persists to the `bootstrap_draft` table, and finishing the wizard promotes the draft
  into `server_config` and sets `bootstrap_completed` (parity with the Go
  `completeBootstrapTx` flow).

  ## Step sequence (Go parity — gateway/internal/admin/bootstrap.go StepHandler)

    1. Instance name      → bootstrap_draft.instance_name
    2. OIDC config        → bootstrap_draft.{oidc_issuer, oidc_client_id, oidc_client_secret}
    3. Claim mapping      → bootstrap_draft.{oidc_user_id_claim, oidc_displayname_claim,
                            oidc_email_claim}, then "Connect with OIDC" redirects to
                            /admin/login/start?mode=bootstrap.

  This LiveView owns ONLY steps 1-3 (collect config into the draft) and the hand-off to
  the bootstrap-mode OIDC login. The operator then authenticates at the IdP; the callback
  (`Nebu.Admin.Auth.callback/2`, mode=bootstrap) renders the claim-selection page, and
  `Nebu.Admin.Auth.bootstrap_confirm_claim/2` promotes the draft into `server_config`,
  writes the chosen `admin_group_claim`, sets `bootstrap_completed`, clears the draft and
  mints the admin session — byte-for-byte parity with the Go ClaimSelectionHandler.

  ## ADR-018

  All draft/config reads + writes are inline SQL against `Nebu.Repo` (`bootstrap_draft`
  and `server_config` are simple key/value tables: `(key, value, set_at)`). No schema,
  changeset, or repository layer. The `oidc_client_secret` is encrypted at rest with
  AES-256-GCM before it is written to `bootstrap_draft` (and carried forward unchanged
  into `server_config` on finish) — byte-for-byte parity with the Go bootstrap handler
  (`gateway/internal/admin/crypto.go` `encryptAES256GCM`: key = SHA-256(internal secret),
  value = hex(nonce ‖ ciphertext ‖ tag)). The AES primitive is reused inline from
  `Nebu.Media.Crypto` (same `:aes_256_gcm` used for media at-rest).

  Stateless / DB-backed (Persistenz Option C): the wizard re-reads its draft from the
  DB on mount, so a crashed LiveView re-mounts at the correct step.
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  @steps [1, 2, 3]
  @step_labels %{1 => "Instance", 2 => "OIDC", 3 => "Claim Mapping"}
  # The user-id claim maps an OIDC token claim to the Matrix localpart, so it must be a
  # stable, human-meaningful username — not the opaque `sub` (which produces user IDs
  # like `@CiQwMDAw…:server` that no operator or client can address). Default to `name`
  # (the username for the configured IdP), matching the migration seed
  # (server_config.oidc_user_id_claim = 'name') and the Claim-Mapping admin page.
  @default_claim_mapping %{
    "oidc_user_id_claim" => "name",
    "oidc_displayname_claim" => "name",
    "oidc_email_claim" => "email"
  }

  # Story oidc-refresh-mode-config (AC4): the operator's chosen OIDC refresh modes,
  # collected on the claim-mapping step and promoted into server_config at confirm.
  # Defaults preselected: Matrix=offline (refresh on Dex & Keycloak), Admin=online (no
  # forced offline_access → no special IdP approval). Values are validated to the
  # offline|online enum before they are written to the draft (no scope injection).
  @refresh_mode_defaults %{
    "matrix_oidc_refresh_mode" => "offline",
    "admin_oidc_refresh_mode" => "online"
  }

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    draft = load_draft()
    # `params` is `:not_mounted_at_router` under live_isolated/3 (no router); treat that
    # like "no step param" and resume from the draft.
    step_param = if is_map(params), do: params["step"], else: nil
    step = parse_step(step_param, draft)

    {:ok,
     assign(socket,
       step: step,
       steps: @steps,
       step_labels: @step_labels,
       draft: draft,
       error: nil,
       completed: bootstrap_completed?(),
       page_title: "Bootstrap",
       active_nav: "bootstrap",
       bootstrap_completed: bootstrap_completed?()
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("save_step", params, socket) do
    case socket.assigns.step do
      1 -> save_instance(params, socket)
      2 -> save_oidc(params, socket)
      _ -> {:noreply, socket}
    end
  end

  # Step 3 "Connect with OIDC" (Go parity: bootstrap.go StepHandler case 3). Persists the
  # claim mapping to the draft, then hands off to the bootstrap-mode OIDC login leg
  # (Nebu.Admin.Auth.login_start mode=bootstrap → IdP). The draft is NOT promoted and
  # bootstrap is NOT completed here — that happens at Confirm, after the operator has
  # authenticated and chosen a claim (Nebu.Admin.Auth.bootstrap_confirm_claim/2).
  def handle_event("connect_oidc", params, socket) do
    save_claim_mapping(params)
    {:noreply, redirect(socket, to: "/admin/login/start?mode=bootstrap")}
  end

  def handle_event("goto_step", %{"step" => step}, socket) do
    {:noreply, assign(socket, step: parse_step(step, socket.assigns.draft))}
  end

  # ── Step writes (inline SQL upsert into bootstrap_draft) ──────────────────────

  defp save_instance(%{"instance_name" => name}, socket) do
    name = String.trim(name || "")

    if name == "" do
      {:noreply, assign(socket, error: "Instance name must not be empty.")}
    else
      put_draft("instance_name", name)
      {:noreply, assign(socket, draft: load_draft(), step: 2, error: nil)}
    end
  end

  defp save_oidc(params, socket) do
    issuer = String.trim(params["oidc_issuer"] || "")
    client_id = String.trim(params["oidc_client_id"] || "")
    client_secret = params["oidc_client_secret"] || ""

    if issuer == "" or client_id == "" or client_secret == "" do
      {:noreply, assign(socket, error: "Issuer, client ID and client secret are required.")}
    else
      put_draft("oidc_issuer", issuer)
      put_draft("oidc_client_id", client_id)
      # MINOR-3: encrypt the client secret at rest (AES-256-GCM) before storing it in
      # bootstrap_draft — byte-for-byte parity with the Go bootstrap handler
      # (gateway/internal/admin/crypto.go encryptAES256GCM, keyed by the gateway
      # internal secret). The encrypted blob is carried forward unchanged when the
      # draft is promoted into server_config in complete_bootstrap/1.
      put_draft("oidc_client_secret", encrypt_secret(client_secret))
      {:noreply, assign(socket, draft: load_draft(), step: 3, error: nil)}
    end
  end

  # Persists the claim-mapping fields (defaults applied for blank inputs) to the draft.
  # Called by the step-3 "Connect with OIDC" handler before the OIDC login hand-off.
  defp save_claim_mapping(params) do
    Enum.each(@default_claim_mapping, fn {key, default} ->
      value = params[key] |> to_string() |> String.trim()
      put_draft(key, if(value == "", do: default, else: value))
    end)

    # Persist the chosen refresh modes alongside the claim mapping (AC4). Validate to
    # the offline|online enum; any out-of-enum input falls back to the client's
    # default — so server_config can only ever hold a valid scope-control value.
    Enum.each(@refresh_mode_defaults, fn {key, default} ->
      value = params[key] |> to_string()
      put_draft(key, if(value in ["offline", "online"], do: value, else: default))
    end)
  end

  # ── inline SQL (ADR-018) ──────────────────────────────────────────────────────

  @sql_load_draft "SELECT key, value FROM bootstrap_draft"
  @sql_put_draft """
  INSERT INTO bootstrap_draft (key, value, set_at) VALUES ($1, $2, $3)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at
  """
  @sql_bootstrap_completed "SELECT value FROM server_config WHERE key = 'bootstrap_completed' LIMIT 1"

  # Every read/write below first consults the :admin_bootstrap_store seam — a single
  # injectable `fun.(op, args)` dispatcher (same thin-boundary pattern as
  # RoomsLive's :admin_auto_join_writer). It is NOT a repository abstraction: the real
  # inline SQL still lives in this module (ADR-018) and runs whenever the seam is unset.
  # The seam lets the bootstrap acceptance test exercise the wizard's step navigation +
  # draft persistence without a live Postgres. The draft→server_config promotion +
  # bootstrap completion now lives in Nebu.Admin.Auth.bootstrap_confirm_claim/2 (post-OIDC).

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

  defp bootstrap_completed? do
    case store(:bootstrap_completed?, []) do
      {:ok, bool} when is_boolean(bool) ->
        bool

      :default ->
        completed_from_repo?()
    end
  end

  defp completed_from_repo? do
    if running_repo?() do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_bootstrap_completed, []) do
        {:ok, %{rows: [[v]]}} -> v == "true"
        _ -> false
      end
    else
      false
    end
  end

  defp running_repo?, do: Process.whereis(Nebu.Repo) != nil
  defp now_ms, do: System.system_time(:millisecond)

  # Injectable persistence seam. Returns the fake's result tuple when a function is
  # installed, or `:default` (run the real inline SQL) when it is not.
  defp store(op, args) do
    case Application.get_env(:nebu_http, :admin_bootstrap_store) do
      fun when is_function(fun, 2) -> fun.(op, args)
      _ -> :default
    end
  end

  # ── oidc_client_secret at-rest encryption (MINOR-3, Go crypto.go parity) ──────
  #
  # Go: encryptAES256GCM(secret, plaintext) → hex(nonce ‖ gcm.Seal(...)) with
  # key = SHA-256(secret). Nebu.Media.Crypto.encrypt/3 already returns
  # `ciphertext ‖ tag` (Go gcm.Seal layout), so we only prepend the random 12-byte
  # nonce and hex-encode to reproduce Go's `hex(nonce ‖ ciphertext ‖ tag)` exactly.
  # The key source is the shared internal secret (same secret the Go gateway keys
  # this with), hashed to 32 bytes via SHA-256.

  @doc false
  # Encrypts the OIDC client secret for at-rest storage (Go crypto.go parity). Public so
  # the bootstrap-mode OIDC confirm path (Nebu.Admin.Auth) and the acceptance tests can
  # round-trip the same blob format. Returns hex(nonce ‖ ciphertext ‖ tag).
  def encrypt_secret(plaintext) do
    key = at_rest_key()
    nonce = :crypto.strong_rand_bytes(12)
    blob = Nebu.Media.Crypto.encrypt(plaintext, key, nonce)
    Base.encode16(nonce <> blob, case: :lower)
  end

  @doc false
  # Decrypts a value produced by encrypt_secret/1. Kept available for the masked
  # display / step-2 re-edit path (parity with the Go handler's decryptAES256GCM
  # round-trip). Returns "" on any decode/auth-tag failure (never crashes the wizard).
  def decrypt_secret(hex_blob) when is_binary(hex_blob) do
    with {:ok, raw} <- Base.decode16(hex_blob, case: :mixed),
         <<nonce::binary-size(12), blob::binary>> <- raw,
         {:ok, plaintext} <- Nebu.Media.Crypto.decrypt(blob, at_rest_key(), nonce) do
      plaintext
    else
      _ -> ""
    end
  end

  def decrypt_secret(_), do: ""

  # SHA-256 of the shared internal secret → 32-byte AES-256 key (Go: sha256.Sum256).
  # F-1 (security review): never derive the at-rest key from an empty secret —
  # SHA-256("") is publicly computable, so encrypting the OIDC client secret under
  # it gives no confidentiality. Fail closed if no real internal secret is present.
  defp at_rest_key do
    secret =
      case Application.get_env(:nebu_http, :admin_secret_at_rest) do
        s when is_binary(s) and s != "" ->
          s

        _ ->
          case System.get_env("NEBU_INTERNAL_SECRET_FILE") do
            nil -> System.get_env("NEBU_INTERNAL_SECRET", "")
            path -> path |> File.read!() |> String.trim()
          end
      end

    if secret == "" do
      raise "admin secret-at-rest key unavailable: set NEBU_INTERNAL_SECRET_FILE " <>
              "or NEBU_INTERNAL_SECRET (refusing to encrypt the OIDC client secret " <>
              "under SHA-256(\"\"))"
    end

    :crypto.hash(:sha256, secret)
  end

  defp parse_step(nil, draft), do: resume_step(draft)

  defp parse_step(value, draft) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n in @steps -> n
      _ -> resume_step(draft)
    end
  end

  defp parse_step(_, draft), do: resume_step(draft)

  # Resume at the first incomplete step (parity with the Go wizard's draft-driven flow).
  # Step 3 (claim mapping → Connect with OIDC) is the terminal wizard step; completion
  # happens post-OIDC in Nebu.Admin.Auth.bootstrap_confirm_claim/2.
  defp resume_step(draft) do
    cond do
      draft["instance_name"] in [nil, ""] -> 1
      draft["oidc_issuer"] in [nil, ""] -> 2
      true -> 3
    end
  end

  # ── render ───────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="admin-bootstrap" data-page="bootstrap" data-step={@step} data-step-active={@step}>
      <h1 class="text-2xl font-bold mb-2">Bootstrap Setup</h1>

      <%!-- Progress indicator (Go parity): each step is marked; the active one carries
            data-progress-step matching the current step + aria-current for a11y. --%>
      <ol class="steps mb-6" data-progress aria-label="Bootstrap progress">
        <li
          :for={s <- @steps}
          class={["step", s <= @step && "step-primary"]}
          data-progress-step={if(s == @step, do: s, else: nil)}
          aria-current={if(s == @step, do: "step", else: nil)}
        >
          {@step_labels[s]}
        </li>
      </ol>

      <div :if={@error} class="alert alert-error mb-4" role="alert">{@error}</div>

      <div :if={@completed} class="alert alert-success" role="status">
        Bootstrap complete. The instance is configured.
      </div>

      <form :if={not @completed and @step == 1} id="bootstrap-step-1" phx-submit="save_step">
        <label class="form-control">
          <span class="label-text">Instance Name</span>
          <input
            type="text"
            name="instance_name"
            aria-label="Instance Name"
            value={@draft["instance_name"]}
            class="input input-bordered"
            required
          />
        </label>
        <button type="submit" class="btn btn-primary mt-4">Next</button>
      </form>

      <form :if={not @completed and @step == 2} id="bootstrap-step-2" phx-submit="save_step">
        <label class="form-control">
          <span class="label-text">OIDC Issuer URL</span>
          <input
            type="url"
            name="oidc_issuer"
            aria-label="OIDC Issuer URL"
            value={@draft["oidc_issuer"]}
            class="input input-bordered"
            required
          />
        </label>
        <label class="form-control mt-2">
          <span class="label-text">OIDC Client ID</span>
          <input
            type="text"
            name="oidc_client_id"
            aria-label="OIDC Client ID"
            value={@draft["oidc_client_id"]}
            class="input input-bordered"
            required
          />
        </label>
        <label class="form-control mt-2">
          <span class="label-text">OIDC Client Secret</span>
          <input
            type="password"
            name="oidc_client_secret"
            aria-label="OIDC Client Secret"
            class="input input-bordered"
            required
          />
        </label>
        <button type="submit" class="btn btn-primary mt-4">Next</button>
      </form>

      <%!-- Step 3: claim mapping defaults + "Connect with OIDC" (Go parity). The button
            persists the claim mapping then redirects to the bootstrap-mode OIDC login. --%>
      <form :if={not @completed and @step == 3} id="bootstrap-step-3" phx-submit="connect_oidc">
        <p class="mb-4 text-base-content/70">
          Map your IdP's claims (defaults shown), then authenticate to pick the admin group claim.
        </p>
        <label class="form-control">
          <span class="label-text">User-ID claim</span>
          <input
            type="text"
            name="oidc_user_id_claim"
            aria-label="User-ID claim"
            value={@draft["oidc_user_id_claim"] || "sub"}
            class="input input-bordered"
          />
        </label>
        <label class="form-control mt-2">
          <span class="label-text">Display-name claim</span>
          <input
            type="text"
            name="oidc_displayname_claim"
            aria-label="Display-name claim"
            value={@draft["oidc_displayname_claim"] || "name"}
            class="input input-bordered"
          />
        </label>
        <label class="form-control mt-2">
          <span class="label-text">Email claim</span>
          <input
            type="text"
            name="oidc_email_claim"
            aria-label="Email claim"
            value={@draft["oidc_email_claim"] || "email"}
            class="input input-bordered"
          />
        </label>

        <%!-- OIDC refresh mode (story oidc-refresh-mode-config, AC4/AC6). Two native
              <select>s so the operator can pick offline/online per client at bootstrap;
              defaults Matrix=offline / Admin=online preselected. --%>
        <fieldset class="mt-4 border border-base-300 rounded p-3">
          <legend class="label-text font-semibold px-1">OIDC refresh mode</legend>

          <label class="form-control mt-2">
            <span class="label-text">Matrix client refresh mode</span>
            <select name="matrix_oidc_refresh_mode" aria-label="Matrix refresh mode" class="select select-bordered">
              <option value="offline" selected={(@draft["matrix_oidc_refresh_mode"] || "offline") == "offline"}>
                offline (offline_access)
              </option>
              <option value="online" selected={@draft["matrix_oidc_refresh_mode"] == "online"}>
                online
              </option>
            </select>
          </label>

          <label class="form-control mt-2">
            <span class="label-text">Admin client refresh mode</span>
            <select name="admin_oidc_refresh_mode" aria-label="Admin refresh mode" class="select select-bordered">
              <option value="offline" selected={@draft["admin_oidc_refresh_mode"] == "offline"}>
                offline (offline_access)
              </option>
              <option value="online" selected={(@draft["admin_oidc_refresh_mode"] || "online") == "online"}>
                online
              </option>
            </select>
          </label>

          <p class="text-sm text-base-content/70 mt-2">
            <strong>offline</strong>: long-lived offline refresh token (survives IdP logout);
            works on Dex &amp; Keycloak. Nebu stores the refresh token AES-256-GCM-encrypted
            (server-side for Matrix, in the signed cookie for admin) and caps its own session at 8h.
            <strong>online</strong>: session-bound refresh token (dies on IdP SSO logout).
            <strong>Dex issues a refresh token only when <code>offline_access</code> is requested</strong>
            — so in online mode refresh is disabled on Dex (use offline for Dex).
          </p>
        </fieldset>

        <button type="submit" class="btn btn-primary mt-4" phx-click="connect_oidc">
          Connect with OIDC
        </button>
      </form>
    </div>
    """
  end
end
