defmodule Nebu.Admin.MediaSettingsHTML do
  @moduledoc """
  Template module for `Nebu.Admin.MediaSettingsController`
  (media-security-admin-control/9b-media-settings-ui). Mirrors
  `Nebu.Admin.ConfigHTML`'s exact pattern (`embed_templates
  "templates/<dir>/*"` + a single `templates/media_settings/index.html.heex`).
  """
  use Phoenix.Component
  import Nebu.Admin.ReauthComponents

  embed_templates "templates/media_settings/*"
end
