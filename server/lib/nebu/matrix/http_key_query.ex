defmodule Nebu.Matrix.HttpKeyQuery do
  @moduledoc """
  HTTP side of `POST /_matrix/client/v3/keys/query` and `POST /_matrix/client/v3/keys/signatures/upload` (story key-query-hardening, epic e2ee-client-support,
  REQ-2026-014). The routes live in `Nebu.Web.Router.Protected` (authentication first, the rate tier `keys_signatures` in front of the upload); the stores are
  `Nebu.Matrix.KeyQueryStore` and `Nebu.Matrix.KeySignatureStore`. Request bodies are never logged (the `RequestLogger` captures no body of either route, see
  `Nebu.Web.Plugs.RawBodyReader.key_material_shape?/1`), and no key material or signature is part of an answer's error text.

  ## Query

  `200` always (users the caller may not see, unknown users, keyless users, remote and malformed ids are left out, `failures` is `{}`: the answers do not differ);
  `400 M_INVALID_PARAM` when more than #{1000} users are queried.

  ## Signatures upload

    * `400 M_NOT_JSON` malformed JSON; `400 M_BAD_JSON` a body that is not a JSON object; `400 M_INVALID_PARAM` more than #{200} signed objects (checked before any
      verification or database work);
    * `200 {"failures": {user: {key_id: {errcode, error}}}}`: per entry `M_FORBIDDEN` (not allowed to sign this key, also a foreign master key without a shared
      joined room: identical for an unknown user), `M_INVALID_SIGNATURE` (bad signature, unknown signing key, changed object), `M_INVALID_PARAM` (the entry is not an
      object, malformed `signatures`, no signature by the caller). Valid entries of the same request still apply.
  """
  import Nebu.Matrix.Http, only: [send_json: 3, error: 4]
  require Logger

  alias Nebu.Matrix.{KeyQueryStore, KeySignatureStore}

  @max_query_users 1000
  @max_signed_objects 200

  @doc "The pinned limits (the tests and the docs read these numbers)."
  def limits, do: %{max_query_users: @max_query_users, max_signed_objects: @max_signed_objects, signatures_per_min: 60, signatures_burst: 20}

  @spec query(Plug.Conn.t()) :: Plug.Conn.t()
  def query(conn) do
    caller = conn.assigns[:current_user]
    requested = body_params(conn)["device_keys"]
    requested = if is_map(requested), do: requested, else: %{}

    if map_size(requested) > @max_query_users do
      error(conn, 400, "M_INVALID_PARAM", "Too many users (at most #{@max_query_users})")
    else
      case KeyQueryStore.query(caller, requested) do
        {:ok, maps} ->
          send_json(conn, 200, %{
            "device_keys" => maps.device_keys,
            "master_keys" => maps.master_keys,
            "self_signing_keys" => maps.self_signing_keys,
            "user_signing_keys" => maps.user_signing_keys,
            "failures" => %{}
          })

        {:error, reason} ->
          Logger.error("keys/query: the read failed (#{error_kind(reason)})")
          error(conn, 500, "M_UNKNOWN", "Internal error")
      end
    end
  end

  @spec signatures_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def signatures_upload(conn) do
    caller = conn.assigns[:current_user]
    params = body_params(conn)

    with :ok <- check_json(conn, params),
         entries = entries(params),
         :ok <- check_cap(entries) do
      case KeySignatureStore.process(caller, entries) do
        {:ok, failures} -> send_json(conn, 200, %{"failures" => failure_map(failures)})
        {:error, :internal} -> error(conn, 500, "M_UNKNOWN", "Internal error")
      end
    else
      {:error, {status, errcode, message}} -> error(conn, status, errcode, message)
    end
  end

  defp check_json(conn, params) do
    cond do
      conn.assigns[:json_parse_error] == true -> {:error, {400, "M_NOT_JSON", "Request body is not valid JSON"}}
      # Plug.Parsers wraps a JSON value that is not an object as %{"_json" => value}
      map_size(params) == 1 and Map.has_key?(params, "_json") -> {:error, {400, "M_BAD_JSON", "Request body must be a JSON object"}}
      true -> :ok
    end
  end

  # `[{user_id, key_id, signed_object}]`; a user whose value is not an object names no key id and is ignored
  defp entries(params) do
    for {user_id, keyed} <- params, is_map(keyed), {key_id, obj} <- keyed, do: {user_id, key_id, obj}
  end

  defp check_cap(entries) do
    if length(entries) > @max_signed_objects, do: {:error, {400, "M_INVALID_PARAM", "Too many signed objects (at most #{@max_signed_objects})"}}, else: :ok
  end

  defp failure_map(failures) do
    Enum.reduce(failures, %{}, fn {user_id, key_id, reason}, acc ->
      Map.update(acc, user_id, %{key_id => failure(reason)}, &Map.put(&1, key_id, failure(reason)))
    end)
  end

  # fixed texts: nothing of the request (key id, object, signature) is echoed
  defp failure(:invalid_param), do: %{"errcode" => "M_INVALID_PARAM", "error" => "Malformed signed object"}
  defp failure(:forbidden), do: %{"errcode" => "M_FORBIDDEN", "error" => "Not allowed to sign this key"}
  defp failure(:invalid_signature), do: %{"errcode" => "M_INVALID_SIGNATURE", "error" => "Signature is invalid or does not match the stored key"}

  defp body_params(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> %{}
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp error_kind(%{__struct__: module}), do: inspect(module)
  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(_), do: "error"
end
