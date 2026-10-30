defmodule ObsSlideshowOverlay.NotObsPlug do
  @moduledoc "A web server that isn't OBS: it answers every request with a page."
  def init(opts), do: opts
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "<p>Hello</p>")
end
