defmodule Nebu.Compliance.UserDeletion do
  @moduledoc """
  Atomare DSGVO Key-Löschung für einen User (Story 5.7).

  delete_user_keys/3 prüft erst Guards außerhalb der TX, dann führt es
  Steps 2–5 in einer einzigen Repo-Transaktion aus:
    1. (Guard, outside TX) SELECT users — :user_not_found | :conflict guard
    2. UPDATE users SET deletion_status = 'deletion_in_progress'
    3. UPDATE user_keys SET private_key = NULL, deleted_at = <now_ms> WHERE key_type = 'signing'
    4. UPDATE user_keys SET private_key = NULL, deleted_at = <now_ms> WHERE key_type = 'encryption'
    4a. row locks (uia_sessions, cross_signing_keys) + the per-user `sync_global|` advisory lock: serialises
        the erasure with the account data / cross-signing writers (story gdpr-erasure-global-data, D1)
    4b. DELETE FROM <every table of erased_tables/0> WHERE user_id = <target> (room and global account data,
        cross-signing keys, device keys, the other per-user tables: follow-up `ck`, D2); then a check that no
        `oauth_codes` row of the user is left (fail closed without migration 000055, D18 (e): step
        `oauth_codes_not_erased`; a failing count query is the step `oauth_codes_check`)
    4c. UPDATE profiles SET displayname = 'Deleted User', avatar_url = NULL (D9)
    5. UPDATE users SET deletion_status = 'keys_deleted', keys_deleted_at = <now_ms>, anonymized_at = <now_ms>
       (when not yet set), is_active = false (the erasure is terminal for authentication, D17) and every
       PII column (display name, avatar, email ciphertexts, last_seen_at, deactivation_reason) to NULL (D16)

  Ecto Repo.transaction/1 Verhalten:
    - fun returns non-error → {:ok, value}
    - fun raises or calls rollback/1 → rollback, returns {:error, reason}
    - fun returns {:error, reason} → the transaction COMMITS and Ecto answers {:ok, {:error, reason}}
      (a step failure is a failed statement, which aborts the PostgreSQL transaction anyway; the one
      business error, :conflict from step 2, wrote nothing). delete_user_keys/3 unwraps it.

  Bei Transaktionsfehler (Steps 2–5 DB-Fehler) wird ein "user_keys_deletion_attempted"
  Audit-Eintrag in einer separaten AuditWriter-TX geschrieben (Failure Invariant, AC3).

  :user_not_found und :conflict sind Business-Logic-Guards (kein attempted-Audit).

  Persistenz-Strategie: Option B — PostgreSQL-persistent.
  Kein GenServer-State; kein Restart-Test erforderlich.
  """

  # story gdpr-erasure-global-data (follow-up `ck`, D1 / D2 / D3): every table whose rows of the user are physically deleted by the
  # erasure transaction, all keyed by a `user_id` column. The single source of truth of the erasure AND of the schema recurrence guard
  # (docs/architecture/08-concepts.md, "GDPR erasure inventory"): a new table with per-user data is added here or justified there.
  @erased_tables ~w(
    user_room_account_data account_data cross_signing_keys
    device_keys device_one_time_keys device_fallback_keys
    forgotten_rooms auto_join_opt_outs read_receipts
    uia_sessions oauth_account_sessions oauth_consent_requests oauth_codes
  )

  # the step name of each DELETE, fixed at compile time (the attempted audit and the log name the failing step)
  @erased_steps Enum.map(@erased_tables, &{&1, String.to_atom("delete_" <> &1)})

  @doc """
  The tables whose rows of the user `delete_user_keys/3` deletes in its transaction (`WHERE user_id = $1`).
  The deleting code and the schema recurrence guard test are driven by this list.
  """
  @spec erased_tables() :: [String.t()]
  def erased_tables, do: @erased_tables

  require Logger

  # Configurable repo for test injection.
  defp repo, do: Application.get_env(:compliance, :repo, Nebu.Repo)

  # Configurable AuditWriter for test injection.
  defp audit_writer, do: Application.get_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

  @doc """
  Atomically soft-deletes the private signing and encryption keys for `target_user_id`.

  Returns:
    - `{:ok, %{keys_deleted_at: integer()}}` on success (epoch milliseconds)
    - `{:error, :user_not_found}` when the user does not exist
    - `{:error, :conflict}` when deletion_status is already 'deletion_in_progress' or 'keys_deleted'
    - `{:error, term()}` on any DB/transaction failure (writes attempted-audit as failure invariant)
  """
  def delete_user_keys(admin_user_id, target_user_id, reason) do
    now_ms = System.system_time(:millisecond)

    # Step 1: Guard check outside the transaction.
    # :user_not_found and :conflict are business-logic guards — NOT transaction failures.
    # No attempted-audit is emitted for these (AC3 spec).
    case check_user(target_user_id) do
      {:error, :user_not_found} ->
        {:error, :user_not_found}

      {:error, :conflict} ->
        {:error, :conflict}

      {:error, db_error} ->
        # DB error on the SELECT check itself — rare but treat as failure.
        # NOTE: do NOT shadow `reason` (the deletion-reason string passed by the caller);
        # the attempted-audit must record the original deletion reason AND the DB error.
        db_error = safe_reason(db_error)
        emit_attempted_audit(admin_user_id, target_user_id, reason, db_error, :check_user)
        {:error, db_error}

      :ok ->
        # Steps 2–5 in a single Repo transaction.
        # A failed statement aborts the PostgreSQL transaction, so the deletion_in_progress marker
        # (Step 2) and every earlier step are rolled back with it. A failing step is THROWN out of
        # the transaction function (the transaction rolls back and re-throws) so that its name
        # survives: Ecto's own result for an aborted transaction is a bare {:error, :rollback}.
        tx_result =
          try do
            repo().transaction(fn ->
              with :ok <- mark_in_progress(target_user_id),
                   :ok <- step(:delete_signing_key, delete_signing_key(target_user_id, now_ms)),
                   :ok <- step(:delete_encryption_key, delete_encryption_key(target_user_id, now_ms)),
                   :ok <- step(:lock_user_writers, lock_user_writers(target_user_id)),
                   :ok <- delete_per_user_rows(target_user_id),
                   :ok <- step(:anonymise_profile, anonymise_profile(target_user_id)),
                   :ok <- step(:mark_keys_deleted, mark_keys_deleted(target_user_id, now_ms)) do
                now_ms
              end
            end)
          catch
            :throw, {:erasure_step_failed, failed_step, failed_reason} -> {:error, {:step_failed, failed_step, failed_reason}}
          end

        case unwrap_transaction(tx_result) do
          {:ok, keys_deleted_at_ms} ->
            # Transaction committed successfully — emit success audit.
            audit_writer().log(
              admin_user_id,
              "user_keys_deleted",
              "user",
              target_user_id,
              %{reason: reason},
              "success"
            )

            {:ok, %{keys_deleted_at: keys_deleted_at_ms}}

          {:error, :conflict} ->
            # mark_in_progress detected a concurrent deletion inside the TX.
            # :conflict is a business-logic guard — no attempted-audit (AC3 spec).
            {:error, :conflict}

          {:error, {:step_failed, failed_step, failed_reason}} ->
            # A step of the transaction failed (DB error in Steps 2–5): the whole transaction is rolled back.
            # The step name is a code atom and the reason is reduced to an atom / SQLSTATE (never row data).
            error_reason = safe_reason(failed_reason)
            Logger.error("user erasure failed and was rolled back in step #{failed_step}: #{inspect(error_reason)}")
            emit_attempted_audit(admin_user_id, target_user_id, reason, error_reason, failed_step)
            {:error, error_reason}

          {:error, error_reason} ->
            # Transaction failed without a named step (e.g. the commit).
            # Emit attempted-audit in separate AuditWriter TX (failure invariant, AC3).
            error_reason = safe_reason(error_reason)
            emit_attempted_audit(admin_user_id, target_user_id, reason, error_reason, nil)
            {:error, error_reason}
        end
    end
  end

  # ─── Step 1: Guard — check user existence ────────────────────────────────────
  #
  # FB-57-01: This SELECT checks existence and deletion_status for early-exit guards
  # (:user_not_found, :conflict when already in_progress/keys_deleted).
  # The TOCTOU window between this SELECT and Step 2 is closed by the atomic
  # conditional UPDATE in mark_in_progress/1 (which uses RETURNING to detect races).

  defp check_user(target_user_id) do
    sql = "SELECT user_id, deletion_status FROM users WHERE user_id = $1"

    case repo().query(sql, [target_user_id]) do
      {:ok, %{rows: []}} ->
        {:error, :user_not_found}

      {:ok, %{rows: [[_user_id, deletion_status] | _]}} ->
        if deletion_status in ["deletion_in_progress", "keys_deleted"] do
          {:error, :conflict}
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── Step 2: Mark deletion_in_progress (atomic conditional UPDATE) ───────────
  #
  # FB-57-01: Replace the old unconditional UPDATE with a single atomic
  # conditional UPDATE + RETURNING. This closes the TOCTOU race window between
  # check_user/1 and the status write:
  #
  #   UPDATE users
  #   SET deletion_status = 'deletion_in_progress'
  #   WHERE user_id = $1
  #     AND (deletion_status IS NULL OR deletion_status = 'active')
  #   RETURNING user_id
  #
  # If a concurrent caller already set deletion_in_progress between our SELECT
  # (step 1) and this UPDATE, the WHERE predicate finds 0 matching rows and
  # RETURNING returns an empty list → {:error, :conflict}.
  # This guarantees exactly-once semantics even under concurrent callers.

  defp mark_in_progress(target_user_id) do
    sql = """
    UPDATE users
    SET deletion_status = 'deletion_in_progress'
    WHERE user_id = $1
      AND (deletion_status IS NULL OR deletion_status = 'active')
    RETURNING user_id
    """

    case repo().query(sql, [target_user_id]) do
      {:ok, %{rows: []}} -> {:error, :conflict}
      {:ok, %{rows: [_ | _]}} -> :ok
      {:error, reason} -> step(:mark_in_progress, {:error, reason})
    end
  end

  # ─── Step 3: Soft-delete signing key ─────────────────────────────────────────

  defp delete_signing_key(target_user_id, now_ms) do
    sql = """
    UPDATE user_keys
    SET private_key = NULL, deleted_at = $1
    WHERE user_id = $2
      AND key_type = 'signing'
    """

    case repo().query(sql, [now_ms, target_user_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Step 4: Soft-delete encryption key ──────────────────────────────────────

  defp delete_encryption_key(target_user_id, now_ms) do
    sql = """
    UPDATE user_keys
    SET private_key = NULL, deleted_at = $1
    WHERE user_id = $2
      AND key_type = 'encryption'
    """

    case repo().query(sql, [now_ms, target_user_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Step 4a: serialise with the writers of the per-user global data (D1) ────
  #
  # AccountDataStore.put/3 and CrossSigningKeyStore.put_keys/2 write under the advisory lock
  # `sync_global|<user>`: a write in flight commits before the DELETEs below run (and is erased), a later one
  # waits for this transaction and is then refused (it sees `deletion_status`, D10).
  #
  # Lock order: the row locks come BEFORE the advisory lock, the order of the cross-signing writers
  # (story cross-signing-upload-races, D1): they decide on `CrossSigningKeyStore.lock_keys/1`, which takes the
  # cross_signing_keys row lock, then the `sync_global|` advisory lock, and only then reads (row -> advisory -> read);
  # the reset (`replace_with_approval/7`) locks the uia_sessions row before that (`Uia.consume`), the upload and the
  # signature merge start at the cross_signing_keys row. Taking the advisory lock first and then waiting for a
  # row such a writer holds would be a lock cycle. One window is NOT cycle-free (accepted residual, see the
  # CrossSigningKeyStore moduledoc): a signature merge whose row lock found NO row (absent) waits for the advisory lock
  # while a first upload commits the row (present); this transaction then locks that row and waits for the advisory
  # lock, and when the merge gets it first, its write waits for the row held here. PostgreSQL aborts one side
  # (40P01): this erasure fails closed (rolled back, audited, retried) or the merge answers 500. A first upload has the
  # same window when the row committed in between has a NULL master (a partial upload: its read sees no master and its
  # upsert takes the row lock only after the advisory lock; pre-existing, resolved the same way). Three actors of one
  # user within milliseconds; closing it would need the advisory lock first everywhere (rejected, story
  # cross-signing-upload-races D1). The writers take no `users` row lock (the D10 check is a plain
  # read, FK checks take FOR KEY SHARE, which the status UPDATE does not conflict with) and the initial-sync persist
  # takes the `users` row FOR SHARE as its FIRST statement with nothing else held, so nobody holds a lock this
  # transaction waits for while waiting for the `users` row it holds from step 2.

  defp lock_user_writers(target_user_id) do
    [
      "SELECT 1 FROM uia_sessions WHERE user_id = $1 FOR UPDATE",
      "SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE",
      "SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))"
    ]
    |> Enum.reduce_while(:ok, fn sql, :ok ->
      case repo().query(sql, [target_user_id]) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ─── Step 4b: GDPR erasure of every per-user table (D1, D2) ──────────────────
  #
  # room-account-data-and-read-markers: the user's room account data (m.marked_unread, m.fully_read, m.tag, ...) is
  # personal data. Story gdpr-erasure-global-data (follow-up `ck`): so are the global account data (secret storage,
  # push rules, m.direct), the cross-signing keys, the device keys and the other per-user tables of @erased_tables.
  # All are physically deleted in the same transaction. NOTE: admin DEACTIVATION deliberately keeps them (reversible).
  # The table names are compile-time constants, never user input; the user id is the only parameter.

  defp delete_per_user_rows(target_user_id) do
    Enum.each(@erased_steps, fn {table, step_name} ->
      step(step_name, run_delete(table, target_user_id))

      case verify_erased(table, target_user_id) do
        :ok -> :ok
        :rows_left -> step(:oauth_codes_not_erased, {:error, :rows_left})
        {:error, reason} -> step(:oauth_codes_check, {:error, reason})
      end
    end)
  end

  defp run_delete(table, target_user_id) do
    case repo().query("DELETE FROM #{table} WHERE user_id = $1", [target_user_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # D18 (e): `oauth_codes` is FORCE ROW LEVEL SECURITY. Without the delete policy of migration 000055 (a rolled-back or skipped
  # migration) the DELETE above does not fail, it silently deletes nothing for a code that has not been expired for 24 hours, and the
  # IdP refresh token ciphertext `idp_rt_enc` would survive an erasure that reports success. So the erasure counts what is left
  # (the SELECT policy is `true`) and fails closed: the transaction rolls back and the attempted audit names the step.
  defp verify_erased("oauth_codes", target_user_id) do
    case repo().query("SELECT count(*) FROM oauth_codes WHERE user_id = $1", [target_user_id]) do
      {:ok, %{rows: [[left]]}} when is_integer(left) and left > 0 -> :rows_left
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_erased(_table, _target_user_id), do: :ok

  # ─── Step 4c: profile anonymisation (D9) ─────────────────────────────────────
  #
  # The documented policy (Story 14.4 / 5.8): the profile row stays (FK from the user, `/profile` of an erased user) and
  # shows "Deleted User" without an avatar. A user without a profile row creates none.

  defp anonymise_profile(target_user_id) do
    sql = "UPDATE profiles SET displayname = 'Deleted User', avatar_url = NULL WHERE user_id = $1"

    case repo().query(sql, [target_user_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Step 5: Mark keys_deleted ───────────────────────────────────────────────
  #
  # Besides the status:
  #   * D16: the `users` PII columns are set to NULL. They are NOT crypto-shredded by the key deletion above: the display name and
  #     avatar ciphertexts (Tier 1, operational PII) are encrypted with the SERVER-WIDE `:signature, :pii_encryption_key`, only the
  #     email (Tier 2) is encrypted to the user's own (now deleted) key. The email columns are NULLed as defence in depth (the
  #     ciphertext is useless to everyone once the private key is gone, but nothing needs it either).
  #     `last_seen_at` (a behavioural timestamp) and `deactivation_reason` (admin free text that may describe the person) are NULLed
  #     too. `personal_room_id` stays: it is a pointer to a room whose events are retained.
  #   * D17: `is_active = false`, so the erasure is terminal for authentication (every auth gate also treats `deletion_status IS NOT NULL`
  #     as deactivated: an admin reactivation cannot revive an erased user).
  #   * `anonymized_at` is the timestamp of the profile anonymisation of step 4c (kept when an operator sweep set it before),
  #     `deactivated_at` keeps an earlier deactivation time.

  defp mark_keys_deleted(target_user_id, now_ms) do
    sql = """
    UPDATE users
    SET deletion_status        = 'keys_deleted',
        keys_deleted_at        = $1,
        anonymized_at          = COALESCE(anonymized_at, $1),
        is_active              = false,
        deactivated_at         = COALESCE(deactivated_at, $1),
        display_name_encrypted = NULL,
        display_name_nonce     = NULL,
        avatar_url_encrypted   = NULL,
        avatar_url_nonce       = NULL,
        email_encrypted        = NULL,
        email_nonce            = NULL,
        email_ephemeral_pub    = NULL,
        last_seen_at           = NULL,
        deactivation_reason    = NULL
    WHERE user_id = $2
    """

    case repo().query(sql, [now_ms, target_user_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ─── Transaction result ──────────────────────────────────────────────────────
  #
  # Ecto commits a transaction function that RETURNS {:error, _} and answers {:ok, {:error, _}}; only a raise or
  # rollback/1 rolls back. The loser of two concurrent erasures (mark_in_progress found 0 rows) must be a :conflict
  # with no success audit, so the wrapped error is unwrapped. (No rollback/1: the test fakes of the repo seam have none.)

  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction(result), do: result

  # A step of the transaction function: `:ok` continues, a failure leaves the function by a throw that carries the step name
  # (see delete_user_keys/3). mark_in_progress/1 is not a step: its `{:error, :conflict}` is a business answer, nothing was written.
  defp step(_name, :ok), do: :ok
  defp step(name, {:error, reason}), do: throw({:erasure_step_failed, name, reason})

  # The reason of a failed step reaches the audit row, the log and the error the dispatcher raises: reduce it to an atom or
  # the SQLSTATE of a database error. A Postgrex error carries the statement and, for a constraint, the row's key values.
  defp safe_reason(%{postgres: %{code: code}}) when is_atom(code), do: {:db_error, code}
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :unknown_error

  # ─── Failure Invariant: attempted-audit in own TX ────────────────────────────

  defp emit_attempted_audit(admin_user_id, target_user_id, reason, error_reason, failed_step) do
    # AuditWriter.log/7 runs in its own Repo.transaction/1 — never inside the failing TX.
    # never-raise: AuditWriter returns {:error, :audit_write_failed} on DB failure.
    # `error_detail` names the failing step of the erasure (a code atom, never data).
    _ =
      audit_writer().log(
        admin_user_id,
        "user_keys_deletion_attempted",
        "user",
        target_user_id,
        %{reason: reason, error: inspect(error_reason)},
        "attempted",
        failed_step && "step=#{failed_step}"
      )

    :ok
  end
end
