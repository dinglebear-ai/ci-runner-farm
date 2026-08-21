defmodule CrfController.MixProject do
  use Mix.Project

  def project do
    [
      app: :crf_controller,
      version: repo_version(),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      releases: [
        crf_controller: [include_executables_for: [:unix]]
      ],
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl],
      mod: {CrfController.Application, []}
    ]
  end

  defp repo_version do
    "../VERSION"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> String.trim()
  end
end
