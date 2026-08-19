defmodule CrfController.MixProject do
  use Mix.Project

  def project do
    [
      app: :crf_controller,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl],
      mod: {CrfController.Application, []}
    ]
  end
end
