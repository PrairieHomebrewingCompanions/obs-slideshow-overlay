defmodule ObsSlideshowOverlayWeb.ObsLiveTest do
  use ObsSlideshowOverlayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ObsSlideshowOverlay.{FakeObs, Library, Obs}

  setup do
    port = 4600 + System.unique_integer([:positive, :monotonic])

    start_supervised!(
      {FakeObs,
       port: port,
       password: "secret",
       test: self(),
       scenes: %{"Background" => [{"Background Plain", "image_source"}]},
       inputs: %{"Background Plain" => %{kind: "image_source", settings: %{}}}}
    )

    {:ok, url: "ws://127.0.0.1:#{port}"}
  end

  test "connecting from the OBS page", %{conn: conn, url: url} do
    {:ok, view, _html} = live(conn, ~p"/obs")

    view |> form("#obs-form", obs: %{url: url, password: "wrong"}) |> render_submit()
    assert has_element?(view, "#obs-status", "OBS rejected the password")

    view |> form("#obs-form", obs: %{url: url, password: "secret"}) |> render_submit()
    assert has_element?(view, "#obs-status", "Connected to OBS 32.0.0")

    # A blank password keeps the saved one.
    view |> form("#obs-form", obs: %{url: url, password: ""}) |> render_submit()
    assert Obs.settings().password == "secret"
  end

  test "the Theme page takes its background from an OBS scene", %{conn: conn, url: url} do
    {:ok, _} = Obs.save_settings(%{"url" => url, "password" => "secret"})
    {:ok, view, _html} = live(conn, ~p"/themes/#{Library.default_theme().id}")

    render_async(view)
    view |> element("#configure-background") |> render_click()
    assert has_element?(view, "#background-source", "None")

    # Choosing a scene is enough.
    view |> element("#grab-form select") |> render_change(%{"scene" => "Background"})
    render_async(view)

    assert_received {:screenshot, "Background", _}
    assert %{background: first, background_scene: "Background"} = Library.default_theme()
    assert has_element?(view, "#theme-preview img[src='/media/#{first}']")
    assert has_element?(view, "#background-source", ~s(From the OBS scene "Background"))
    assert has_element?(view, "#grab-form option[selected][value='Background']")

    # Refresh grabs the same scene again.
    view |> element("#refresh-background") |> render_click()
    render_async(view)
    assert_received {:screenshot, "Background", _}
    assert %{background: second, background_scene: "Background"} = Library.default_theme()
    assert second != first
  end

  test "a slideshow sets itself up in OBS from its settings", %{conn: conn, url: url} do
    {:ok, _} = Obs.save_settings(%{"url" => url, "password" => "secret"})
    {:ok, _} = Library.create_slideshow(%{name: "Sponsors"})
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    view |> element("button[aria-label='Slideshow settings']") |> render_click()
    render_async(view)
    view |> form("#obs-setup-form", base: "Background") |> render_submit()
    render_async(view)

    assert Map.has_key?(FakeObs.state().scenes, "Slideshow: Sponsors")
    assert has_element?(view, "#obs-setup-form", ~s(In OBS as "Slideshow: Sponsors"))
  end

  test "without OBS set up, the slideshow settings point to the OBS page", %{conn: conn} do
    {:ok, _} = Library.create_slideshow(%{name: "Sponsors"})
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")

    view |> element("button[aria-label='Slideshow settings']") |> render_click()
    refute has_element?(view, "#obs-setup-form")
    assert has_element?(view, "a[href='/obs']", "Connect to OBS")
  end
end
