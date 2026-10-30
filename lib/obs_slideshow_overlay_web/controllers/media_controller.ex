defmodule ObsSlideshowOverlayWeb.MediaController do
  use ObsSlideshowOverlayWeb, :controller

  alias ObsSlideshowOverlay.Media

  # Stored images have generated names (see ObsSlideshowOverlay.Media.store/2); anything
  # else, including paths, isn't one of ours.
  def show(conn, %{"name" => name}) do
    path = Media.path(name)

    if name =~ ~r/\A[A-Za-z0-9_-]+\.(png|jpg)\z/ and File.regular?(path) do
      conn
      # A stored image never changes; a new upload gets a new name.
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_content_type(MIME.from_path(path))
      |> send_file(200, path)
    else
      send_resp(conn, 404, "Not found")
    end
  end
end
