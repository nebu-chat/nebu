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

  # ── AC3: No SSL query params in DB URLs inside environment block ───────────────

  describe "AC3 — DB URLs in environment block must not contain SSL query parameters" do
    test "NEBU_DB_URL in environment block does not contain ?ssl= or ?sslmode=", %{
      content: content
    } do
      # Extract only the environment: block of the server service by finding all
      # occurrences of NEBU_DB_URL lines. Any occurrence with ?ssl= or ?sslmode=
      # indicates SSL is still baked into the URL instead of controlled via the env var.
      #
      # This test is RED because the current template still has:
      #   NEBU_DB_URL: "postgresql://...?ssl=true"
      refute content =~ ~r/NEBU_DB_URL:.*\?ssl=/,
             "NEBU_DB_URL in environment block still contains ?ssl= parameter. " <>
               "Remove SSL query params — use NEBU_POSTGRES_SSL instead."

      refute content =~ ~r/NEBU_DB_URL:.*\?sslmode=/,
             "NEBU_DB_URL in environment block still contains ?sslmode= parameter. " <>
               "Remove SSL query params — use NEBU_POSTGRES_SSL instead."
    end

    test "NEBU_DB_URL_MIGRATE in environment block does not contain SSL query parameters", %{
      content: content
    } do
      refute content =~ ~r/NEBU_DB_URL_MIGRATE:.*\?ssl=/,
             "NEBU_DB_URL_MIGRATE in environment block still contains ?ssl= parameter. " <>
               "Remove SSL query params — use NEBU_POSTGRES_SSL instead."

      refute content =~ ~r/NEBU_DB_URL_MIGRATE:.*\?sslmode=/,
             "NEBU_DB_URL_MIGRATE in environment block still contains ?sslmode= parameter. " <>
               "Remove SSL query params — use NEBU_POSTGRES_SSL instead."
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

  # ── AC3 + AC4 combined: .env block has no SSL params in any DB URL line ───────

  describe "AC3+AC4 combined — no SSL query params anywhere in any DB URL (env or .env)" do
    test "no ?sslmode= anywhere in the template DB URL values", %{content: content} do
      # The .env block currently has sslmode=require in both URLs.
      # After the fix, ?sslmode= must not appear anywhere in the template.
      refute String.contains?(content, "sslmode=require"),
             "Found sslmode=require in cloud-init.tftpl. " <>
               "All SSL configuration must go through NEBU_POSTGRES_SSL."

      refute String.contains?(content, "sslmode=verify-full"),
             "Found sslmode=verify-full in cloud-init.tftpl. " <>
               "All SSL configuration must go through NEBU_POSTGRES_SSL."
    end
  end
end
