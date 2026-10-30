defmodule Habibi.MixProject do
  use Mix.Project

  def project do
    [
      app: :habibi,
      version: System.get_env("HABIBI_VERSION", "0.1.0-dev"),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [
        "ecto.setup": ["ecto.create", "ecto.migrate"],
        "assets.deploy": ["cmd --cd .. npm run build"]
      ]
    ]
  end

  def application do
    [mod: {Habibi.Application, []}, extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.3"},
      {:gettext, "~> 1.0"},
      {:boruta, "~> 2.3.8"},
      {:wax_, "~> 0.7.0"},
      {:bandit, "~> 1.8"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.21"},
      {:dns_cluster, "~> 0.2"},
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"},
      {:ex_aws, "~> 2.6"},
      {:ex_aws_s3, "~> 2.5"},
      {:req, "~> 0.7.5"},
      {:sweet_xml, "~> 0.7"}
    ]
  end
end
