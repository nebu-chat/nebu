defmodule Nebu.Admin do
  @moduledoc """
  Public API for the Admin domain (ADR-020).

  The only entry point other domains may use to reach Admin functionality. Internal
  Admin modules (`Nebu.Admin.Endpoint`, `Nebu.Admin.Auth`, `Nebu.Admin.*Live`,
  `Nebu.Admin.Router`, `Nebu.Admin.DB`, …) are private to the domain.

  The Admin domain owns: the Phoenix LiveView Admin UI, the admin OIDC
  Authorization-Code + PKCE login flow, and the admin-facing read/write DB queries.
  It calls into other domains only through their public APIs (`Nebu.Matrix`,
  `Nebu.Media`).

  Kassandra flags any cross-domain call into `Nebu.Admin.*` (other than this module)
  as a finding.
  """
end
