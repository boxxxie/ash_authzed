defmodule AshAuthzed.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/boxxxie/ash_authzed"

  def project do
    [
      app: :ash_authzed,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix]],
      description:
        "Zanzibar-style Relationship-Based Access Control (ReBAC) extension for Ash Framework with SpiceDB and Licet adapters."
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        "ash_authzed.bench": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.2"},
      {:licet, "~> 0.1.0"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.2"},
      {:req, "~> 0.5", optional: true},
      {:igniter, "~> 0.6", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:plug, "~> 1.16", only: :test}
    ]
  end

  defp aliases do
    [
      "spark.formatter": "spark.formatter --extensions AshAuthzed",
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshAuthzed",
      docs: [
        "spark.cheat_sheets",
        "docs"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      files: ~w(
        lib
        documentation
        usage-rules.md
        .formatter.exs
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        "documentation/tutorials/getting-started-with-ash-authzed.md": [
          title: "Getting Started"
        ],
        "documentation/dsls/DSL-AshAuthzed.md": [
          title: "DSL: AshAuthzed"
        ],
        "usage-rules.md": [title: "LLM & Agent Usage Rules"]
      ],
      groups_for_extras: [
        Tutorials: ~r"documentation/tutorials/",
        "DSL Reference": ~r"documentation/dsls/",
        Reference: ["usage-rules.md", "CHANGELOG.md"]
      ],
      groups_for_modules: [
        Extension: [
          AshAuthzed,
          AshRebac,
          AshAuthzed.PolicyMacros,
          AshAuthzed.Checks.Can,
          AshAuthzed.Checks.CanAssign,
          AshAuthzed.SyncChange,
          AshAuthzed.Relation,
          AshAuthzed.ExternalRole,
          AshAuthzed.ConditionalWildcard
        ],
        Adapters: [
          AshAuthzed.Adapter,
          AshAuthzed.Adapters.Licet,
          AshAuthzed.Adapters.SpiceDBHttp,
          AshAuthzed.Adapters.Memory
        ],
        "Transformers & Verifiers": [
          AshAuthzed.Transformer,
          AshAuthzed.Verifiers.VerifyZedSchema
        ],
        Errors: [
          AshAuthzed.Error
        ]
      ]
    ]
  end
end
