defmodule Otera.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/georgeguimaraes/otera"

  def project do
    [
      app: :otera,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Jinja templates in pure Elixir, with the Python compatibility of Hugging Face chat templates.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
