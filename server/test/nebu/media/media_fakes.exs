defmodule Nebu.Web.MediaFakes do
  @moduledoc """
  Function-backed fake boundaries for the media-gateway-migration RED tests.

  Mox is NOT a dependency of this umbrella (checked mix.lock), so rather than a
  generated mock we use thin modules whose behavior is supplied per-test through
  application env closures. Each fake reads a 0-/n-arity function from
  `Application.get_env(:nebu_http, <key>)` and calls it. Tests set the closure in
  their own `setup`/`on_exit`.

  The dev agent's production code reads the SAME app-env keys
  (`:media_storage_module`, `:media_membership_module`, `:media_db_module`,
  `:media_http_fetch_module`) and falls back to the real ExAws/OTP/SQL/Finch
  implementations when the key is unset. In tests we point the key at one of
  these fakes.
  """

  defmodule Storage do
    @moduledoc "Fake storage boundary (production: ExAws.S3 Storer)."
    def get(key) do
      fun = Application.get_env(:nebu_http, :media_storage_get_fun)
      if fun, do: fun.(key), else: {:error, :not_found}
    end

    def put(key, bytes) do
      fun = Application.get_env(:nebu_http, :media_storage_put_fun)
      if fun, do: fun.(key, bytes), else: :ok
    end
  end

  defmodule Membership do
    @moduledoc "Fake membership boundary (production: local OTP call, AC2/AC4)."
    def member?(room_id, user_id) do
      fun = Application.get_env(:nebu_http, :media_member_fun)
      if fun, do: fun.(room_id, user_id), else: false
    end
  end

  defmodule DB do
    @moduledoc "Fake media_files lookup (production: inline SQL, ADR-018)."
    def lookup(server_name, media_id) do
      fun = Application.get_env(:nebu_http, :media_lookup_fun)
      if fun, do: fun.(server_name, media_id), else: {:error, :not_found}
    end
  end

  defmodule HttpFetch do
    @moduledoc "Fake HTTP fetch for preview_url (production: Finch). SSRF guard runs in the handler BEFORE this is ever reached."
    def fetch(url) do
      fun = Application.get_env(:nebu_http, :media_fetch_fun)

      if fun do
        fun.(url)
      else
        {:error, :no_fetch_fun}
      end
    end
  end
end
