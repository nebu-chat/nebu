defmodule Nebu.Admin.RoleMappingHTML do
  @moduledoc "Template module for RoleMappingController."
  use Phoenix.Component
  import Nebu.Admin.ReauthComponents

  embed_templates "templates/role_mapping/*"
end
