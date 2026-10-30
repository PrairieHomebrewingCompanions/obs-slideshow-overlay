defmodule ObsSlideshowOverlayWeb.GalleryLiveTest do
  use ObsSlideshowOverlayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ObsSlideshowOverlay.Fixtures

  alias ObsSlideshowOverlay.Library

  test "with no slideshows, invites making one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#new-slideshow-form")

    view |> form("#new-slideshow-form", new: %{name: "Sponsors"}) |> render_submit()
    assert_patch(view, ~p"/s/sponsors")
    %{id: id} = Library.get_slideshow("sponsors")
    assert has_element?(view, "#obs-url[value$='/play/#{id}']")
  end

  test "the front page opens the first slideshow", %{conn: conn} do
    slideshow()
    assert {:error, {:live_redirect, %{to: "/s/sponsors"}}} = live(conn, ~p"/")
  end

  test "uploaded images join the slideshow", %{conn: conn} do
    slideshow()
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    logo =
      file_input(view, "#upload-form", :images, [
        %{name: "07-acme-brewing.png", content: File.read!(png(:dark)), type: "image/png"}
      ])

    render_upload(logo, "07-acme-brewing.png")

    [item] = Library.get_slideshow("sponsors").items
    assert item.slide.name == "Acme Brewing"
    assert has_element?(view, "#item-#{item.id}", "Acme Brewing")
    assert has_element?(view, "#item-#{item.id}", "card")
  end

  test "selecting a slide opens its editor, and edits save", %{conn: conn} do
    s = slideshow()
    {[slide], []} = Library.add_images(s, [{png(:solid), "acme.png"}])
    [item] = Library.get_slideshow("sponsors").items
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    render_hook(view, "select", %{"ids" => ["#{item.id}"]})
    assert has_element?(view, "#slide-form")

    view
    |> form("#slide-form", slide: %{name: "ACME", style: "card", size: "fill"})
    |> render_change()

    assert %{name: "ACME", style: :card, size: :fill} =
             ObsSlideshowOverlay.Repo.get!(ObsSlideshowOverlay.Library.Slide, slide.id)
  end

  test "several selected slides change together", %{conn: conn} do
    s = slideshow()
    Library.add_images(s, for(_ <- 1..3, do: {png(:solid), "x.png"}))
    items = Library.get_slideshow("sponsors").items
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    render_hook(view, "select", %{"ids" => Enum.map(items, &"#{&1.id}")})
    assert has_element?(view, "#edit-many", "3 slides selected")

    view
    |> form("#bulk-style-form", slides: %{style: "cutout", size: "contained"})
    |> render_change()

    view |> form("#bulk-seconds-form", %{seconds: "12"}) |> render_submit()

    items = Library.get_slideshow("sponsors").items
    assert Enum.all?(items, &(&1.slide.style == :cutout and &1.slide.size == :contained))
    assert Enum.all?(items, &(&1.seconds == 12))
  end

  test "dragging reorders", %{conn: conn} do
    s = slideshow()
    Library.add_images(s, for(_ <- 1..3, do: {png(:solid), "x.png"}))
    [a, b, c] = Library.get_slideshow("sponsors").items
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    render_hook(view, "reorder", %{"ids" => Enum.map([b, c, a], &"#{&1.id}")})
    assert Enum.map(Library.get_slideshow("sponsors").items, & &1.id) == [b.id, c.id, a.id]
  end

  test "name list and text slides are made in the app", %{conn: conn} do
    slideshow()
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    view |> element("button", "Name list") |> render_click()
    view |> element("button", "Text") |> render_click()

    assert [:names, :text] = Enum.map(Library.get_slideshow("sponsors").items, & &1.slide.type)
  end

  test "double-clicking a slide opens it for editing", %{conn: conn} do
    s = slideshow()
    Library.add_slide(s, %{type: :names, name: "Volunteers", body: "Avery Chen"})
    Library.add_slide(s, %{type: :text, heading: "Welcome"})
    Library.add_images(s, [{png(:solid), "acme.png"}])
    [names, text, logo] = Library.get_slideshow("sponsors").items
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    # A name list opens its editor.
    view |> element("#grid") |> render_hook("open_item", %{"id" => "#{names.id}"})
    assert has_element?(view, "#names-editor")
    view |> element("#names-editor button[aria-label='Close']") |> render_click()

    # A text slide puts the cursor in its heading; a logo, in its name.
    view |> element("#grid") |> render_hook("open_item", %{"id" => "#{text.id}"})
    assert_push_event(view, "focus", %{selector: "#slide-form [name='slide[heading]']"})
    assert has_element?(view, "#slide-form [name='slide[heading]']")

    view |> element("#grid") |> render_hook("open_item", %{"id" => "#{logo.id}"})
    assert_push_event(view, "focus", %{selector: "#slide-form [name='slide[name]']"})
  end
end
