defmodule Nebu.DeployConfigTest do
  @moduledoc """
  Static analysis tests for the Stackit cloud-init deployment template.

  These tests read `deploy/tofu/examples/stackit/cloud-init.tftpl` and assert
  the expected structure WITHOUT running OpenTofu or connecting to any
  infrastructure. They are RED until the `postgres-ssl-env-var` story is
  implemented.

  Acceptance Criteria covered:
  - AC3: NEBU_POSTGRES_SSL: "true" is present in the server service environment block
  - AC3: DB URLs in the environment block contain no SSL query parameters
  - AC4: NEBU_DB_URL and NEBU_DB_URL_MIGRATE are NOT in the .env content block
  - AC4: Both vars appear directly in the environment block as inline values

  The assertions use plain string matching against the template source —
  no YAML/HCL parsing is needed because the template is rendered by OpenTofu,
  not Elixir.
  """

  use ExUnit.Case, async: true

  # Resolve the template path relative to this test file.
  #
  # __DIR__ is always the directory of this source file:
  #   - Locally:    <repo>/server/test/nebu
  #   - In Docker:  /workspace/server/test/nebu  (repo mounted at /workspace)
  #
  # The cloud-init template lives at <repo>/deploy/tofu/examples/stackit/.
  # From <repo>/server/test/nebu, that is three "../" steps up to <repo>,
  # then into deploy/:
  #   nebu/ → test/ → server/ → <repo>/  →  deploy/tofu/examples/stackit/...
  @template_path Path.expand(
                   "../../../deploy/tofu/examples/stackit/cloud-init.tftpl",
                   __DIR__
                 )

  setup_all do
    unless File.exists?(@template_path) do
      flunk("cloud-init.tftpl not found at #{@template_path}. " <>
              "Is the deploy/tofu/examples/stackit/ directory present?")
    end

    {:ok, content: File.read!(@template_path)}
  end

  # ── AC3: NEBU_POSTGRES_SSL in environment block ───────────────────────────────

  describe "AC3 — NEBU_POSTGRES_SSL: \"true\" in server service environment block" do
    test "template contains NEBU_POSTGRES_SSL: \"true\"", %{content: content} do
      # This assertion is RED because the env var does not yet exist in the template.
      assert String.contains?(content, ~s(NEBU_POSTGRES_SSL: "true")),
             "Expected NEBU_POSTGRES_SSL: \"true\" in cloud-init.tftpl environment block, " <>
               "but it was not found. The postgres-ssl-env-var story must add this line."
    end
  end

  # ── AC4: DB URLs removed from the .env content block ─────────────────────────

  describe "AC4 — NEBU_DB_URL and NEBU_DB_URL_MIGRATE not in the .env content block" do
    test "NEBU_DB_URL= is not in the .env file content block", %{content: content} do
      # The .env block in cloud-init is a `content: |` block that writes
      # /opt/nebu/.env. It starts after `content: |` and contains lines like
      # `KEY=value`. After AC4 is implemented, NEBU_DB_URL= must no longer
      # appear there.
      #
      # This test is RED because the current template has:
      #   NEBU_DB_URL=postgresql://...?sslmode=require
      # in the .env content block.
      refute content =~ ~r/NEBU_DB_URL=postgresql/,
             "NEBU_DB_URL= still found in the .env content block of cloud-init.tftpl. " <>
               "Move it to the environment: block of the server service as an inline value."
    end

    test "NEBU_DB_URL_MIGRATE= is not in the .env file content block", %{content: content} do
      # This test is RED because the current template has:
      #   NEBU_DB_URL_MIGRATE=postgresql://...?sslmode=require
      # in the .env content block.
      refute content =~ ~r/NEBU_DB_URL_MIGRATE=postgresql/,
             "NEBU_DB_URL_MIGRATE= still found in the .env content block of cloud-init.tftpl. " <>
               "Move it to the environment: block of the server service as an inline value."
    end
  end

  # ── AC4: Both vars present as inline values in environment block ──────────────

  describe "AC4 — Both DB URLs directly in environment block as inline values" do
    test "NEBU_DB_URL appears as inline value (key: value) in environment block", %{
      content: content
    } do
      # After the fix, the environment block must have the URL inline, e.g.:
      #   NEBU_DB_URL: "postgresql://${pg_user}:${pg_password}@${pg_host}:${pg_port}/nebu"
      # (without SSL query params).
      #
      # The current template has `NEBU_DB_URL: "postgresql://...?ssl=true"` —
      # which still fails the SSL-params test above. After both ACs are applied,
      # this line should exist without the ?ssl param.
      assert content =~ ~r/NEBU_DB_URL:\s+"postgresql:/,
             "NEBU_DB_URL is not present as an inline value in the environment: block. " <>
               "Expected a line like: NEBU_DB_URL: \"postgresql://...\""
    end

    test "NEBU_DB_URL_MIGRATE appears as inline value (key: value) in environment block", %{
      content: content
    } do
      # After the fix, the NEBU_DB_URL_MIGRATE should also be inlined (not referenced
      # from .env via $${NEBU_DB_URL_MIGRATE}), e.g.:
      #   NEBU_DB_URL_MIGRATE: "postgresql://${pg_migrate_user}:..."
      #
      # Currently: `NEBU_DB_URL_MIGRATE: $${NEBU_DB_URL_MIGRATE}` (reads from .env)
      # This test is RED because the current value is a shell variable reference, not
      # a direct inline URL.
      assert content =~ ~r/NEBU_DB_URL_MIGRATE:\s+"postgresql:/,
             "NEBU_DB_URL_MIGRATE is not present as an inline postgresql:// value " <>
               "in the environment: block. Expected a line like: " <>
               "NEBU_DB_URL_MIGRATE: \"postgresql://...\""
    end
  end

  # ── Regression: /admin/ nginx locations must forward WebSocket upgrade headers ─
  #
  # Phoenix LiveView connects via WebSocket to /admin/live. Without the Upgrade +
  # Connection proxy headers on the /admin/ location block, nginx silently drops the
  # WebSocket upgrade handshake and the LiveSocket never connects — so phx-submit
  # events (Next button, form submits) are never delivered to the server.
  #
  # Both TLS modes (tls_mode = "alb" and tls_mode = "acme") have an explicit
  # `location /admin/` block when element_web is enabled. Both must carry the two
  # WebSocket headers. The `location /` catch-all blocks already have them; the
  # dedicated /admin/ block was the omission.

  defp extract_admin_blocks(content) do
    Regex.scan(~r/location \/admin\/ \{[^}]+\}/, content)
    |> Enum.map(fn [match] -> match end)
  end

  describe "nginx /admin/ locations must forward WebSocket upgrade headers" do
    test "ALB nginx config /admin/ location has Upgrade WebSocket header", %{
      content: content
    } do
      blocks = extract_admin_blocks(content)

      assert length(blocks) >= 1,
             "Expected at least one `location /admin/ { ... }` block in cloud-init.tftpl " <>
               "but found none. Check the nginx proxy config sections."

      Enum.each(blocks, fn block ->
        assert String.contains?(block, "proxy_set_header   Upgrade"),
               "location /admin/ block is missing `proxy_set_header Upgrade $http_upgrade`.\n" <>
                 "Phoenix LiveView WebSocket connections to /admin/live will be rejected " <>
                 "by nginx, causing all phx-submit events to silently fail.\n" <>
                 "Affected block:\n#{block}"
      end)
    end

    test "ALB nginx config /admin/ location has Connection WebSocket header", %{
      content: content
    } do
      blocks = extract_admin_blocks(content)

      Enum.each(blocks, fn block ->
        assert String.contains?(block, "proxy_set_header   Connection"),
               "location /admin/ block is missing `proxy_set_header Connection $connection_upgrade`.\n" <>
                 "Affected block:\n#{block}"
      end)
    end
  end

  # ── Regression: app.js must not use the fake longPollFallbackMs option ─────────
  #
  # `longPollFallbackMs` does not exist in Phoenix LiveView 1.0 — the LiveSocket
  # constructor silently ignores it. Using it as the sole workaround gives the
  # impression that WS fallback is configured when it is not. The correct fix is
  # to add Upgrade/Connection headers to the nginx /admin/ location.

  describe "app.js LiveSocket configuration" do
    test "does not use the non-existent longPollFallbackMs option" do
      app_js_path = Path.expand("../../priv/static/assets/app.js", __DIR__)
      js = File.read!(app_js_path)

      refute String.contains?(js, "longPollFallbackMs"),
             "app.js contains `longPollFallbackMs` which is not a valid Phoenix LiveView " <>
               "LiveSocket option and is silently ignored. Remove it — the correct fix is " <>
               "adding Upgrade+Connection headers to the nginx /admin/ location block."
    end
  end
end
