defmodule ObsSlideshowOverlay.FontsTest do
  use ObsSlideshowOverlayWeb.ConnCase, async: false

  import ObsSlideshowOverlay.Fixtures

  setup do
    dir = Path.join(System.tmp_dir!(), "slides-fonts-#{System.unique_integer([:positive])}")
    Application.put_env(:obs_slideshow_overlay, :font_dirs, [dir])

    on_exit(fn ->
      Application.put_env(:obs_slideshow_overlay, :font_dirs, [])
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "installed fonts are found by family, weight and style", %{dir: dir} do
    font(dir, "Grenze-Regular.ttf", "Grenze")
    font(dir, "Grenze-BoldItalic.otf", "Grenze", 700, true)
    font(dir, "notes.txt", "Not a font")

    assert [%{weight: 400, italic: false}, %{weight: 700, italic: true}] =
             Enum.filter(ObsSlideshowOverlay.Fonts.servable(), &(&1.family == "Grenze"))

    assert ObsSlideshowOverlay.Fonts.families() == ["Grenze"]
  end

  test "a font added later is found, and an unreadable one is skipped", %{dir: dir} do
    font(dir, "Grenze.ttf", "Grenze")
    assert ObsSlideshowOverlay.Fonts.families() == ["Grenze"]

    font(dir, "sub/Lora.ttf", "Lora")
    File.write!(Path.join(dir, "broken.ttf"), "nope")
    assert ObsSlideshowOverlay.Fonts.families() == ["Grenze", "Lora"]
  end

  test "pages get a stylesheet declaring the fonts, and the files", %{conn: conn, dir: dir} do
    path = font(dir, "Lora.ttf", "Lora")
    [face] = ObsSlideshowOverlay.Fonts.servable()

    css = conn |> get(~p"/fonts.css") |> response(200)
    assert css =~ ~s(font-family: "Lora";)
    assert css =~ ~s|src: url("/fonts/#{face.id}") format("truetype");|

    assert get(conn, ~p"/fonts/#{face.id}") |> response(200) == File.read!(path)
    assert get(conn, ~p"/fonts/nope") |> response(404)
    assert get(conn, ~p"/fonts.json") |> json_response(200) == ["Lora"]
  end
end
