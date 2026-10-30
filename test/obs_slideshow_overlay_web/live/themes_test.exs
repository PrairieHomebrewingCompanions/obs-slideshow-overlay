defmodule ObsSlideshowOverlayWeb.ThemesTest do
  use ObsSlideshowOverlayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ObsSlideshowOverlay.Fixtures

  alias ObsSlideshowOverlay.{Library, Media}

  test "a new theme is a copy, with its own copy of the background" do
    default = Library.default_theme()
    {:ok, default} = Library.update_theme(default, %{title_style: %{font: "Grenze"}})
    {:ok, default} = Library.set_theme_background(default, png(:solid), {:upload, "bg.png"})

    {:ok, copy} = Library.create_theme(default, "Spring")
    assert copy.name == "Spring"
    assert ObsSlideshowOverlay.Library.Theme.style(copy, :title_style).font == "Grenze"
    assert copy.background != default.background
    assert File.exists?(Media.path(copy.background))

    # Removing one background leaves the other.
    {:ok, _} = Library.remove_theme_background(copy)
    assert File.exists?(Media.path(default.background))
  end

  test "slideshows use their own theme, or the default" do
    s = slideshow()
    assert Library.theme_for(s).id == Library.default_theme().id

    {:ok, spring} = Library.create_theme(Library.default_theme(), "Spring")
    {:ok, s} = Library.update_slideshow(s, %{theme_id: spring.id})
    assert Library.theme_for(s).id == spring.id
    assert %{} = usage = Library.theme_usage()
    assert [%{name: "Sponsors"}] = usage[spring.id]

    # Deleting a theme sends its slideshows back to the default.
    {:ok, _} = Library.delete_theme(spring)
    assert Library.theme_for(Library.get_slideshow("sponsors")).id == Library.default_theme().id
  end

  test "the last theme can't be deleted" do
    assert {:error, _} = Library.delete_theme(Library.default_theme())
  end

  test "the Themes page lists themes, makes new ones and deletes them", %{conn: conn} do
    default = Library.default_theme()
    slideshow()
    {:ok, view, _html} = live(conn, ~p"/themes/#{default.id}")

    assert has_element?(view, "#theme-usage", "Used by Sponsors")
    refute has_element?(view, "#delete-theme")

    view |> element("#new-theme") |> render_click()
    [_, copy] = Library.list_themes()
    assert_patch(view, ~p"/themes/#{copy.id}")
    assert copy.name == "Default copy"
    assert has_element?(view, "#theme-list", "Default copy")
    assert has_element?(view, "#theme-usage", "Not used by any slideshow yet")

    view |> element("#delete-theme") |> render_click()
    assert_patch(view, ~p"/themes/#{default.id}")
    assert Library.get_theme(copy.id) == nil
  end

  test "a slideshow chooses its theme in its settings, and plays in it", %{conn: conn} do
    {:ok, spring} = Library.create_theme(Library.default_theme(), "Spring")
    {:ok, _} = Library.update_theme(spring, %{title_style: %{font: "Grenze"}})
    s = slideshow()
    Library.add_slide(s, %{type: :text, title: "Hello", heading: "Hi"})

    {:ok, view, _html} = live(conn, ~p"/s/sponsors")
    view |> element("button[aria-label='Slideshow settings']") |> render_click()
    view |> form("#settings-form", slideshow: %{theme_id: spring.id}) |> render_submit()
    assert Library.get_slideshow("sponsors").theme_id == spring.id

    {:ok, player, _html} = live(conn, ~p"/play/sponsors")
    assert render(player) =~ "font-family: &#39;Grenze&#39;"
  end
end
