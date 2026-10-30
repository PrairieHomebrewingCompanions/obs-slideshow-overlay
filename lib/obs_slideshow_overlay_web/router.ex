defmodule ObsSlideshowOverlayWeb.Router do
  use ObsSlideshowOverlayWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ObsSlideshowOverlayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The player OBS loads: no page chrome and a transparent background.
  pipeline :player do
    plug :put_root_layout, html: {ObsSlideshowOverlayWeb.Layouts, :player}
  end

  scope "/", ObsSlideshowOverlayWeb do
    get "/media/:name", MediaController, :show
    get "/fonts.css", FontController, :css
    get "/fonts.json", FontController, :index
    get "/google-fonts.json", FontController, :google
    get "/fonts/:id", FontController, :show
  end

  scope "/", ObsSlideshowOverlayWeb do
    pipe_through [:browser, :player]

    live "/play/:key", PlayerLive
  end

  scope "/", ObsSlideshowOverlayWeb do
    pipe_through :browser

    live "/", GalleryLive, :index
    live "/s/:slug", GalleryLive, :show
    live "/themes", ThemeLive
    live "/themes/:id", ThemeLive
    live "/obs", ObsLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", ObsSlideshowOverlayWeb do
  #   pipe_through :api
  # end
end
