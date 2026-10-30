defmodule ObsSlideshowOverlay.ObsTest do
  use ObsSlideshowOverlay.DataCase, async: false

  alias ObsSlideshowOverlay.{FakeObs, Library, Obs}

  setup context do
    # A port per test, so tests never share a server.
    port = 4500 + System.unique_integer([:positive, :monotonic])

    start_supervised!(
      {FakeObs,
       port: port,
       password: "secret",
       test: self(),
       canvas: context[:canvas] || {1920, 1080},
       scenes: %{
         "Background" => [{"Background Plain", "image_source"}],
         "Sponsors" => [{"Background Plain", "image_source"}, {"Old Logos", "slideshow_v2"}]
       },
       inputs: %{
         "Background Plain" => %{kind: "image_source", settings: %{}},
         "Old Logos" => %{kind: "slideshow_v2", settings: %{}}
       }}
    )

    {:ok, _} = Obs.save_settings(%{"url" => "ws://127.0.0.1:#{port}", "password" => "secret"})
    :ok
  end

  test "checks the connection and lists scenes" do
    assert {:ok, %{version: "32.0.0", scenes: 2}} = Obs.check()
    assert {:ok, ["Sponsors", "Background"]} = Obs.scenes()
  end

  test "a wrong password says so" do
    {:ok, _} = Obs.save_settings(%{"password" => "nope"})
    assert {:error, "OBS rejected the password"} = Obs.check()
  end

  test "OBS not running says so" do
    {:ok, _} = Obs.save_settings(%{"url" => "ws://127.0.0.1:4499"})
    assert {:error, "OBS isn't running, or its WebSocket server is off"} = Obs.check()
  end

  test "sets a slideshow up as its own scene, and updates it in place" do
    {:ok, show} = Library.create_slideshow(%{name: "Sponsors"})
    {:ok, show, %{widescreen: true}} = Obs.set_up(show, "Background")

    state = FakeObs.state()
    assert show.obs_scene == "Slideshow: Sponsors"
    # The app's scene, not the existing "Sponsors" one
    assert [{"Background Plain", _}, {"Old Logos", _}] = sources(state, "Sponsors")

    assert [{"Background", nil}, {"Slideshow: Sponsors player", "browser_source"}] =
             sources(state, "Slideshow: Sponsors")

    assert %{"url" => url, "width" => 1920, "height" => 1080} =
             state.inputs["Slideshow: Sponsors player"].settings

    # The player's permalink, which a rename doesn't change.
    assert url == ObsSlideshowOverlayWeb.Endpoint.url() <> "/play/#{show.id}"

    # Renamed, and on another base: same scene and source, updated.
    {:ok, show} = Library.update_slideshow(show, %{name: "Preshow"})
    {:ok, _, _} = Obs.set_up(show, "Sponsors")
    state = FakeObs.state()

    refute Map.has_key?(state.scenes, "Slideshow: Sponsors")

    assert [{"Sponsors", nil}, {"Slideshow: Preshow player", _}] =
             sources(state, "Slideshow: Preshow")

    assert state.inputs["Slideshow: Preshow player"].settings["url"] =~ "/play/#{show.id}"
    assert map_size(state.inputs) == 3
  end

  test "a set-up that fails partway can be run again" do
    {:ok, show} = Library.create_slideshow(%{name: "Sponsors"})
    FakeObs.fail_next("CreateInput")
    assert {:error, "CreateInput failed"} = Obs.set_up(show, "Background")
    assert Map.has_key?(FakeObs.state().scenes, "Slideshow: Sponsors")

    show = Library.get_slideshow("sponsors")
    assert {:ok, %{obs_scene: "Slideshow: Sponsors"}, _} = Obs.set_up(show, "Background")

    assert [{"Background", nil}, {"Slideshow: Sponsors player", "browser_source"}] =
             sources(FakeObs.state(), "Slideshow: Sponsors")
  end

  test "an address that isn't OBS says so" do
    port = 4800 + System.unique_integer([:positive, :monotonic])

    start_supervised!(
      {Bandit, plug: ObsSlideshowOverlay.NotObsPlug, port: port, startup_log: false}
    )

    {:ok, _} = Obs.save_settings(%{"url" => "ws://127.0.0.1:#{port}"})

    assert {:error, "that address answers, but it isn't OBS's WebSocket server"} = Obs.check()
  end

  test "never takes over a scene it didn't make" do
    {:ok, _} =
      Obs.connect(fn obs -> Obs.call(obs, "CreateScene", %{sceneName: "Slideshow: Sponsors"}) end)

    {:ok, show} = Library.create_slideshow(%{name: "Sponsors"})

    assert {:error,
            "OBS already has a scene called Slideshow: Sponsors that this app didn't make"} =
             Obs.set_up(show, "Background")

    assert sources(FakeObs.state(), "Slideshow: Sponsors") == []
  end

  test "grabs a scene without this app's slideshows, then puts them back" do
    {:ok, show} = Library.create_slideshow(%{name: "Sponsors"})
    {:ok, _, _} = Obs.set_up(show, "Background")

    assert {:ok, <<137, "PNG", _::binary>>} = Obs.grab_scene("Slideshow: Sponsors")
    assert_receive {:screenshot, "Slideshow: Sponsors", ["Background"]}

    assert Enum.all?(FakeObs.state().scenes["Slideshow: Sponsors"], & &1.enabled)
    # Other browser sources and everything else stay as they are.
    assert {:ok, _} = Obs.grab_scene("Sponsors")
    assert_receive {:screenshot, "Sponsors", ["Background Plain", "Old Logos"]}
  end

  test "a grabbed scene becomes the theme's background" do
    {:ok, png} = Obs.grab_scene("Background")
    path = Path.join(System.tmp_dir!(), "grab.png")
    File.write!(path, png)

    assert {:ok, %{background: name, background_scene: "Background"}} =
             Library.set_theme_background(Library.default_theme(), path, {:obs, "Background"})

    assert File.exists?(ObsSlideshowOverlay.Media.path(name))
  end

  defp sources(state, scene), do: Enum.map(state.scenes[scene], &{&1.source, &1.kind})

  @tag canvas: {3840, 2160}
  test "the browser source is the size of OBS's canvas, so a 4K canvas gets sharp slides" do
    assert {:ok, %{canvas: %{width: 3840, height: 2160, widescreen: true}}} = Obs.check()
    {:ok, show} = Library.create_slideshow(%{name: "Sponsors"})
    {:ok, _, _} = Obs.set_up(show, "Background")

    assert %{"width" => 3840, "height" => 2160} =
             FakeObs.state().inputs["Slideshow: Sponsors player"].settings
  end

  @tag canvas: {1080, 1920}
  test "a canvas that isn't 16:9 is called out" do
    {:ok, %{canvas: canvas}} = Obs.check()
    refute canvas.widescreen
    assert Obs.describe_canvas(canvas) =~ "isn't 16:9"
  end
end
