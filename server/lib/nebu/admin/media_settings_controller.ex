defmodule Nebu.Admin.MediaSettingsController do
  @moduledoc """
  HTTP controller for the Admin Media Policy Settings page
  (media-security-admin-control/9b-media-settings-ui).

  `GET /admin/media/settings` renders a form pre-filled with the current
  value of every admin-editable `media_config` key (Story 9a's 10-key
  catalog minus `mime_denylist`, which this page does not expose); `POST
  /admin/media/settings` validates and persists it. Deliberately a plain
  Phoenix Controller, NOT a LiveView (see the story's Summary and
  `Nebu.Admin.Router`'s moduledoc on the three remaining LiveView
  exceptions) — follows `Nebu.Admin.LogsController`'s and
  `Nebu.Admin.ConfigController`'s exact conventions (plug-based
  `:require_admin`, small per-field `validate_bound/2`-style helpers, a
  `render_settings/2`-style rendering helper, flash-only success/error
  messaging).

  ## Persistence seam (ADR-020)

  The ONLY calls this controller makes into the `Nebu.Media` namespace are
  `Nebu.Media.Config.get/0` (read, to pre-fill the form) and
  `Nebu.Media.Config.upsert/3` (write, on save — one call per key, the real
  Story 9a public API; NOT the story text's stale `upsert/1` map-based
  phrasing). No `Postgrex`/`Ecto.Adapters.SQL` call against `media_config`
  from this module or its template.

  ## Validation is two-phase (AC2/AC3 atomicity)

  `validate_and_normalize/1` validates and coerces EVERY submitted field
  before `save/2` calls `Nebu.Media.Config.upsert/3` even once — mirroring
  `Nebu.Admin.LogsController.validate_and_normalize/1`'s pipeline structure.
  If ANY field fails validation, ZERO keys are persisted; the form
  re-renders at HTTP 200 with the operator's submitted (invalid) values
  preserved and a flash naming the first specific validation failure.

  ## Numeric bounds (AC2)

  Each of the 7 numeric fields is bounded independently of
  `Nebu.Media.Config.upsert/3`'s own "non-negative integer" contract — this
  controller additionally enforces an operationally-sane upper bound so an
  admin cannot accidentally configure a pathological value (e.g. a
  multi-terabyte upload limit, a multi-day stall timeout) through this UI.
  The bounds below are this story's own choice (the story does not mandate
  specific numbers), chosen generously enough to never reject any
  `config.exs` default:

    * `max_upload_size_bytes` / `max_file_size_bytes` — 1 byte to 5 GiB
      (`5_368_709_120`): generous headroom above the 100 MiB config.exs
      default while still rejecting an obviously-wrong entry.
    * `max_pending_per_user` — 1 to 1000: the 429 pending-upload limit;
      config.exs default is 20.
    * `max_stall_ms` — 1 ms to 1 hour (`3_600_000`): the upload-stall
      timeout; config.exs default is 20000 (20s).
    * `deleted_days` / `infected_days` — 0 to 3650 (10 years): retention
      windows; 0 means "delete immediately on next sweep", matching
      `Nebu.Media.Config.upsert/3`'s own `>= 0` contract.
    * `orphaned_hours` — 0 to 8760 (1 year in hours): the orphaned-upload
      retention window.

  `webhook_url` and `released_delete_after_days` have no fixed numeric
  upper bound in this controller; their validation is delegated to
  `Nebu.Media.SSRF.check/1` (webhook_url — reused verbatim, never
  re-derived) and a plain non-negative-integer-or-blank check
  (released_delete_after_days) respectively.

  ## AC4 — nil → value warning on `released_delete_after_days`

  When a valid save changes `released_delete_after_days` from unset (`nil`)
  to a concrete number of days, `save/2` adds a SECOND, stronger `:warning`
  flash (in addition to the generic `:info` "Media settings saved" flash)
  explicitly stating that released media will now be automatically and
  permanently deleted — the exact copy is this story's own choice; the
  rendered template shows it with the same `role="alert"` treatment as the
  error flash so assistive technology treats it with equal urgency.

  ## Storage-target config + Test Connection (story
  `media-security-admin-control/11b-storage-ui-test-connection`)

  `index/2` also assigns `:storage_config` (`Nebu.Media.StorageConfig.get/0`)
  for the template's second, independent form section. Two new actions:

    * `save_storage/2` — validates the raw params map (plain Elixir, no
      `Ecto.Changeset`, ADR-018), then persists exclusively via
      `Nebu.Media.StorageConfig.upsert/2` (ADR-020). A blank `access_key`/
      `secret_key` field means "leave unchanged" — it is OMITTED from the
      partial-update map handed to `upsert/2`, never written as an explicit
      `nil` (which would clear the stored secret). Gated by AC4's orphan-risk
      warning: if the submitted `endpoint`/`bucket` differs from the
      currently PERSISTED value (`StorageConfig.persisted_target/0` — never
      `get/0`'s env-var/default-merged view, since a genuinely fresh/empty
      config must never gate) AND `Nebu.Admin.DB.count_media_with_storage_key/0`
      is greater than zero, the first submission re-renders at 200 with a
      `role="alert"` warning and a required acknowledgment checkbox instead
      of persisting; checking `confirm_orphan_risk` and resubmitting bypasses
      the gate.
    * `test_connection/2` — resolves the submitted candidate (blank secrets
      resolved server-side against the stored secret) via
      `Nebu.Media.StorageConfig.test_connection/1` and renders a fixed,
      non-leaking success/failure message — never persists, never touches
      `upsert/2`. A raw `ExAws`/`:hackney` error reason is logged
      server-side only, never interpolated into the response.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn
  require Logger

  alias Nebu.Admin.DB
  alias Nebu.Media.Config
  alias Nebu.Media.SSRF
  alias Nebu.Media.StorageConfig

  plug Nebu.Admin.Auth, :require_admin

  @storage_generic_failure_message "Connection failed. Check the endpoint, bucket, region, and " <>
                                      "credentials, then try again."
  @storage_invalid_endpoint_message "Endpoint must be a bare host[:port] value " <>
                                       "(no http:// or https:// scheme prefix)."

  @numeric_fields ~w(
    max_upload_size_bytes
    max_file_size_bytes
    max_pending_per_user
    max_stall_ms
    deleted_days
    infected_days
    orphaned_hours
  )

  @all_fields @numeric_fields ++ ~w(webhook_url released_delete_after_days)

  # {min, max} bounds per numeric field — see moduledoc for rationale.
  @bounds %{
    "max_upload_size_bytes" => {1, 5_368_709_120},
    "max_file_size_bytes" => {1, 5_368_709_120},
    "max_pending_per_user" => {1, 1_000},
    "max_stall_ms" => {1, 3_600_000},
    "deleted_days" => {0, 3_650},
    "infected_days" => {0, 3_650},
    "orphaned_hours" => {0, 8_760}
  }

  @strong_warning_copy "Released media will now be deleted automatically and permanently " <>
                          "after the configured number of days. This was previously disabled " <>
                          "(released media persisted indefinitely) — this change is irreversible " <>
                          "for any file that is actually deleted."

  # code review (Cycle 1, MINOR-2): translates a submitted (string-keyed)
  # field name to the atom key Nebu.Media.Config.get/0 uses, so a changed-vs-
  # previous diff can be computed against that atom-keyed catalog. Mirrors
  # Nebu.Media.Config's own internal @key_to_atom convention — only the 9
  # keys this page exposes (of Config's full 10-key catalog; `mime_denylist`
  # is out of scope here per AC1).
  @key_to_atom %{
    "max_upload_size_bytes" => :max_upload_size_bytes,
    "max_file_size_bytes" => :max_file_size_bytes,
    "max_pending_per_user" => :max_pending_per_user,
    "max_stall_ms" => :max_stall_ms,
    "deleted_days" => :deleted_days,
    "infected_days" => :infected_days,
    "orphaned_hours" => :orphaned_hours,
    "webhook_url" => :webhook_url,
    "released_delete_after_days" => :released_delete_after_days
  }

  # ── actions ──────────────────────────────────────────────────────────────

  def index(conn, _params) do
    render_settings(conn, state_from_config(Config.get()))
  end

  # ── Storage-target config + Test Connection (story 11b) ─────────────────

  def save_storage(conn, params) do
    case validate_storage_params(params) do
      {:ok, changes} ->
        handle_storage_save(conn, params, changes)

      {:error, message} ->
        conn
        |> put_status(200)
        |> put_flash(:error, message)
        |> render_settings(state_from_config(Config.get()), storage_config: storage_config_from_params(params))
    end
  end

  def test_connection(conn, params) do
    candidate = candidate_from_params(params)

    case StorageConfig.test_connection(candidate) do
      :ok ->
        conn
        |> put_status(200)
        |> render_settings(state_from_config(Config.get()),
          storage_config: storage_config_from_params(params),
          test_connection_result: {:ok, "Connection succeeded."}
        )

      {:error, :invalid_endpoint} ->
        conn
        |> put_status(200)
        |> render_settings(state_from_config(Config.get()),
          storage_config: storage_config_from_params(params),
          test_connection_result: {:error, @storage_invalid_endpoint_message}
        )

      {:error, reason} ->
        Logger.warning(
          "Nebu.Admin.MediaSettingsController: storage test connection failed: #{inspect(reason)}"
        )

        conn
        |> put_status(200)
        |> render_settings(state_from_config(Config.get()),
          storage_config: storage_config_from_params(params),
          test_connection_result: {:error, @storage_generic_failure_message}
        )
    end
  end

  defp handle_storage_save(conn, params, changes) do
    case StorageConfig.persisted_target() do
      {:ok, %{endpoint: old_endpoint, bucket: old_bucket}} ->
        if target_changed?(changes, old_endpoint, old_bucket) and not confirmed_orphan_risk?(params) do
          maybe_gate_on_orphan_risk(conn, params, changes)
        else
          persist_storage_config(conn, changed_storage_keys(changes))
        end

      :fresh ->
        persist_storage_config(conn, changes)
    end
  end

  defp maybe_gate_on_orphan_risk(conn, params, changes) do
    existing_count = DB.count_media_with_storage_key()

    if existing_count > 0 do
      conn
      |> put_status(200)
      |> render_settings(state_from_config(Config.get()),
        storage_config: storage_config_from_params(params),
        orphan_warning: existing_count
      )
    else
      persist_storage_config(conn, changed_storage_keys(changes))
    end
  end

  defp target_changed?(changes, old_endpoint, old_bucket) do
    changes.endpoint != old_endpoint or changes.bucket != old_bucket
  end

  # code review (Cycle 2, MINOR-2): mirrors save/2's own changed_keys/2 —
  # diffs the submitted storage-target `changes` against the currently
  # persisted (StorageConfig.get/0, the same merged view that pre-fills the
  # form) values so a no-op/single-field resubmit no longer inflates
  # StorageConfig.upsert/2's audit `changed_fields` to the full submitted
  # field set. The AC4 orphan-risk-gate comparison above (`target_changed?`)
  # deliberately runs FIRST against the raw, undiffed `changes` — orphan-risk
  # detection must see the actual submitted endpoint/bucket, not a
  # post-diff-filtered view. Only reached once `persisted_target/0` has
  # already confirmed a row exists (the `:fresh` branch above calls
  # `persist_storage_config/2` directly, unfiltered): on a genuinely fresh
  # config there is nothing yet to diff against, and `get/0`'s env-var/
  # compiled-default-merged view could otherwise coincidentally match a
  # submitted value and wrongly suppress the very first save (AC1).
  defp changed_storage_keys(changes) do
    persisted = StorageConfig.get()
    Map.filter(changes, fn {key, value} -> Map.get(persisted, key) != value end)
  end

  defp confirmed_orphan_risk?(params), do: params["confirm_orphan_risk"] == "true"

  defp persist_storage_config(conn, changes) do
    case StorageConfig.upsert(changes, actor_id(conn)) do
      :ok ->
        conn
        |> put_flash(:info, "Storage settings saved")
        |> redirect(to: "/admin/media/settings")

      {:error, _reason} ->
        conn
        |> put_status(200)
        |> put_flash(:error, "Failed to save storage settings")
        |> render_settings(state_from_config(Config.get()))
    end
  end

  # Required: endpoint/bucket. Optional fields (region, s3_key_prefix_template,
  # archive_bucket, access_key, secret_key) are OMITTED from the returned map
  # when blank, so Nebu.Media.StorageConfig.upsert/2's partial-update
  # semantics leave them untouched — this is what makes a blank secret field
  # mean "leave unchanged" (AC2) rather than "clear the stored secret".
  defp validate_storage_params(params) do
    endpoint = String.trim(params["endpoint"] || "")
    bucket = String.trim(params["bucket"] || "")

    cond do
      endpoint == "" ->
        {:error, "Endpoint is required."}

      bucket == "" ->
        {:error, "Bucket is required."}

      invalid_endpoint_scheme?(endpoint) ->
        {:error, @storage_invalid_endpoint_message}

      true ->
        changes =
          %{endpoint: endpoint, bucket: bucket, use_ssl: params["use_ssl"] == "true"}
          |> maybe_put_field(:region, params["region"])
          |> maybe_put_field(:s3_key_prefix_template, params["s3_key_prefix_template"])
          |> maybe_put_field(:archive_bucket, params["archive_bucket"])
          |> maybe_put_field(:access_key, params["access_key"])
          |> maybe_put_field(:secret_key, params["secret_key"])

        {:ok, changes}
    end
  end

  # M-1 (SSRF + transport-downgrade, forward-carried from the 11a security
  # review): mirrors the identical guard in Nebu.Media.StorageConfig's own
  # test_connection/1 (defense in depth — this controller-level check stops
  # a bad endpoint before it ever reaches upsert/2, not just before an ExAws
  # call). runtime.exs's NEBU_MINIO_ENDPOINT contract is bare host[:port],
  # never a URL with a scheme.
  defp invalid_endpoint_scheme?(endpoint) do
    downcased = String.downcase(endpoint)
    String.starts_with?(downcased, "http://") or String.starts_with?(downcased, "https://")
  end

  defp maybe_put_field(map, key, raw) do
    case blank_to_nil(raw) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Candidate map for Nebu.Media.StorageConfig.test_connection/1 — atom-keyed,
  # secrets left nil (not "") when blank so StorageConfig's own blank-secret
  # resolution (server-side, against the stored decrypted secret) applies.
  defp candidate_from_params(params) do
    %{
      endpoint: String.trim(params["endpoint"] || ""),
      bucket: String.trim(params["bucket"] || ""),
      region: String.trim(params["region"] || ""),
      use_ssl: params["use_ssl"] == "true",
      access_key: blank_to_nil(params["access_key"]),
      secret_key: blank_to_nil(params["secret_key"])
    }
  end

  # Echoes the submitted (unsaved) non-secret values back for a blocked/
  # invalid re-render (AC4: "the submitted non-secret field values
  # preserved, not reset") — access_key/secret_key are always nil here (the
  # form never renders a value= attribute for them regardless, but keeping
  # the map itself free of the submitted plaintext is an extra guard against
  # ever accidentally wiring it into the template later).
  defp storage_config_from_params(params) do
    %{
      endpoint: params["endpoint"] || "",
      bucket: params["bucket"] || "",
      region: params["region"] || "",
      use_ssl: params["use_ssl"] == "true",
      access_key: nil,
      secret_key: nil,
      s3_key_prefix_template: params["s3_key_prefix_template"] || "",
      archive_bucket: params["archive_bucket"] || ""
    }
  end

  def save(conn, params) do
    case validate_and_normalize(params) do
      {:ok, changes} ->
        previous = Config.get()
        actor = actor_id(conn)
        changed = changed_keys(changes, previous)

        case persist(changed, actor) do
          :ok ->
            conn
            |> put_flash(:info, "Media settings saved")
            |> maybe_warn_released_delete_change(previous, changes)
            |> redirect(to: "/admin/media/settings")

          {:error, _reason} ->
            conn
            |> put_status(200)
            |> put_flash(:error, "Failed to save media settings")
            |> render_settings(state_from_params(params))
        end

      {:error, message} ->
        conn
        |> put_status(200)
        |> put_flash(:error, message)
        |> render_settings(state_from_params(params))
    end
  end

  # ── validation (AC2/AC3) — fully validate before ANY persistence call ──────

  defp validate_and_normalize(params) do
    with {:ok, numeric_changes} <- validate_numeric_fields(params),
         {:ok, webhook_value} <- validate_webhook_url(params["webhook_url"]),
         {:ok, released_value} <-
           validate_released_delete_after_days(params["released_delete_after_days"]) do
      changes =
        numeric_changes
        |> Map.put("webhook_url", webhook_value)
        |> Map.put("released_delete_after_days", released_value)

      {:ok, changes}
    end
  end

  defp validate_numeric_fields(params) do
    Enum.reduce_while(@numeric_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case validate_bound(field, params[field]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp validate_bound(field, raw) do
    {min, max} = Map.fetch!(@bounds, field)
    trimmed = String.trim(raw || "")

    if trimmed == "" do
      {:error, "#{field} is required and must be a whole number."}
    else
      case Integer.parse(trimmed) do
        {n, ""} when n >= min and n <= max ->
          {:ok, n}

        {n, ""} ->
          {:error, "#{field} must be a whole number between #{min} and #{max} (got #{n})."}

        _ ->
          {:error, "#{field} must be a whole number."}
      end
    end
  end

  # AC3: HTTPS required, then delegate the private/loopback/link-local IP
  # check to Nebu.Media.SSRF.check/1 verbatim — never re-derived here. A
  # blank submission means "unset" (nil), matching this codebase's
  # established blank-means-no-limit convention.
  defp validate_webhook_url(raw) do
    trimmed = String.trim(raw || "")

    if trimmed == "" do
      {:ok, nil}
    else
      case URI.parse(trimmed) do
        %URI{scheme: "https"} ->
          case SSRF.check(trimmed) do
            :ok ->
              {:ok, trimmed}

            {:error, _reason} ->
              {:error,
               "Webhook URL is blocked: it resolves to a private, loopback, or link-local " <>
                 "address, which is not allowed."}
          end

        _ ->
          {:error, "Webhook URL must use HTTPS."}
      end
    end
  end

  # Blank means "unset" (nil) — the "never auto-delete" sentinel.
  defp validate_released_delete_after_days(raw) do
    trimmed = String.trim(raw || "")

    if trimmed == "" do
      {:ok, nil}
    else
      case Integer.parse(trimmed) do
        {n, ""} when n >= 0 ->
          {:ok, n}

        _ ->
          {:error,
           "released_delete_after_days must be a non-negative whole number, or left blank to disable."}
      end
    end
  end

  # code review (Cycle 1, MINOR-2): only the keys whose validated value
  # actually differs from Config.get/0's current catalog are persisted — a
  # no-op resubmit (every field identical to its current stored/default
  # value) therefore triggers ZERO Nebu.Media.Config.upsert/3 calls instead
  # of unconditionally rewriting all 9 keys. This avoids two problems the
  # previous always-write-everything behavior had: (a) audit-log noise — a
  # no-op save no longer produces 9 `media_config_updated` audit entries (8
  # of them old_value==new_value) plus 9 refresh/:pg-broadcast round-trips;
  # (b) "default pinning" — the FIRST save ever no longer writes an explicit
  # row for every key, so a future config.exs default change for a key the
  # admin never intentionally touched is no longer silently ignored.
  #
  # `previous` (Config.get/0's shape) is atom-keyed; `changes` (this
  # controller's validated params) is string-keyed — @key_to_atom bridges
  # the two, mirroring Nebu.Media.Config's own internal convention for the
  # same key-space translation.
  defp changed_keys(changes, previous) do
    Map.filter(changes, fn {key, value} ->
      Map.get(previous, Map.fetch!(@key_to_atom, key)) != value
    end)
  end

  # ── persistence (ADR-020: Nebu.Media.Config.upsert/3 only, one call per key) ──

  # code review (Cycle 1, MINOR-1): this loop is NOT atomic at the DB layer —
  # if key N of `changes` fails after keys 1..(N-1) already committed, those
  # keys stay persisted while the caller sees a generic "Failed to save"
  # flash implying nothing was saved. Nebu.Media.Config's public API
  # (ADR-020) intentionally has no cross-call transaction seam (`upsert/3` is
  # one call per key, by design — Story 9a); adding one is out of scope for
  # this controller. Accepted, known limitation, same documentation style as
  # Nebu.Media.Config's own moduledoc "Code review (Cycle 0, m3)" note on its
  # DB-write/audit-write non-atomicity. `changed_keys/2` above already
  # shrinks the blast radius to just the fields that actually changed,
  # rather than always all 9, so the residual risk here is now much smaller
  # than a full-catalog write on every save.
  defp persist(changes, actor) do
    Enum.reduce_while(changes, :ok, fn {key, value}, :ok ->
      case Config.upsert(key, value, actor) do
        :ok -> {:cont, :ok}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  # Mirrors Nebu.Admin.UsersController.actor_id/1 — the real admin's
  # identity (matrix_user_id, falling back to sub) attributes the
  # `media_config_updated` audit-log entry to the actual operator instead of
  # Nebu.Media.Config's generic default actor.
  defp actor_id(conn) do
    case conn.assigns[:current_user] do
      %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
      %{"sub" => sub} when is_binary(sub) -> sub
      _ -> "system:media_config"
    end
  end

  # AC4: only when released_delete_after_days transitions from unset (nil)
  # to a concrete value — not concrete-to-concrete, not value-to-nil.
  defp maybe_warn_released_delete_change(conn, previous, changes) do
    old_value = previous.released_delete_after_days
    new_value = Map.get(changes, "released_delete_after_days")

    if is_nil(old_value) and not is_nil(new_value) do
      put_flash(conn, :warning, @strong_warning_copy)
    else
      conn
    end
  end

  # ── state / rendering ────────────────────────────────────────────────────

  defp state_from_config(cfg) do
    %{
      "max_upload_size_bytes" => to_string(cfg.max_upload_size_bytes),
      "max_file_size_bytes" => to_string(cfg.max_file_size_bytes),
      "max_pending_per_user" => to_string(cfg.max_pending_per_user),
      "max_stall_ms" => to_string(cfg.max_stall_ms),
      "deleted_days" => to_string(cfg.deleted_days),
      "infected_days" => to_string(cfg.infected_days),
      "orphaned_hours" => to_string(cfg.orphaned_hours),
      "webhook_url" => cfg.webhook_url || "",
      "released_delete_after_days" => nilable_to_string(cfg.released_delete_after_days)
    }
  end

  # AC6: on a validation error, echo the operator's submitted values back
  # verbatim (never silently clear them) — mirrors
  # Nebu.Admin.LogsController.state_from_params/1.
  defp state_from_params(params) do
    Map.new(@all_fields, fn field -> {field, params[field] || ""} end)
  end

  defp nilable_to_string(nil), do: ""
  defp nilable_to_string(n) when is_integer(n), do: to_string(n)

  defp render_settings(conn, state, opts \\ []) do
    current_storage_cfg = StorageConfig.get()
    storage_config = Keyword.get(opts, :storage_config, current_storage_cfg)

    conn
    |> assign(:state, state)
    |> assign(:storage_config, storage_config)
    |> assign(:access_key_configured, not is_nil(current_storage_cfg.access_key))
    |> assign(:secret_key_configured, not is_nil(current_storage_cfg.secret_key))
    |> assign(:orphan_warning, Keyword.get(opts, :orphan_warning))
    |> assign(:test_connection_result, Keyword.get(opts, :test_connection_result))
    |> assign(:page_title, "Media Settings")
    |> assign(:active_nav, "media-settings")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end
end
