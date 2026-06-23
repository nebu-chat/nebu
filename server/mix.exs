defmodule Nebu.MixProject do
  use Mix.Project

  # ADR-019: single OTP application — no umbrella. One mix.exs, one Nebu.Application,
  # one supervisor tree. Domains are module namespaces under lib/nebu/.
  def project do
    [
      app: :nebu,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Shared test-support modules loaded via Code.require_file in test_helper.exs
      # (not ExUnit "*_test.exs" files) — keep the 1.20+ test runner from warning.
      test_ignore_filters: [
        &String.ends_with?(&1, "media_test_support.exs"),
        &String.ends_with?(&1, "media_fakes.exs")
      ],
      deps: deps(),
      releases: [
        nebu: [
          include_executables_for: [:unix]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets],
      mod: {Nebu.Application, []}
    ]
  end

  defp elixirc_paths(_), do: ["lib"]

  # Union of all former umbrella apps' deps (deduplicated). No internal in_umbrella deps.
  defp deps do
    [
      # ── Database (nebu_db) ──
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      # ── Clustering (room_manager / event_dispatcher) ──
      {:horde, "~> 0.9"},
      {:libcluster, "~> 3.3"},
      # grpc-removal (ADR-021): the gRPC stack was removed. The former Core.* protobuf
      # DTOs are now hand-maintained plain Elixir structs in lib/pb/core.pb.ex; no
      # :grpc / :protobuf dependency remains.
      {:jason, "~> 1.4"},
      # ── HTTP / Web (nebu_http) ──
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.18"},
      {:cors_plug, "~> 3.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_html, "~> 4.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # ── OIDC / crypto (nebu_http) ──
      {:assent, "~> 0.3"},
      {:jose, "~> 1.11"},
      # ── Media / object storage (nebu_http) ──
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:hackney, "~> 1.20"},
      {:finch, "~> 0.18"},
      {:floki, "~> 0.36"}
    ]
  end
end
