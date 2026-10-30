defmodule ObsSlideshowOverlay.GoogleFontsTest do
  use ObsSlideshowOverlayWeb.ConnCase, async: false

  import ObsSlideshowOverlay.Fixtures

  alias ObsSlideshowOverlay.{Fonts, GoogleFonts}

  setup do
    File.rm_rf!(GoogleFonts.dir())
    File.rm(Path.join(ObsSlideshowOverlay.Media.dir(), "google-fonts.json"))
    Phoenix.PubSub.subscribe(ObsSlideshowOverlay.PubSub, "fonts")
    on_exit(fn -> File.rm_rf!(GoogleFonts.dir()) end)
    :ok
  end

  # Google: its catalogue, the stylesheet for a family, and the files it
  # names (TrueType, as it sends to apps).
  defp stub_google(test) do
    dir = Path.join(System.tmp_dir!(), "google-#{System.unique_integer([:positive])}")
    regular = File.read!(font(dir, "r.ttf", "Grenze"))
    bold = File.read!(font(dir, "b.ttf", "Grenze", 700))

    Req.Test.stub(GoogleFonts, fn conn ->
      send(test, {:google, conn.request_path, conn.query_string})

      case conn.request_path do
        "/metadata/fonts" ->
          Req.Test.text(
            conn,
            ~s|)]}'{"familyMetadataList": [| <>
              ~s|{"family": "Grenze", "category": "Serif", "fonts": {"700": {}, "400": {}}},| <>
              ~s|{"family": "Buda", "category": "Display", "fonts": {"300": {}}}]}|
          )

        "/css2" ->
          Req.Test.text(conn, """
          @font-face {
            font-family: 'Grenze';
            font-style: normal;
            font-weight: 400;
            src: url(https://fonts.gstatic.com/s/grenze/r.ttf) format('truetype');
          }
          @font-face {
            font-family: 'Grenze';
            font-style: normal;
            font-weight: 700;
            src: url(https://fonts.gstatic.com/s/grenze/b.ttf) format('truetype');
          }
          """)

        "/s/grenze/r.ttf" ->
          Plug.Conn.send_resp(conn, 200, regular)

        "/s/grenze/b.ttf" ->
          Plug.Conn.send_resp(conn, 200, bold)
      end
    end)
  end

  test "a Google Font downloads into the data folder and is served like any other",
       %{conn: conn} do
    stub_google(self())

    assert get(conn, ~p"/google-fonts.json") |> json_response(200) == ["Grenze", "Buda"]
    assert :ok = GoogleFonts.install("Grenze")

    # Every weight it has, in one request.
    assert_received {:google, "/css2", query}
    assert URI.decode_query(query)["family"] == "Grenze:ital,wght@0,400;0,700"
    assert_received {:fonts, :changed}

    assert [%{weight: 400}, %{weight: 700}] =
             Enum.filter(Fonts.servable(), &(&1.family == "Grenze"))

    assert get(conn, ~p"/fonts.css") |> response(200) =~ ~s(font-family: "Grenze";)
    # Downloaded, it's no longer offered from Google.
    assert get(conn, ~p"/google-fonts.json") |> json_response(200) == ["Buda"]

    # Once is enough.
    assert :ok = GoogleFonts.install("Grenze")
    refute_received {:google, "/css2", _}
  end

  test "the catalogue is kept, and used when Google can't be reached" do
    stub_google(self())
    assert {:ok, [_, _]} = GoogleFonts.catalogue()
    assert_received {:google, "/metadata/fonts", _}

    assert {:ok, [_, _]} = GoogleFonts.catalogue()
    refute_received {:google, "/metadata/fonts", _}

    assert {:error, "Google Fonts has no Comic Sans"} = GoogleFonts.install("Comic Sans")
  end
end
