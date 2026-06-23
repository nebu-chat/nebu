defmodule Nebu.Repo do
  use Ecto.Repo,
    otp_app: :nebu,
    adapter: Ecto.Adapters.Postgres
end
