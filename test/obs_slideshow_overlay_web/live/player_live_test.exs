defmodule ObsSlideshowOverlayWeb.PlayerLiveTest do
  use ObsSlideshowOverlayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ObsSlideshowOverlay.Fixtures

  alias ObsSlideshowOverlay.Library

  test "plays every slide that isn't skipped, and updates as they change", %{conn: conn} do
    {:ok, s} = Library.update_slideshow(slideshow(), %{default_title: "With Thanks"})
    Library.add_images(s, for(_ <- 1..2, do: {png(:solid), "x.png"}))
    [a, b] = Library.get_slideshow("sponsors").items
    Library.update_items([b.id], %{"skipped" => "true"})

    {:ok, view, _html} = live(conn, ~p"/play/#{s.id}")
    assert has_element?(view, "[data-item='#{a.id}-0']")
    refute has_element?(view, "[data-item='#{b.id}-0']")
    # Slides without a title of their own get the slideshow's.
    assert has_element?(view, "[data-item='#{a.id}-0']", "With Thanks")

    Library.add_slide(s, %{type: :text, heading: "Welcome"})
    assert render(view) =~ "Welcome"
  end

  test "an unknown slideshow shows nothing on stream", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/play/nope")
    assert has_element?(view, "#player-missing")
    refute html =~ "nope</"
  end

  test "the address is a permalink: renaming keeps the player playing", %{conn: conn} do
    s = slideshow()
    Library.add_slide(s, %{type: :text, heading: "Welcome"})
    {:ok, by_id, _html} = live(conn, ~p"/play/#{s.id}")
    # Addresses by name, from earlier versions, follow the slideshow too.
    {:ok, by_slug, _html} = live(conn, ~p"/play/sponsors")

    {:ok, s} = Library.update_slideshow(s, %{name: "Sponsors 2026"})
    assert s.slug == "sponsors-2026"
    assert render(by_id) =~ "Welcome"
    assert render(by_slug) =~ "Welcome"

    # Deleted, it leaves the stream empty rather than showing an error.
    Library.delete_slideshow(s)
    assert has_element?(by_id, "#player-missing")
  end

  test "stored images are served, and nothing else", %{conn: conn} do
    s = slideshow()
    {[slide], []} = Library.add_images(s, [{png(:light), "x.png"}])

    assert conn |> get(~p"/media/#{slide.image}") |> response(200)
    assert conn |> get("/media/..%2Fslides.db") |> response(404)
  end

  test "a long name list plays as pages, one after another", %{conn: conn} do
    s = slideshow()
    body = Enum.map_join(1..45, "\n", &"Name #{&1} | Helper")
    {:ok, slide} = Library.add_slide(s, %{type: :names, body: body})
    [item] = Library.get_slideshow("sponsors").items

    {:ok, view, _html} = live(conn, ~p"/play/#{s.id}")
    assert has_element?(view, "[data-item='#{item.id}-0']", "Name 1")
    assert has_element?(view, "[data-item='#{item.id}-1']", "Name 24")
    refute has_element?(view, "[data-item='#{item.id}-0']", "Name 24")

    Library.update_slide(slide, %{max_per_page: 50})
    refute has_element?(view, "[data-item='#{item.id}-1']")
  end
end
