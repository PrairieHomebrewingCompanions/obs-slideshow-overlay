defmodule ObsSlideshowOverlay.Repo do
  use Ecto.Repo,
    otp_app: :obs_slideshow_overlay,
    adapter: Ecto.Adapters.SQLite3
end
