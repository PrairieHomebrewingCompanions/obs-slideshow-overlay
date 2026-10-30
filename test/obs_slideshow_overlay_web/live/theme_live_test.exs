defmodule ObsSlideshowOverlayWeb.ThemeLiveTest do
  use ObsSlideshowOverlayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ObsSlideshowOverlay.Fixtures

  alias ObsSlideshowOverlay.{Library, Media}
  alias ObsSlideshowOverlay.Library.Theme

  defp open_page(conn) do
    {:ok, view, _html} = live(conn, ~p"/themes/#{Library.default_theme().id}")
    view
  end

  defp open_section(view, section) do
    view |> element("#open-#{section}") |> render_click()
    view
  end

  defp open_background(view) do
    view |> element("#configure-background") |> render_click()
    assert has_element?(view, "#background-panel")
    view
  end

  defp upload_background(view) do
    view
    |> file_input("#background-form", :background, [
      %{name: "scene.png", content: File.read!(png(:solid)), type: "image/png"}
    ])
    |> render_upload("scene.png")
  end

  defp style(name), do: Theme.style(Library.default_theme(), name)

  test "one section is open at a time, each summed up in its heading", %{conn: conn} do
    view = open_page(conn)

    assert has_element?(view, "#open-title_style", "system-ui · 72px · bold")
    assert has_element?(view, "#open-detail_style", "system-ui · 100%")
    # A generic family, which every computer has, goes to CSS as itself.
    assert view |> element("#theme-preview") |> render() =~ "font-family: system-ui;"
    assert has_element?(view, "#section-title_style [name='theme[title_style][font]']")
    refute has_element?(view, "#section-name_style [name='theme[name_style][font]']")

    open_section(view, "name_style")
    assert has_element?(view, "#section-name_style [name='theme[name_style][font]']")
    refute has_element?(view, "#section-title_style [name='theme[title_style][font]']")

    # Clicking an open section's heading closes it.
    open_section(view, "name_style")
    refute has_element?(view, "#section-name_style [name='theme[name_style][font]']")
    assert has_element?(view, "#open-name_style[aria-expanded='false']")
  end

  test "changes save as they're made, and can be undone", %{conn: conn} do
    view = open_section(open_page(conn), "heading_style")
    # Opening a text slide's section shows a text slide.
    assert has_element?(view, "#show-text.btn-active")

    view
    |> form("#theme-form",
      theme: %{heading_style: %{font: "Grenze", size: "120", weight: "bold", uppercase: "true"}}
    )
    |> render_change()

    assert %{font: "Grenze", size: 120, weight: :bold, uppercase: true} = style(:heading_style)
    assert has_element?(view, "#save-status", "Saved")

    html = view |> element("#theme-preview") |> render()
    assert html =~ "font-family: &#39;Grenze&#39;; font-size: 120px; font-weight: 700;"
    assert has_element?(view, "#open-heading_style", "Grenze · 120px · bold · caps")

    view |> element("#undo") |> render_click()
    assert %{font: "system-ui", size: 96, weight: :bold} = style(:heading_style)
    refute has_element?(view, "#undo")
  end

  test "invalid values aren't saved", %{conn: conn} do
    view = open_page(conn)

    view
    |> form("#theme-form", theme: %{title_style: %{font: "Evil'; } body { display: none"}})
    |> render_change()

    assert style(:title_style).font == "system-ui"
    assert has_element?(view, "#section-title_style", "letters, numbers")
  end

  test "clicking text in the preview opens its section", %{conn: conn} do
    view = open_page(conn)
    view |> element("#theme-pane") |> render_hook("open_section", %{"section" => "detail_style"})
    assert has_element?(view, "#section-detail_style [name='theme[detail_style][font]']")
    assert has_element?(view, "#theme-pane[data-highlight='detail_style']")
  end

  test "the title moves by dragging or nudging", %{conn: conn} do
    view = open_page(conn)
    view |> element("#theme-pane") |> render_hook("move_title", %{"dx" => 30, "dy" => -5})

    theme = Library.default_theme()
    assert {theme.title_x, theme.title_baseline} == {150, 985}
    assert has_element?(view, "[name='theme[title_x]'][value='150']")
  end

  test "a section's text that isn't on the slide says how to see it", %{conn: conn} do
    view = open_section(open_page(conn), "footer_style")
    view |> element("#show-text") |> render_click()
    assert has_element?(view, "#section-footer_style", "Not on this slide")

    view |> element("#section-footer_style button", "Show a name list") |> render_click()
    assert has_element?(view, "#show-names.btn-active")
  end

  test "colours take a pasted hex code", %{conn: conn} do
    view = open_page(conn)
    view |> form("#theme-form", theme: %{title_style: %{color: "#336699"}}) |> render_change()
    assert style(:title_style).color == "#336699"
  end

  test "a background can be uploaded, replaced and removed", %{conn: conn} do
    view = open_background(open_page(conn))
    refute has_element?(view, "#remove-background")
    assert has_element?(view, "#background-source", "None")

    upload_background(view)
    first = Library.default_theme().background
    assert has_element?(view, "#background-source", "Uploaded image: scene.png")
    assert File.exists?(Media.path(first))
    assert has_element?(view, "#theme-preview img[src='/media/#{first}']")

    upload_background(view)
    second = Library.default_theme().background
    assert second != first
    refute File.exists?(Media.path(first))

    view |> element("#remove-background") |> render_click()
    assert Library.default_theme().background == nil
    refute File.exists?(Media.path(second))
  end

  test "the background shows in OBS only when asked", %{conn: conn} do
    view = open_background(open_page(conn))
    upload_background(view)
    background = Library.default_theme().background
    s = slideshow()
    Library.add_slide(s, %{type: :text, heading: "Hello"})

    {:ok, player, _html} = live(conn, ~p"/play/sponsors")
    refute has_element?(player, "img[src='/media/#{background}']")

    view |> element("#background-panel input[name='in_player']") |> render_click()
    assert has_element?(player, "img[src='/media/#{background}']")
  end

  test "the preview shows each kind of slide, from the library", %{conn: conn} do
    {:ok, s} = Library.update_slideshow(slideshow(), %{default_title: "With Thanks"})
    view = open_page(conn)

    # No images yet; name lists and text have samples.
    assert has_element?(view, "#show-image[disabled]")
    assert has_element?(view, "#preview-slide-names-0")

    Library.add_images(s, [{png(:dark), "acme.png"}, {png(:dark), "bolt.png"}])
    view |> element("#show-image") |> render_click()
    assert has_element?(view, "#theme-pane", "Acme")
    assert has_element?(view, "#preview-controls", "1 of 2")

    view |> element("#preview-controls button[aria-label='Next']") |> render_click()
    assert has_element?(view, "#theme-pane", "Bolt")
    assert has_element?(view, "#preview-slide-image-1", "With Thanks")

    view |> element("#show-text") |> render_click()
    assert has_element?(view, "#preview-slide-text-0", "Keynote at 7:30")
  end

  test "the content area is placed by dragging its box, and images follow it", %{conn: conn} do
    Library.add_images(slideshow(), [{png(:solid), "photo.png"}])
    view = open_section(open_page(conn), "content_area")
    view |> element("#show-image") |> render_click()
    assert has_element?(view, "#content-area-box[data-box='[120,80,1680,800]']")
    assert has_element?(view, "#content-area-box .content-area-inner")
    assert has_element?(view, "#open-content_area", "1680×800 at 120, 80")

    # Dragged off the slide's edge, it stops at the edge.
    view
    |> element("#theme-pane")
    |> render_hook("set_content_area", %{"x" => 1000, "y" => 40, "w" => 1200, "h" => 500})

    assert Theme.content_area(Library.default_theme()) == {720, 40, 1200, 500}
    # The 400x200 image fills it: as tall as the area, centred across it.
    assert view |> element("#theme-preview") |> render() =~
             "left: 820px; top: 40px; width: 1000px; height: 500px;"

    view |> element("#undo") |> render_click()
    assert Theme.content_area(Library.default_theme()) == {120, 80, 1680, 800}
  end

  test "contained images keep room around them inside the content area", %{conn: conn} do
    view = open_section(open_page(conn), "content_area")

    view
    |> form("#theme-form",
      theme: %{content_x: "0", content_y: "0", content_width: "1920", content_height: "1080"}
    )
    |> render_change()

    assert Theme.contained_area(Library.default_theme()) == {103, 60, 1714, 960}

    # It has to stay on the slide.
    view |> form("#theme-form", theme: %{content_x: "800"}) |> render_change()
    assert Library.default_theme().content_x == 0
    assert has_element?(view, "#section-content_area", "runs off the slide")
  end

  test "name lists and text are laid out in the content area too", %{conn: conn} do
    view = open_section(open_page(conn), "content_area")
    # Over a list, the box is there while its section is open, without the
    # inner box for contained images.
    assert has_element?(view, "#content-area-box")
    refute has_element?(view, "#content-area-box .content-area-inner")

    view
    |> element("#theme-pane")
    |> render_hook("set_content_area", %{"x" => 100, "y" => 0, "w" => 800, "h" => 500})

    # The sample list has a footer, so the list ends 70px early.
    html = view |> element("#theme-preview") |> render()
    assert html =~ "left: 100px; width: 800px; display: grid;"
    assert html =~ "top: 30px; height: 370px;"
    assert html =~ "left: 100px; width: 800px; top: 418px;"

    view |> element("#show-text") |> render_click()

    assert view |> element("#theme-preview") |> render() =~
             "left: 140px; top: 30px; width: 720px; height: 440px;"
  end

  test "the title has a width that longer titles shrink to fit", %{conn: conn} do
    view = open_page(conn)
    assert has_element?(view, "#title-limit[data-width='1680']")
    assert has_element?(view, "#theme-preview [data-style='title_style'][data-max-width='1680']")

    view |> element("#theme-pane") |> render_hook("set_title_width", %{"w" => 2000})
    # It stops at the slide's right edge.
    assert Library.default_theme().title_width == 1920 - 120
    assert has_element?(view, "[name='theme[title_width]'][value='1800']")
  end

  test "the title can't be dragged off the slide's right edge", %{conn: conn} do
    view = open_page(conn)
    view |> element("#theme-pane") |> render_hook("move_title", %{"dx" => 2000, "dy" => 0})

    theme = Library.default_theme()
    # All of its width stays on the slide.
    assert theme.title_x == 1920 - theme.title_width
  end

  describe "Google Fonts" do
    setup do
      File.rm_rf!(ObsSlideshowOverlay.GoogleFonts.dir())
      File.rm(Path.join(ObsSlideshowOverlay.Media.dir(), "google-fonts.json"))
      on_exit(fn -> File.rm_rf!(ObsSlideshowOverlay.GoogleFonts.dir()) end)
    end

    # Google, as far as the font menu needs it: one family, and its files
    # (or no files, when `ok?` is false).
    defp stub_google(ok?) do
      dir = Path.join(System.tmp_dir!(), "google-#{System.unique_integer([:positive])}")
      regular = File.read!(font(dir, "r.ttf", "Grenze"))

      Req.Test.stub(ObsSlideshowOverlay.GoogleFonts, fn conn ->
        case {conn.request_path, ok?} do
          {"/metadata/fonts", _} ->
            Req.Test.text(
              conn,
              ~s|)]}'{"familyMetadataList": [{"family": "Grenze", "fonts": {"400": {}}}]}|
            )

          {"/css2", true} ->
            Req.Test.text(conn, """
            @font-face {
              font-style: normal;
              font-weight: 400;
              src: url(https://fonts.gstatic.com/s/grenze/r.ttf) format('truetype');
            }
            """)

          {"/css2", false} ->
            Plug.Conn.send_resp(conn, 500, "")

          {"/s/grenze/r.ttf", _} ->
            Plug.Conn.send_resp(conn, 200, regular)
        end
      end)
    end

    test "a picked Google Font changes the style once it's downloaded", %{conn: conn} do
      stub_google(true)
      view = open_page(conn)

      view
      |> element("#theme-form [name='theme[title_style][font]']")
      |> render_hook("add_google_font", %{"family" => "Grenze", "style" => "title_style"})

      render_async(view)
      assert style(:title_style).font == "Grenze"
      # And Undo puts the old font back.
      view |> element("#undo") |> render_click()
      assert style(:title_style).font == "system-ui"
    end

    test "a Google Font that can't download leaves the style as it was", %{conn: conn} do
      stub_google(false)
      view = open_page(conn)
      input = "theme_title_style_0_font"

      view
      |> element("#theme-form [name='theme[title_style][font]']")
      |> render_hook("add_google_font", %{
        "family" => "Grenze",
        "style" => "title_style",
        "input" => input
      })

      render_async(view)
      assert style(:title_style).font == "system-ui"
      assert_push_event(view, "font_failed", %{input: ^input, font: "system-ui"})
    end
  end
end
