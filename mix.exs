defmodule ExTerm.MixProject do
  use Mix.Project

  @development [:dev, :test]

  def project do
    [
      app: :ex_term,
      version: "0.1.0",
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(Mix.env()),
      deps: deps(),
      description: "liveview terminal module",
      package: package(),
      source_url: "https://github.com/E-xyza/ex_term",
      docs: [
        main: "ExTerm",
        extras: ["README.md"],
        filter_modules: fn module, _ -> module == ExTerm end
      ]
    ]
  end

  def application do
    application =
      if Mix.env() in @development, do: ExTerm.DevApplication, else: ExTerm.Application

    [
      mod: {application, []},
      extra_applications: [:logger, :runtime_tools, :iex]
    ]
  end

  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(:test), do: ["lib", "dev", "test/_support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    in_dev = Mix.env() in @development

    [
      {:phoenix, "~> 1.6.15"},
      {:phoenix_html, "~> 3.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 0.18.3"},
      {:match_spec, "~> 0.3.1"},
      {:floki, ">= 0.30.0", only: :test},
      {:mox, "~> 1.0", only: :test},
      {:esbuild, "~> 0.4", runtime: Mix.env() == :dev},
      {:jason, "~> 1.2"},
      {:plug_cowboy, "~> 2.5", optional: !in_dev},
      {:mix_test_watch, "~> 1.1", only: :dev, runtime: false},
      {:ex_doc, "> 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp aliases(env) do
    List.wrap(
      if env in @development do
        [
          setup: ["deps.get"],
          "assets.deploy": ["esbuild default --minify", "phx.digest"]
        ]
      end
    )
  end

  defp package do
    [
      # These are the default files included in the package
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/E-xyza/ex_term"}
    ]
  end
end
