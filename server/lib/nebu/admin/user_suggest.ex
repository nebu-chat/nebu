defmodule Nebu.Admin.UserSuggest do
  @moduledoc """
  Story admin-add-user-autocomplete — shared add-user typeahead backend used by the
  room AND space add-member pages. Since admin-http-refactor those pages are plain
  HTTP controllers (`Nebu.Admin.RoomsController` / `SpacesController`); the suggestion
  data is served as JSON by `Nebu.Admin.UsersController.search/2`
  (GET /admin/users/search) and rendered client-side by the CSP-safe fetch widget in
  `priv/static/assets/app.js`.

  Single source of truth for the suggestion query so the Admin pages do not
  copy-paste the search/limit/min-length logic.

    * `min_chars/0`  — the minimum query length before any DB hit (>=2). Below this the
      result is always `[]` (AC1: "type at least N characters").
    * `limit/0`      — the LIMIT cap passed to the DB (enumeration / DoS guard, SEC Gate).
    * `search/1,2`   — returns a list of `%{user_id: ...}` maps for the (trimmed) query, or
      `[]` for a too-short / blank query. Routes through `Nebu.Admin.DB.search_users/2`
      (inline parameter-bound SQL, ADR-018) by default; a function-backed
      `:admin_user_searcher` app-env seam lets unit tests record calls without a live Repo.

  ADR-020: the query hits PostgreSQL only — no node-local state — so behaviour is
  identical single-node and clustered.
  """

  @min_chars 2
  @limit 10

  @spec min_chars() :: pos_integer()
  def min_chars, do: @min_chars

  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  Suggestions for the given raw query string. Returns `[]` for a blank query or one
  shorter than `min_chars/0` (no DB hit). Otherwise returns up to `limit/0`
  `%{user_id: ...}` maps.
  """
  @spec search(term(), pos_integer()) :: list(map())
  def search(query, max \\ @limit)

  def search(query, max) when is_binary(query) do
    trimmed = String.trim(query)

    if String.length(trimmed) < @min_chars do
      []
    else
      do_search(trimmed, max)
    end
  end

  def search(_query, _max), do: []

  defp do_search(trimmed, max) do
    case Application.get_env(:nebu_http, :admin_user_searcher) do
      fun when is_function(fun, 2) ->
        fun.(trimmed, max)

      fun when is_function(fun, 1) ->
        fun.(trimmed)

      _ ->
        if Process.whereis(Nebu.Repo) != nil do
          Nebu.Admin.DB.search_users(trimmed, max)
        else
          []
        end
    end
    |> Enum.map(&normalize/1)
  end

  defp normalize(%{user_id: uid}), do: %{user_id: uid}
  defp normalize(%{"user_id" => uid}), do: %{user_id: uid}
end
