defmodule Nebu.Matrix.CanonicalJson do
  @moduledoc """
  Canonical JSON encoding for Nebu event signing and hashing.

  Produces deterministic JSON output regardless of map insertion order:
  - All map keys are converted to strings and sorted alphabetically
  - Nested maps are recursively normalized
  - Uses `Jason.OrderedObject` to guarantee key order during encoding,
    because Erlang maps do not preserve insertion order for maps with >32 keys

  Architecture Rule #8: This module is the single canonical JSON implementation
  in the system. All code that needs deterministic JSON (event IDs, signatures)
  MUST use this module.
  """

  @doc """
  Encodes a map to canonical JSON with alphabetically sorted string keys.

  ## Examples

      iex> Nebu.Matrix.CanonicalJson.encode!(%{"b" => 2, "a" => 1})
      ~S({"a":1,"b":2})

      iex> Nebu.Matrix.CanonicalJson.encode!(%{b: 2, a: 1})
      ~S({"a":1,"b":2})

  """
  @spec encode!(map() | list() | term()) :: binary()
  def encode!(value) do
    value
    |> normalize()
    |> Jason.encode!()
  end

  @max_int 9_007_199_254_740_991

  @doc """
  The Matrix canonical JSON of a decoded JSON value for SIGNATURE checks (Matrix CS v1.18, appendix "Canonical JSON"): `encode!/1` after a check of the
  numbers: integers only in [-(2^53)+1, 2^53-1], no floats (a float, `1.0` and `1e3` included, or an integer beyond the range has no canonical form).
  `{:error, :not_canonical}` for such a value; never raises for one.
  """
  @spec encode_strict(term()) :: {:ok, binary()} | {:error, :not_canonical}
  def encode_strict(value) do
    if canonical_numbers?(value), do: {:ok, encode!(value)}, else: {:error, :not_canonical}
  end

  defp canonical_numbers?(map) when is_map(map), do: Enum.all?(map, fn {_k, v} -> canonical_numbers?(v) end)
  defp canonical_numbers?(list) when is_list(list), do: Enum.all?(list, &canonical_numbers?/1)
  defp canonical_numbers?(int) when is_integer(int), do: int >= -@max_int and int <= @max_int
  defp canonical_numbers?(float) when is_float(float), do: false
  defp canonical_numbers?(_other), do: true

  @doc """
  Lowercase hex SHA-256 of the canonical JSON encoding of `value` (story oauth-account-management, A14:
  the `m.oauth` approval is bound to the hash of ALL supplied cross-signing keys, whatever their key
  order). Pure.
  """
  @spec sha256_hex(term()) :: String.t()
  def sha256_hex(value), do: :crypto.hash(:sha256, encode!(value)) |> Base.encode16(case: :lower)

  # Recursively converts all map keys to strings and sorts them alphabetically.
  # Returns a Jason.OrderedObject to preserve sort order during JSON encoding.
  @spec normalize(term()) :: term()
  defp normalize(map) when is_map(map) do
    values =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), normalize(v)} end)
      |> Enum.sort_by(fn {k, _} -> k end)

    %Jason.OrderedObject{values: values}
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value
end
