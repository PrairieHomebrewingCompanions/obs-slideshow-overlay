defmodule ObsSlideshowOverlay.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # SQLite creates the database file, but not its folder.
    File.mkdir_p!(ObsSlideshowOverlay.Media.dir())

    children = [
      ObsSlideshowOverlayWeb.Telemetry,
      ObsSlideshowOverlay.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:obs_slideshow_overlay, :ecto_repos),
       skip: skip_migrations?()},
      {DNSCluster,
       query: Application.get_env(:obs_slideshow_overlay, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ObsSlideshowOverlay.PubSub},
      ObsSlideshowOverlay.Fonts,
      # Start to serve requests, typically the last entry
      ObsSlideshowOverlayWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ObsSlideshowOverlay.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ObsSlideshowOverlayWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Migrating on start means `mix phx.server` is all it takes, even the
  # first time. Tests migrate through the test alias instead.
  defp skip_migrations?() do
    not Application.get_env(:obs_slideshow_overlay, :migrate_on_start, true)
  end
end
