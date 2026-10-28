defmodule Nebu.Matrix.Session.TokenValidator.Postgres do
  @moduledoc "PostgreSQL implementation of Nebu.Matrix.Session.TokenValidator."

  @behaviour Nebu.Matrix.Session.TokenValidator

  # story gdpr-erasure-global-data (D17): a user whose erasure is under way or done (`deletion_status IS NOT NULL`) is never
  # active, whatever `is_active` says: an admin reactivation cannot revive an erased user.
  @lookup_sql """
  SELECT user_id, system_role, display_name_encrypted, display_name_nonce,
         (is_active AND deletion_status IS NULL), signing_key_id
  FROM users
  WHERE user_id = $1
  """

  @impl Nebu.Matrix.Session.TokenValidator
  def validate(user_id, system_role, display_name, email) do
    case lookup_user(user_id) do
      {:ok, nil} ->
        # Brand-new user — provision and mark as new (is_new: true).
        # Story admin-auto-join-rooms: is_new drives ensure_auto_join_memberships/1.
        case provision_new_user(user_id, system_role, display_name, email) do
          {:ok, user_data} -> {:ok, Map.put(user_data, :is_new, true)}
          error -> error
        end

      {:ok, %{is_active: false}} ->
        {:error, :deactivated}

      {:ok, %{signing_key_id: nil}} ->
        case provision_existing_user(user_id, display_name, email) do
          {:ok, :provisioned} ->
            case read_and_decrypt(user_id) do
              {:ok, user_data} -> {:ok, Map.put(user_data, :is_new, false)}
              error -> error
            end
          {:error, reason} -> {:error, reason}
        end

      {:ok, user} ->
        case decrypt_and_return(user) do
          {:ok, user_data} -> {:ok, Map.put(user_data, :is_new, false)}
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_user(user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @lookup_sql, [user_id]) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok, %{rows: [[uid, role, dn_enc, dn_nonce, active, sign_key_id]]}} ->
        {:ok, %{
          user_id: uid,
          system_role: role,
          display_name_encrypted: dn_enc,
          display_name_nonce: dn_nonce,
          is_active: active,
          signing_key_id: sign_key_id
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provision_new_user(user_id, system_role, display_name, email) do
    server_key = Application.get_env(:signature, :pii_encryption_key)

    with {:ok, {^user_id, resolved_role}} <-
           Nebu.Matrix.Session.BootstrapChecker.upsert_with_bootstrap(user_id, system_role),
         {:ok, :provisioned} <-
           Nebu.Matrix.Session.UserProvisioner.provision_user(user_id, display_name, email, server_key) do
      # Story admin-auto-join-rooms: is_new: true signals validate_token to trigger ensure_auto_join_memberships.
      {:ok, %{
        user_id: user_id,
        system_role: resolved_role,
        display_name: display_name,
        is_active: true,
        is_new: true
      }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp provision_existing_user(user_id, display_name, email) do
    server_key = Application.get_env(:signature, :pii_encryption_key)
    Nebu.Matrix.Session.UserProvisioner.provision_user(user_id, display_name, email, server_key)
  end

  defp read_and_decrypt(user_id) do
    case lookup_user(user_id) do
      {:ok, nil} -> {:error, :user_not_found}
      {:ok, %{is_active: false}} -> {:error, :deactivated}
      {:ok, user} -> decrypt_and_return(user)
      {:error, reason} -> {:error, reason}
    end
  end

  # story gdpr-erasure-global-data (D16): the display name columns are NULL for an erased user (such a user is never active, so this
  # is not reached for one) and for a user whose provisioning left them empty: no decryption of NULL.
  defp decrypt_and_return(%{
         user_id: user_id,
         system_role: system_role,
         display_name_encrypted: nil,
         is_active: true
       }) do
    {:ok, %{user_id: user_id, system_role: system_role, display_name: "", is_active: true, is_new: false}}
  end

  defp decrypt_and_return(%{
         user_id: user_id,
         system_role: system_role,
         display_name_encrypted: dn_enc,
         display_name_nonce: dn_nonce,
         is_active: true
       }) do
    server_key = Application.get_env(:signature, :pii_encryption_key)

    case Nebu.Matrix.Signature.decrypt_operational_pii(dn_enc, dn_nonce, server_key) do
      {:ok, display_name} ->
        # Story admin-auto-join-rooms: is_new: false — existing user, no auto-join needed.
        {:ok, %{
          user_id: user_id,
          system_role: system_role,
          display_name: display_name,
          is_active: true,
          is_new: false
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
