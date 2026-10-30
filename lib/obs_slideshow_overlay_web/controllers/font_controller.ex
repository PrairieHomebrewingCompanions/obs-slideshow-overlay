defmodule ObsSlideshowOverlayWeb.FontController do
  @moduledoc """
  Serves the fonts installed on this computer (ObsSlideshowOverlay.Fonts) to pages: a
  stylesheet declaring each one, the files themselves, and the list of
  families for the Themes page's font menu. Browsers only download a font
  when something on the page uses it.
  """
  use ObsSlideshowOverlayWeb, :controller

  alias ObsSlideshowOverlay.Fonts

  def css(conn, _params) do
    css = Enum.map_join(Fonts.servable(), "\n", &font_face/1)

    conn
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_content_type("text/css")
    |> send_resp(200, css)
  end

  def show(conn, %{"id" => id}) do
    case Fonts.get(id) do
      nil ->
        send_resp(conn, 404, "Not found")

      face ->
        conn
        |> put_resp_header("cache-control", "public, max-age=86400")
        |> put_resp_content_type(content_type(face.path), nil)
        |> send_file(200, face.path)
    end
  end

  def index(conn, _params), do: json(conn, Fonts.families())

  # Google's families not downloaded yet, for the font menu.
  def google(conn, _params) do
    case ObsSlideshowOverlay.GoogleFonts.catalogue() do
      {:ok, fonts} ->
        installed = MapSet.new(Fonts.families())
        json(conn, for(%{family: f} <- fonts, f not in installed, do: f))

      {:error, reason} ->
        conn |> put_status(503) |> json(%{error: reason})
    end
  end

  defp font_face(face) do
    format = if content_type(face.path) == "font/otf", do: "opentype", else: "truetype"

    """
    @font-face {
      font-family: "#{escape(face.family)}";
      src: url("/fonts/#{face.id}") format("#{format}");
      font-weight: #{face.weight};
      font-style: #{if face.italic, do: "italic", else: "normal"};
    }\
    """
  end

  defp content_type(path) do
    if String.downcase(Path.extname(path)) == ".otf", do: "font/otf", else: "font/ttf"
  end

  defp escape(name), do: String.replace(name, ~r/["\\\n]/, "")
end
