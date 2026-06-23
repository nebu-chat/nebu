defmodule Nebu.Admin.ErrorHTML do
  @moduledoc """
  Error view for the Admin endpoint (bugfix/fix-matrix-sso-redirect-missing).

  `Nebu.Admin.Endpoint` previously configured `render_errors: [formats: []]`. An
  EMPTY formats list made `Phoenix.Endpoint.RenderErrors.put_formats/2` crash with
  `(MatchError) no match of right hand side value: []` whenever ANY exception was
  raised inside the admin endpoint — including a legitimately rejected CSRF form
  POST. That secondary crash (a 500 with an empty body, no clean error page) masked
  the primary exception in the logs.

  This view supplies a real, dependency-free error renderer so the endpoint can
  always negotiate a format and produce a clean status-code response. Phoenix calls
  `render/2` with a template name like `"404.html"` / `"403.html"`; we strip the
  extension and return the human-readable status phrase as the body.
  """
  use Phoenix.Component

  @doc """
  Renders an error body for a `"<status>.<format>"` template (e.g. `"403.html"`).

  Returns the canonical reason phrase for the status code (e.g. "Forbidden"), which
  Phoenix sends as the response body with the matching HTTP status.
  """
  def render(template, _assigns) do
    template
    |> String.split(".")
    |> hd()
    |> Plug.Conn.Status.reason_phrase()
  rescue
    # Unknown / non-numeric status component → generic message (never crash the
    # error handler again).
    _ -> "Something went wrong"
  end
end
