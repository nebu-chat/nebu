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
  `Nebu.Media.Config.get/0` (read, to pre-fill the form), `Nebu.Media.Config.damaged_keys/0`
  (the stored rows that cannot be read: a warning above the form, and a plain save rewrites them) and
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
      the gate. A non-nil `iam_endpoint`/`sts_endpoint` in the DECIDED
      changes (i.e. actually about to be written, not merely submitted
      unchanged) must be a full `https://` URL passing
      `Nebu.Media.SSRF.checked_target/1`
      (F-1 fix, Kassandra security review, SEC Gate 1, 2026-10-08; rescoped to
      the decided value by the R-1 fix, 2026-10-08) — see
      `validate_changes_iam_sts/1` — mirrored at the persist layer by
      `Nebu.Media.StorageConfig.validate_iam_sts_fields/1` so the guard holds
      regardless of caller.
    * `test_connection/2` — resolves the submitted candidate (blank secrets
      resolved server-side against the stored secret, ONLY when the submitted endpoint and scheme are the stored ones, else the form must carry the keys) via
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

  # story admin-forms-gate-sweep: the strict fetch metadata of a user-clicked form submit (Safari: the click proof) before anything is read or changed
  import Nebu.Admin.OAuthAdminHelpers, only: [click_gate: 2]
  plug :click_gate when action in [:test_connection]

  @storage_generic_failure_message "Connection failed. Check the endpoint, bucket, region, and " <>
                                      "credentials, then try again."
  @storage_invalid_endpoint_message "Endpoint must be a bare host[:port] value " <>
                                       "(no http:// or https:// scheme prefix)."
  @storage_invalid_iam_sts_message "IAM/STS endpoint is invalid."

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

  # the writer's own cap (Nebu.Media.Config: what its tolerant decode reads back), so a saved value is never read as damaged
  @released_delete_after_days_max 999_999_999_999_999_999

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

  # story admin-forms-gate-sweep (D1 / D2): the media policy and the storage target are `:marker` forms: strict fetch metadata, then a fresh admin sign-in bound
  # to /admin/media/settings (one marker for both forms: the page holds ONE object, the instance configuration), before anything is validated or written;
  # the marker is consumed after a SUCCESSFUL save only
  @page "/admin/media/settings"

  def save_storage(conn, params) do
    with {:ok, conn, _kind} <- Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, @page) do
      do_save_storage(conn, params)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_save_storage(conn, params) do
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
          test_connection_result:
            {:error, StorageConfig.describe_invalid_endpoint(candidate.endpoint)}
        )

      # story admin-forms-gate-sweep D4: the stored credentials belong to the stored endpoint and scheme only
      {:error, :secret_required} ->
        # for the stored target itself the keys are what is wrong (missing, half a pair, undecryptable): say so
        message =
          if StorageConfig.stored_target?(candidate.endpoint, candidate.use_ssl) do
            "The stored access key and secret key are missing or unusable. Enter both keys to test. Nothing was saved."
          else
            "Enter the access key and secret key to test a different endpoint or a changed Use SSL setting: the stored credentials are only used for the stored endpoint and scheme. Nothing was saved."
          end

        conn
        |> put_status(200)
        |> render_settings(state_from_config(Config.get()),
          storage_config: storage_config_from_params(params),
          test_connection_result: {:error, message}
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
          persist_storage_config(conn, params, changed_storage_keys(changes))
        end

      :fresh ->
        persist_storage_config(conn, params, changes)
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
      persist_storage_config(conn, params, changed_storage_keys(changes))
    end
  end

  defp target_changed?(changes, old_endpoint, old_bucket) do
    changes.endpoint != old_endpoint or changes.bucket != old_bucket
  end

  # code review (Cycle 2, MINOR-2): mirrors save/2's own changed_keys/2 —
  # diffs the submitted storage-target `changes` against the currently
  # persisted (StorageConfig.get/0, the same merged view that pre-fills the
  # form) values, which keeps a no-op/single-field resubmit from writing the
  # whole submitted field set. (The audit `changed_fields` is decided by
  # StorageConfig.upsert/2 itself, against the row as it was before the write:
  # it names the really changed fields, so the endpoint / use_ssl added for a
  # key save below are not named when they equal the stored values.)
  # The AC4 orphan-risk-gate comparison above (`target_changed?`)
  # deliberately runs FIRST against the raw, undiffed `changes` — orphan-risk
  # detection must see the actual submitted endpoint/bucket, not a
  # post-diff-filtered view. Only reached once `persisted_target/0` has
  # already confirmed a row exists (the `:fresh` branch above calls
  # `persist_storage_config/2` directly, unfiltered): on a genuinely fresh
  # config there is nothing yet to diff against, and `get/0`'s env-var/
  # compiled-default-merged view could otherwise coincidentally match a
  # submitted value and wrongly suppress the very first save (AC1).
  #
  # A save that carries keys always writes `endpoint` and `use_ssl` with them (also when they equal the stored view): the
  # keys are saved for exactly that target, in the same row write, so a row never holds keys for one endpoint and another
  # endpoint beside them. (`upsert/2` validates the endpoint then, including the SSRF / DNS check.)
  defp changed_storage_keys(changes) do
    persisted = StorageConfig.get()
    changed = Map.filter(changes, fn {key, value} -> Map.get(persisted, key) != value end)

    if Map.has_key?(changes, :access_key) or Map.has_key?(changes, :secret_key) do
      Map.merge(changed, Map.take(changes, [:endpoint, :use_ssl]))
    else
      changed
    end
  end

  defp confirmed_orphan_risk?(params), do: params["confirm_orphan_risk"] == "true"

  # A validation error re-renders the form with the values the admin typed (never the keys); the message is rendered
  # in the Storage Target section, in the position of the Test Connection result, with aria hooks on the fields it is
  # about. The sign-in marker stays and nothing is written or audited.
  defp persist_storage_config(conn, params, changes) do
    case StorageConfig.upsert(changes, actor_id(conn)) do
      :ok ->
        conn
        |> Nebu.Admin.Auth.consume_reauth()
        |> put_flash(:info, "Storage settings saved")
        |> redirect(to: "/admin/media/settings")

      {:error, :invalid_endpoint} ->
        render_storage_validation_error(conn, params, StorageConfig.describe_invalid_endpoint(String.trim(params["endpoint"] || "")), ["endpoint"])

      {:error, :secret_required} ->
        render_storage_validation_error(
          conn,
          params,
          "Enter the access key and secret key to use a different endpoint or a changed Use SSL setting. " <>
            "The stored credentials are only used for the stored endpoint and scheme. Nothing was saved.",
          ["access_key", "secret_key"]
        )

      {:error, :key_pair_required} ->
        render_storage_validation_error(conn, params, "Enter both the access key and the secret key. Nothing was saved.", ["access_key", "secret_key"])

      {:error, _reason} ->
        conn
        |> put_status(200)
        |> put_flash(:error, "Failed to save storage settings")
        |> render_settings(state_from_config(Config.get()))
    end
  end

  # `fields`: the ids of the inputs the message is about (aria-invalid / aria-describedby). A ticked orphan-risk
  # confirmation stays ticked and its warning stays visible, so the next submit with the keys passes without a third
  # round trip.
  defp render_storage_validation_error(conn, params, message, fields) do
    confirmed? = confirmed_orphan_risk?(params)
    existing_count = if confirmed?, do: DB.count_media_with_storage_key(), else: 0

    conn
    |> put_status(200)
    |> render_settings(state_from_config(Config.get()),
      storage_config: storage_config_from_params(params),
      storage_save_error: {message, fields},
      orphan_warning: if(existing_count > 0, do: existing_count),
      orphan_confirmed: confirmed?
    )
  end

  # Required: endpoint/bucket. Optional fields (region, s3_key_prefix_template,
  # archive_bucket, access_key, secret_key) are OMITTED from the returned map
  # when blank, so Nebu.Media.StorageConfig.upsert/2's partial-update
  # semantics leave them untouched — this is what makes a blank secret field
  # mean "leave unchanged" (AC2) rather than "clear the stored secret".
  # iam_endpoint/sts_endpoint are infra metadata about how to reach the
  # store, not the store target itself — bugfix-add-sts-iam-endpoints-to-
  # admin-ui (AC3/AC4) deliberately does NOT add them to target_changed?/3's
  # orphan-risk-gate comparison below (that stays scoped to endpoint/bucket
  # only).
  #
  # code review (cycle 1, MAJOR-1): iam_endpoint/sts_endpoint do NOT use the
  # plain maybe_put_field/3 blank-omit rule above — they get a multi-rule
  # cond instead (put_env_backed_field/5 below), because the form PRE-FILLS these
  # two inputs from the env-resolved value even when no DB override exists
  # yet (AC5). A plain blank-omit would let an untouched, env-pre-filled
  # value get silently written to the DB the very first time ANY storage
  # field is saved on a fresh config, permanently shadowing future
  # Terraform/env changes to these URLs — that was MAJOR-1.
  #
  # code review (cycle 1 re-review, MAJOR-N1): the ORIGINAL cycle-1 fix
  # baselined rule 2 ("untouched -> omit") on `StorageConfig.env_only_iam_sts/0`
  # — the env var ALONE, ignoring any existing DB override. That meant: if a
  # DB override X already existed and the admin deliberately edited the field
  # to the env value Y (a legitimate change — "go back to what the
  # environment says, I happen to know what that is"), the submission matched
  # the env value and was silently discarded — the admin's edit never reached
  # the DB, with a false "saved successfully" flash. The fix: baseline rule 2
  # on the ACTUAL CURRENTLY-EFFECTIVE value (`StorageConfig.get()` — DB
  # override if one exists, else env, else default; the SAME resolved value
  # this controller already uses elsewhere, e.g. `changed_storage_keys/1`
  # above), not the env-only value. `env_only_iam_sts/0` is gone — nothing
  # calls it any more. The rule (now baselined on the resolved value):
  #
  #   1. submitted value == current resolved value -> OMIT the key entirely
  #      (the admin didn't change anything from what's actually in effect,
  #      whether that's DB- or env-sourced; also covers "both blank" — e.g.
  #      an env var set to "" on a fresh install — so a field that was never
  #      meaningfully set never re-issues a redundant `SET ... = NULL` write
  #      or a bogus audit entry on every save)
  #   2. submitted value is blank (and differs from a non-blank resolved
  #      value) -> explicit `nil` (a genuine "clear my override, go back to
  #      env-controlled" action — reaches column_for/2/build_columns/1 as a
  #      real `SET column = NULL`, never just omitted)
  #   3. submitted value is non-blank AND differs from the resolved value
  #      -> include it (a genuine, deliberate override — persisted exactly
  #      like every other optional field above, EVEN IF it happens to equal
  #      the env value, as long as it differs from what was actually in
  #      effect — this is the MAJOR-N1 fix)
  #
  # code review (cycle 2 re-review, N2-MINOR-1 / N2-MINOR-2 fix): two more
  # refinements, both folded into put_env_backed_field/5 below (now arity 5
  # — see the plain comment directly above its definition for the full
  # per-clause breakdown, now 5 clauses, not 3):
  #
  #   * N2-MINOR-1 — rule 2 above ("blanked -> explicit nil") used to fire
  #     whenever the RESOLVED baseline was non-blank, regardless of whether
  #     that baseline came from an actual DB override or just the env var.
  #     If no DB override exists for the field, there is nothing to
  #     "clear" — writing nil over an already-nil column is a pointless
  #     no-op write that also pollutes the audit trail (changed_fields
  #     names a field that didn't actually change). Rule 2 now ALSO
  #     requires `has_db_override?` (from the NEW
  #     `StorageConfig.persisted_iam_sts/0` accessor, the raw DB-only row —
  #     never `resolved`/`get/0`'s merged view) before writing an explicit
  #     nil; a blanked, env-only (no DB override) field is now a plain
  #     no-op/omit instead.
  #   * N2-MINOR-2 — a POST that OMITS the param entirely (`params["iam_endpoint"]`
  #     absent from `params`, not an empty-string VALUE) came through as
  #     `raw = nil`, indistinguishable from "admin submitted blank" and
  #     triggering the same clear logic — inconsistent with every other
  #     optional field (`maybe_put_field/3`), which already treats an absent
  #     param as "nothing to do," never as "clear this." A genuinely blank
  #     *submitted* value (`raw = ""`) is unaffected — `blank_to_nil("")`
  #     still yields `nil` and falls through to the (now has_db_override?-
  #     gated) clear-or-omit logic below it.
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
        resolved = StorageConfig.get()
        # code review (cycle 2, N2-MINOR-1 fix): the RAW DB-only row — `nil`
        # per field whenever NO db override currently exists for it — is the
        # `has_db_override?` baseline put_env_backed_field/5 needs below.
        # NEVER `resolved` itself (that's the DB>env>default MERGED view,
        # which can be non-blank purely from an env var with no DB row at
        # all).
        persisted_iam_sts = StorageConfig.persisted_iam_sts()

        changes =
          %{endpoint: endpoint, bucket: bucket, use_ssl: params["use_ssl"] == "true"}
          |> maybe_put_field(:region, params["region"])
          |> maybe_put_field(:s3_key_prefix_template, params["s3_key_prefix_template"])
          |> maybe_put_field(:archive_bucket, params["archive_bucket"])
          |> put_env_backed_field(
            :iam_endpoint,
            params["iam_endpoint"],
            resolved.iam_endpoint,
            not is_nil(blank_to_nil(persisted_iam_sts.iam_endpoint))
          )
          |> put_env_backed_field(
            :sts_endpoint,
            params["sts_endpoint"],
            resolved.sts_endpoint,
            not is_nil(blank_to_nil(persisted_iam_sts.sts_endpoint))
          )
          |> maybe_put_field(:access_key, params["access_key"])
          |> maybe_put_field(:secret_key, params["secret_key"])

        case validate_changes_iam_sts(changes) do
          :ok -> {:ok, changes}
          {:error, reason} -> {:error, @storage_invalid_iam_sts_message <> " " <> reason}
        end
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

  # F-1 fix (Kassandra security review, SEC Gate 1, 2026-10-08): unlike
  # `endpoint` (a bare host[:port], guarded above by
  # invalid_endpoint_scheme?/1), iam_endpoint/sts_endpoint are full URLs
  # (UpCloud's iam_url/sts_url shape) — they are admin-UI-writable and
  # DB-persisted (AC1/AC2 of this story) but had NO scheme assertion and NO
  # SSRF guard, unlike every other admin-writable endpoint-shaped field on
  # this page (`endpoint`, `webhook_url`). The structural guarantee that
  # justified leaving these two unvalidated in the predecessor story
  # (bugfix-upcloud-s3-iam-sts-endpoints) — no DB write path existed at all
  # — is exactly what this story removed.
  #
  # Mirrors `endpoint`'s own two-layer guard shape (controller +
  # model — see Nebu.Media.StorageConfig.validate_iam_sts_fields/1 for the
  # persist-path mirror of this same check), adapted for a full URL: require
  # an `https://` scheme, then run the whole URL through the SAME
  # `Nebu.Media.SSRF.checked_target/1` guard `endpoint`/`webhook_url` already
  # use — no synthetic `http://` prefix needed here (unlike
  # invalid_endpoint_scheme?/1's sibling check for `endpoint`'s bare
  # host[:port] contract), since these fields are already full URLs.
  #
  # R-1 fix (focused follow-up review, 2026-10-08): this validates the
  # DECIDED `changes` map — the output of put_env_backed_field/5's
  # clear/no-op/override decision — NOT the raw submitted param. The
  # original F-1 fix validated params["iam_endpoint"]/params["sts_endpoint"]
  # unconditionally, in validate_storage_params/1's `cond`, BEFORE `changes`
  # was even built: an untouched, env-pre-filled value that happens to fail
  # this very check (e.g. a private/internal address — exactly this
  # project's own `NEBU_MINIO_ENDPOINT: "minio:9000"` docker-compose
  # convention, if ever applied to NEBU_MINIO_IAM_ENDPOINT/
  # NEBU_MINIO_STS_ENDPOINT) would then permanently block EVERY storage
  # save, not just that field — since the form always re-renders the same
  # env value, the admin could never again save any storage setting without
  # manually blanking the field on every single submission, forever.
  #
  # A key ABSENT from `changes` (rule 1/N2-MINOR-1/N2-MINOR-2 of
  # put_env_backed_field/5 — untouched, or env-only-no-op) has nothing to
  # validate: nothing is being written, so it is skipped. A key present with
  # value `nil` (rule 2 — an explicit clear) is always valid: `nil` is the
  # "go back to env-controlled" sentinel, never a candidate URL — mirrors
  # Nebu.Media.StorageConfig.validate_iam_sts_field/2's own `{:ok, nil} ->
  # :ok` clause one layer down. Only a key present with a non-nil value
  # (rule 3 — a genuine, deliberate override actually about to be persisted)
  # is validated — same https:// + SSRF.checked_target/1 rule as before,
  # just applied to the right input.
  defp validate_changes_iam_sts(changes) do
    with :ok <- validate_change_iam_sts_field(changes, :iam_endpoint) do
      validate_change_iam_sts_field(changes, :sts_endpoint)
    end
  end

  defp validate_change_iam_sts_field(changes, key) do
    case Map.fetch(changes, key) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, value} ->
        iam_sts_url_problem(value)
    end
  end

  # `:ok`, or `{:error, human_readable_reason}` — the reason is shown to the
  # admin (and logged) so a DNS failure or a private-resolving host is not
  # reported as the same generic "invalid URL".
  defp iam_sts_url_problem(value) do
    cond do
      not String.starts_with?(String.downcase(value), "https://") ->
        {:error, "The URL must start with https://."}

      # before the SSRF check and before any log line; neither the message nor the log names any part of the URL (it holds a credential)
      StorageConfig.iam_sts_user_info?(value) ->
        Logger.warning("Nebu.Admin.MediaSettingsController: IAM/STS endpoint rejected: the URL carries user info (the URL is not logged)")
        {:error, "The URL must not contain a user name or password."}

      true ->
        case SSRF.checked_target(value, allow_private: SSRF.allow_private_storage?()) do
          {:ok, _target} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Nebu.Admin.MediaSettingsController: IAM/STS endpoint host #{inspect(URI.parse(value).host)} rejected: " <>
                SSRF.describe_error(reason)
            )

            {:error, "Rejected: " <> SSRF.describe_error(reason) <> "."}
        end
    end
  end

  defp maybe_put_field(map, key, raw) do
    case blank_to_nil(raw) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  # MAJOR-1 fix (cycle 1) / MAJOR-N1 fix (cycle 1 re-review) / N2-MINOR-1,
  # N2-MINOR-2 fix (cycle 2 re-review): the clear/no-op/override rule for
  # iam_endpoint/sts_endpoint ONLY — see validate_storage_params/1's comment
  # above for the full rationale. `resolved_value` is this field's
  # CURRENTLY-EFFECTIVE value (`StorageConfig.get()` — DB override if one
  # exists, else env, else default), i.e. exactly what the form pre-filled
  # this input with. `has_db_override?` is whether a `media_storage_config`
  # row's OWN column currently holds a non-blank value for this field (the
  # caller passes `StorageConfig.persisted_iam_sts/0`'s raw DB row, already
  # normalized through `blank_to_nil/1` — never the resolved/merged view) —
  # this is what lets rule 2 below tell "there is an actual override to
  # clear" apart from "the baseline is merely non-blank because of an env
  # var." Both `submitted`/`baseline` are normalized through `blank_to_nil/1`
  # before comparing, so an untrimmed env value and a set-but-empty env
  # value behave identically to their trimmed/nil counterparts (cycle 1
  # re-review).
  defp put_env_backed_field(map, key, raw, resolved_value, has_db_override?) do
    submitted = blank_to_nil(raw)
    baseline = blank_to_nil(resolved_value)

    cond do
      # N2-MINOR-2: the param was entirely ABSENT from the POST (never even
      # an empty-string VALUE) -> always a no-op, never a clear. Only a
      # scripted/non-browser POST can produce this (every real HTML form
      # submission sends the field, even blank) — but it must behave like
      # every other optional field's maybe_put_field/3: "nothing submitted"
      # means "nothing to do," not "clear this."
      is_nil(raw) ->
        map

      # Rule 1: untouched (whether DB- or env-sourced), or both blank -> omit
      # (no-op, never written — this is what prevents the silent first-save
      # env->DB promotion AND what makes a set-but-empty env var converge
      # instead of re-writing NULL-over-NULL forever).
      submitted == baseline ->
        map

      # Rule 2: baseline was non-blank, the admin blanked the field, AND a
      # genuine DB override currently exists for it -> explicit nil (clears
      # that override back to env-controlled; must reach column_for/2 as a
      # real SET ... = NULL, never an omission).
      submitted == nil and has_db_override? ->
        Map.put(map, key, nil)

      # N2-MINOR-1: baseline was non-blank purely from the env var (no DB
      # override exists) and the admin blanked the field -> omit, not an
      # explicit nil. There is nothing to actually clear; writing nil here
      # would be a pointless, forever-repeating `SET ... = NULL` plus a
      # false audit changed_fields entry.
      submitted == nil ->
        map

      # Rule 3: a genuine, non-blank value that differs from what's
      # currently in effect -> persist it normally, even if it happens to
      # equal the env value (MAJOR-N1: a deliberate edit back to the env
      # value, when a DB override was in effect, must NOT be discarded).
      true ->
        Map.put(map, key, submitted)
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
      iam_endpoint: blank_to_nil(params["iam_endpoint"]),
      sts_endpoint: blank_to_nil(params["sts_endpoint"]),
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
  #
  # story admin-reauth-button-flow (Kassandra delta): an endpoint value that carries user info (`user:password@host`, refused by the validation) is NOT
  # echoed either: it holds a credential, like the keys above.
  defp storage_config_from_params(params) do
    %{
      endpoint: echo_endpoint(params["endpoint"]),
      bucket: params["bucket"] || "",
      region: params["region"] || "",
      use_ssl: params["use_ssl"] == "true",
      access_key: nil,
      secret_key: nil,
      s3_key_prefix_template: params["s3_key_prefix_template"] || "",
      archive_bucket: params["archive_bucket"] || "",
      iam_endpoint: echo_endpoint(params["iam_endpoint"]),
      sts_endpoint: echo_endpoint(params["sts_endpoint"])
    }
  end

  defp echo_endpoint(value) when is_binary(value), do: if(StorageConfig.iam_sts_user_info?(value), do: "", else: value)
  defp echo_endpoint(_), do: ""

  def save(conn, params) do
    with {:ok, conn, _kind} <- Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, @page) do
      do_save(conn, params)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_save(conn, params) do
    case validate_and_normalize(params) do
      {:ok, changes} ->
        previous = Config.get()
        actor = actor_id(conn)
        changed = changed_keys(changes, previous, Config.damaged_keys())

        case persist(changed, actor) do
          :ok ->
            conn
            |> Nebu.Admin.Auth.consume_reauth()
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
        {n, ""} when n >= 0 and n <= @released_delete_after_days_max ->
          {:ok, n}

        _ ->
          {:error,
           "released_delete_after_days must be a non-negative whole number (at most #{@released_delete_after_days_max}), or left blank to disable."}
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
  #
  # story media-config-tolerant-loader (D6): a key whose stored row is damaged (`Config.damaged_keys/0`) shows its default in `previous`, so a plain
  # "Save" of that shown default would be filtered out as "unchanged" and the damaged row would stay. A damaged key that is part of the submitted form is
  # therefore always written (normal gate, validation and audit of `Config.upsert/3`); a damaged key the form does not carry is not in `changes`.
  defp changed_keys(changes, previous, damaged) do
    Map.filter(changes, fn {key, value} ->
      key in damaged or Map.get(previous, Map.fetch!(@key_to_atom, key)) != value
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
  # One `Config.upsert/3` per changed key, in SORTED key order (deterministic: which keys are already committed when a later one fails does not depend on
  # map iteration). There is no cross-key atomicity (the known per-key limitation of this controller): the earlier keys stay committed when a later one
  # fails. A refused shortening of a retention value (`{:error, {:audit, _}}`, story media-retention-audit-atomic: its audit row cannot be written) takes
  # the same generic failure path as any other error: the flash never names the reason.
  defp persist(changes, actor) do
    changes
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
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
      %{"sub" => sub} when is_binary(sub) and sub != "" -> sub
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

  # story media-config-tolerant-loader (D5): the damaged keys split by what the admin can do about them on THIS page. A key of the form is rewritten by a
  # save (with the value shown in its field); a key the form does not carry (alert thresholds, scan_kill_switch, mime_denylist) can only be repaired in
  # the database. `:damaged_retention_keys` = the keys whose damage pauses the automatic cleanup.
  defp assign_damaged_media_keys(conn) do
    damaged = Config.damaged_keys()
    {on_form, off_form} = Enum.split_with(damaged, &(&1 in @all_fields))

    conn
    |> assign(:damaged_media_keys, damaged)
    |> assign(:damaged_form_keys, on_form)
    |> assign(:damaged_other_keys, off_form)
    |> assign(:damaged_retention_keys, Enum.filter(damaged, &(&1 in ["deleted_days", "infected_days"])))
  end

  defp nilable_to_string(nil), do: ""
  defp nilable_to_string(n) when is_integer(n), do: to_string(n)

  defp render_settings(conn, state, opts \\ []) do
    current_storage_cfg = StorageConfig.get()
    storage_config = Keyword.get(opts, :storage_config, current_storage_cfg)

    conn
    |> assign(:state, state)
    |> assign_damaged_media_keys()
    |> assign(:storage_config, storage_config)
    |> assign(:access_key_configured, not is_nil(current_storage_cfg.access_key))
    |> assign(:secret_key_configured, not is_nil(current_storage_cfg.secret_key))
    |> assign(:orphan_warning, Keyword.get(opts, :orphan_warning))
    |> assign(:orphan_confirmed, Keyword.get(opts, :orphan_confirmed, false))
    |> assign(:storage_save_error, Keyword.get(opts, :storage_save_error))
    |> assign(:test_connection_result, Keyword.get(opts, :test_connection_result))
    |> Nebu.Admin.OAuthAdminHelpers.assign_reauth(@page)
    |> assign(:page_title, "Media Settings")
    |> assign(:active_nav, "media-settings")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end
end
