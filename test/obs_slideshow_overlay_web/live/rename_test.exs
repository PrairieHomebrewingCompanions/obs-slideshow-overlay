defmodule ObsSlideshowOverlayWeb.RenameTest do
  use ObsSlideshowOverlayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ObsSlideshowOverlay.Fixtures

  alias ObsSlideshowOverlay.Library

  test "renaming the open slideshow in the sidebar moves its gallery page, not its player",
       %{conn: conn} do
    s = slideshow()
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    view |> element("#slideshow-#{s.id} button[aria-label='Rename Sponsors']") |> render_click()
    assert has_element?(view, "#slideshow-#{s.id}-name")

    view |> form("#slideshow-#{s.id}-rename", name: "Preshow") |> render_submit()
    assert_patch(view, ~p"/s/preshow")
    assert has_element?(view, "#slideshow-#{s.id}", "Preshow")
    assert has_element?(view, "#obs-url[value$='/play/#{s.id}']")
  end

  test "leaving the box saves; Esc cancels", %{conn: conn} do
    s = slideshow()
    other = slideshow("Photos")
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    view
    |> element("#slideshow-#{other.id}-link")
    |> render_hook("rename_start", %{"id" => "#{other.id}"})

    view |> element("#slideshow-#{other.id}-name") |> render_blur(%{"value" => "Pictures"})
    assert Library.get_slideshow("pictures")
    # Renaming another slideshow leaves this one open.
    assert has_element?(view, "h1", "Sponsors")

    view |> element("#slideshow-#{s.id} button[aria-label='Rename Sponsors']") |> render_click()
    view |> element("#slideshow-#{s.id}-name") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#slideshow-#{s.id}-name")
    assert Library.get_slideshow("sponsors")
  end

  test "a name another slideshow already has is refused", %{conn: conn} do
    s = slideshow()
    slideshow("Photos")
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    view |> element("#slideshow-#{s.id} button[aria-label='Rename Sponsors']") |> render_click()
    view |> form("#slideshow-#{s.id}-rename", name: "photos") |> render_submit()
    assert render(view) =~ "too close"
    assert Library.get_slideshow("sponsors")
  end

  test "themes rename in the sidebar too", %{conn: conn} do
    theme = Library.default_theme()
    {:ok, view, _html} = live(conn, ~p"/themes/#{theme.id}")

    view
    |> element("#theme-#{theme.id}-link")
    |> render_hook("rename_start", %{"id" => "#{theme.id}"})

    view |> form("#theme-#{theme.id}-rename", name: "Autumn Gala") |> render_submit()

    assert Library.get_theme(theme.id).name == "Autumn Gala"
    assert has_element?(view, "h1", "Autumn Gala")
    assert has_element?(view, "#theme-list", "Autumn Gala")
  end
end
