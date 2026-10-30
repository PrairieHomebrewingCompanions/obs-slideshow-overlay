defmodule ObsSlideshowOverlay.Obs do
  @moduledoc """
  An optional, light connection to OBS (obs-websocket v5). Nothing here runs
  unless asked: each call connects, does its work and disconnects.

    * `scenes/0` - the scene names, for choosing one.
    * `grab_scene/1` - a screenshot of a scene, without this app's slides
      in it, for the theme's background.
    * `set_up/2` - makes (or updates) a scene that plays a slideshow: the
      chosen base scene with the slideshow's browser source on top.
  """
  import Ecto.Query

  alias ObsSlideshowOverlay.Repo
  alias ObsSlideshowOverlay.Library.Slideshow
  alias ObsSlideshowOverlay.Obs.Settings

  @timeout 5_000

  ## Settings

  def settings, do: Repo.one(from s in Settings, limit: 1) || %Settings{}

  def change_settings(%Settings{} = settings, attrs \\ %{}),
    do: Settings.changeset(settings, attrs)

  @doc "Saves the settings; a blank password keeps the saved one."
  def save_settings(attrs) do
    settings = settings()
    attrs = if attrs["password"] in [nil, ""], do: Map.delete(attrs, "password"), else: attrs
    settings |> Settings.changeset(attrs) |> Repo.insert_or_update()
  end

  def forget_password do
    settings() |> Ecto.Changeset.change(password: nil) |> Repo.insert_or_update()
  end

  @doc "Whether OBS has been set up here at all; the OBS features hide until it has."
  def configured?, do: Repo.exists?(Settings)

  ## Features

  @doc """
  Checks the connection: `{:ok, %{version: ..., scenes: n, canvas: canvas}}`,
  the canvas as from `canvas/1`.
  """
  def check do
    connect(fn c ->
      with {:ok, %{"obsVersion" => version}} <- call(c, "GetVersion"),
           {:ok, %{"scenes" => scenes}} <- call(c, "GetSceneList"),
           {:ok, canvas} <- canvas(c) do
        {:ok, %{version: version, scenes: length(scenes), canvas: canvas}}
      end
    end)
  end

  @doc """
  OBS's canvas: `%{width: w, height: h, widescreen: true}` when it's 16:9,
  the shape slides are laid out for. OBS scales a 1920x1080 slide to any
  16:9 canvas; other shapes get it letterboxed.
  """
  def canvas(c) do
    with {:ok, %{"baseWidth" => w, "baseHeight" => h}} <- call(c, "GetVideoSettings") do
      {:ok, %{width: w, height: h, widescreen: abs(w / h - 16 / 9) < 0.01}}
    end
  end

  @doc "A sentence on the canvas, for showing next to OBS results."
  def describe_canvas(%{width: w, height: h, widescreen: true}),
    do: "The canvas is #{w}×#{h}; slides fill it."

  def describe_canvas(%{width: w, height: h}),
    do:
      "The canvas is #{w}×#{h}, which isn't 16:9: slides are laid out for 16:9, so they'll " <>
        "show letterboxed."

  @doc "Scene names, top of OBS's list first."
  def scenes do
    connect(fn c ->
      with {:ok, %{"scenes" => scenes}} <- call(c, "GetSceneList") do
        # OBS lists them bottom-up.
        {:ok, scenes |> Enum.sort_by(& &1["sceneIndex"], :desc) |> Enum.map(& &1["sceneName"])}
      end
    end)
  end

  @doc """
  A 1920x1080 PNG of a scene, with any of this app's slideshows in it hidden
  for the moment of the screenshot.
  """
  def grab_scene(scene) do
    connect(fn c ->
      with {:ok, %{"sceneItems" => items}} <- call(c, "GetSceneItemList", %{sceneName: scene}) do
        ours =
          for item <- items,
              item["sceneItemEnabled"],
              item["inputKind"] == "browser_source",
              ours?(c, item["sourceName"]),
              do: item["sceneItemId"]

        enable = fn on ->
          for id <- ours do
            call(c, "SetSceneItemEnabled", %{
              sceneName: scene,
              sceneItemId: id,
              sceneItemEnabled: on
            })
          end
        end

        enable.(false)

        try do
          shot =
            call(c, "GetSourceScreenshot", %{
              sourceName: scene,
              imageFormat: "png",
              imageWidth: 1920,
              imageHeight: 1080
            })

          with {:ok, %{"imageData" => "data:image/png;base64," <> png}} <- shot do
            {:ok, Base.decode64!(png)}
          end
        after
          enable.(true)
        end
      end
    end)
  end

  defp ours?(c, input) do
    case call(c, "GetInputSettings", %{inputName: input}) do
      {:ok, %{"inputSettings" => %{"url" => url}}} -> String.starts_with?(url, player_root())
      _ -> false
    end
  end

  @doc """
  Makes OBS play a slideshow: a scene called "Slideshow: <name>" holding
  `base` (a scene with the background, and anything else under the slides)
  with the slideshow's browser
  source on top. Running it again updates that scene and source in place,
  following renames. It never takes over a scene it didn't make. The browser
  source is the size of OBS's canvas, so slides are drawn sharp at its
  resolution. Returns the updated slideshow and the canvas (see `canvas/1`).
  """
  def set_up(%Slideshow{} = slideshow, base) do
    scene = "Slideshow: #{slideshow.name}"
    input = "Slideshow: #{slideshow.name} player"
    url = player_root() <> "/play/#{slideshow.id}"

    result =
      connect(fn c ->
        with {:ok, %{"scenes" => scenes}} <- call(c, "GetSceneList"),
             names = Enum.map(scenes, & &1["sceneName"]),
             :ok <- check_base(base, scene, names),
             {:ok, canvas} <- canvas(c),
             :ok <- ensure_scene(c, slideshow.obs_scene, scene, names),
             # Remembered straight away, so a set-up that fails later can be
             # retried: the scene is ours from here on.
             {:ok, _} <- remember(slideshow, obs_scene: scene),
             :ok <- ensure_base(c, scene, slideshow.obs_base, base),
             :ok <- ensure_input(c, scene, slideshow.obs_input, input, url, canvas) do
          {:ok, canvas}
        end
      end)

    with {:ok, canvas} <- result,
         {:ok, slideshow} <-
           remember(slideshow, obs_scene: scene, obs_input: input, obs_base: base) do
      {:ok, slideshow, canvas}
    end
  end

  # What this app made in OBS for a slideshow, saved on it.
  defp remember(slideshow, changes) do
    case Repo.get(Slideshow, slideshow.id) do
      nil -> {:error, "the slideshow was deleted"}
      current -> current |> Ecto.Changeset.change(changes) |> Repo.update()
    end
  end

  defp check_base(base, scene, names) do
    cond do
      base == scene -> {:error, "the base scene can't be the slideshow's own scene"}
      base not in names -> {:error, "there's no scene called #{base}"}
      true -> :ok
    end
  end

  defp ensure_scene(c, old, scene, names) do
    cond do
      scene in names and scene == old ->
        :ok

      scene in names ->
        {:error, "OBS already has a scene called #{scene} that this app didn't make"}

      old in names ->
        ok(call(c, "SetSceneName", %{sceneName: old, newSceneName: scene}))

      true ->
        ok(call(c, "CreateScene", %{sceneName: scene}))
    end
  end

  # The base scene sits at the bottom, nested as a source.
  defp ensure_base(c, scene, old, base) do
    if old && old != base, do: remove_item(c, scene, old)

    with {:ok, id} <- item_id(c, scene, base) || create_item(c, scene, base) do
      ok(call(c, "SetSceneItemIndex", %{sceneName: scene, sceneItemId: id, sceneItemIndex: 0}))
    end
  end

  defp ensure_input(c, scene, old, input, url, canvas) do
    settings = %{url: url, width: canvas.width, height: canvas.height}

    with :ok <- create_or_rename_input(c, scene, old, input, settings),
         :ok <-
           ok(
             call(c, "SetInputSettings", %{
               inputName: input,
               inputSettings: settings,
               overlay: true
             })
           ),
         {:ok, id} <- item_id(c, scene, input) || create_item(c, scene, input),
         {:ok, %{"sceneItems" => items}} <- call(c, "GetSceneItemList", %{sceneName: scene}) do
      top = length(items) - 1
      ok(call(c, "SetSceneItemIndex", %{sceneName: scene, sceneItemId: id, sceneItemIndex: top}))
    end
  end

  defp create_or_rename_input(c, scene, old, input, settings) do
    exists? = fn name -> match?({:ok, _}, call(c, "GetInputSettings", %{inputName: name})) end

    cond do
      exists?.(input) ->
        :ok

      old && exists?.(old) ->
        ok(call(c, "SetInputName", %{inputName: old, newInputName: input}))

      true ->
        ok(
          call(c, "CreateInput", %{
            sceneName: scene,
            inputName: input,
            inputKind: "browser_source",
            inputSettings: settings
          })
        )
    end
  end

  defp item_id(c, scene, source) do
    case call(c, "GetSceneItemId", %{sceneName: scene, sourceName: source}) do
      {:ok, %{"sceneItemId" => id}} -> {:ok, id}
      _ -> nil
    end
  end

  defp create_item(c, scene, source) do
    with {:ok, %{"sceneItemId" => id}} <-
           call(c, "CreateSceneItem", %{sceneName: scene, sourceName: source}) do
      {:ok, id}
    end
  end

  defp remove_item(c, scene, source) do
    with {:ok, id} <- item_id(c, scene, source) do
      call(c, "RemoveSceneItem", %{sceneName: scene, sceneItemId: id})
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  # Where OBS reaches this app's players. OBS on another machine needs this
  # machine's address instead of localhost; see the README.
  defp player_root, do: ObsSlideshowOverlayWeb.Endpoint.url()

  ## The connection
  #
  # One connection at a time per process, kept in the process dictionary
  # while `connect/1` runs: Mint's state changes with every frame, and this
  # keeps the feature code above free of it.

  @key {__MODULE__, :conn}

  @doc false
  # Connects, identifies, runs `fun` and disconnects. Returns what `fun`
  # returns, or `{:error, reason}` as text.
  def connect(fun) do
    %Settings{url: url, password: password} = settings()
    uri = URI.parse(url)
    {scheme, ws_scheme} = if uri.scheme == "wss", do: {:https, :wss}, else: {:http, :ws}

    result =
      with {:ok, http} <-
             Mint.HTTP.connect(scheme, uri.host, uri.port || 4455, protocols: [:http1]),
           {:ok, http, ref} <- Mint.WebSocket.upgrade(ws_scheme, http, "/", []),
           {:ok, http, ws, early} <- await_upgrade(http, ref) do
        {ws, messages, _closed} = decode(ws, early)
        Process.put(@key, %{http: http, ws: ws, ref: ref, buffer: messages})

        try do
          with :ok <- identify(password), do: fun.(:obs)
        after
          %{http: http} = Process.delete(@key)
          Mint.HTTP.close(http)
        end
      else
        # Mint's errors after connecting carry the connection: close it.
        {:error, http, reason} ->
          Mint.HTTP.close(http)
          {:error, reason}

        error ->
          error
      end

    describe(result)
  catch
    {:obs, reason} -> describe({:error, reason})
  end

  # Returns the WebSocket, plus any data that came with the upgrade: OBS says
  # hello straight away, and Mint hands bytes that arrive in the same packet
  # as the 101 response over as the response's body.
  defp await_upgrade(http, ref, status \\ nil, headers \\ [], early \\ []) do
    with {:ok, message} <- receive_socket(http) do
      case Mint.WebSocket.stream(http, message) do
        {:ok, http, responses} ->
          status = Enum.find_value(responses, status, &match_status(&1, ref))
          headers = headers ++ Enum.flat_map(responses, &match_headers(&1, ref))
          early = early ++ for({:data, ^ref, _} = data <- responses, do: data)

          if {:done, ref} in responses do
            with {:ok, http, ws} <- Mint.WebSocket.new(http, ref, status, headers) do
              {:ok, http, ws, early}
            end
          else
            await_upgrade(http, ref, status, headers, early)
          end

        {:error, _http, reason, _responses} ->
          {:error, reason}
      end
    end
  end

  # Waits for a message from this connection's socket only, leaving anything
  # else the calling process is sent where it is.
  defp receive_socket(http) do
    socket = Mint.HTTP.get_socket(http)

    receive do
      {tag, ^socket, _data} = message when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
        {:ok, message}

      {tag, ^socket} = message when tag in [:tcp_closed, :ssl_closed] ->
        {:ok, message}
    after
      @timeout -> {:error, :timeout}
    end
  end

  defp match_status({:status, ref, status}, ref), do: status
  defp match_status(_, _), do: nil
  defp match_headers({:headers, ref, headers}, ref), do: headers
  defp match_headers(_, _), do: []

  defp identify(password) do
    with {:ok, %{"op" => 0, "d" => hello}} <- receive_message() do
      auth =
        case hello do
          %{"authentication" => %{"challenge" => challenge, "salt" => salt}} ->
            secret = :crypto.hash(:sha256, (password || "") <> salt) |> Base.encode64()
            %{authentication: :crypto.hash(:sha256, secret <> challenge) |> Base.encode64()}

          _ ->
            %{}
        end

      send_message(1, Map.merge(%{rpcVersion: 1, eventSubscriptions: 0}, auth))

      case receive_message() do
        {:ok, %{"op" => 2}} -> :ok
        other -> other
      end
    end
  end

  @doc false
  # One request, inside `connect/1`. The first argument is what `connect/1`
  # passes its function, so feature code reads as `call(obs, ...)`.
  def call(:obs, type, data \\ %{}) do
    id = Integer.to_string(System.unique_integer([:positive]))
    send_message(6, %{requestType: type, requestId: id, requestData: data})
    await_response(id)
  end

  defp await_response(id) do
    case receive_message() do
      {:ok, %{"op" => 7, "d" => %{"requestId" => ^id} = d}} ->
        case d["requestStatus"] do
          %{"result" => true} -> {:ok, d["responseData"] || %{}}
          status -> {:error, status["comment"] || "OBS said no (#{status["code"]})"}
        end

      {:ok, _other} ->
        await_response(id)

      error ->
        error
    end
  end

  defp send_message(op, data) do
    conn = Process.get(@key)
    {:ok, ws, frame} = Mint.WebSocket.encode(conn.ws, {:text, Jason.encode!(%{op: op, d: data})})

    case Mint.WebSocket.stream_request_body(conn.http, conn.ref, frame) do
      {:ok, http} -> Process.put(@key, %{conn | http: http, ws: ws})
      {:error, _http, reason} -> throw({:obs, reason})
    end
  end

  defp receive_message do
    case Process.get(@key) do
      %{buffer: [message | rest]} = conn ->
        Process.put(@key, %{conn | buffer: rest})
        {:ok, message}

      conn ->
        with {:ok, message} <- receive_socket(conn.http) do
          case Mint.WebSocket.stream(conn.http, message) do
            {:ok, http, responses} ->
              {ws, messages, closed} = decode(conn.ws, responses)
              Process.put(@key, %{conn | http: http, ws: ws, buffer: messages})

              if messages == [] and closed,
                do: {:error, {:closed, closed}},
                else: receive_message()

            {:error, _http, reason, _responses} ->
              {:error, reason}
          end
        end
    end
  end

  defp decode(ws, responses) do
    Enum.reduce(responses, {ws, [], nil}, fn
      {:data, _ref, data}, {ws, messages, closed} ->
        {:ok, ws, frames} = Mint.WebSocket.decode(ws, data)

        Enum.reduce(frames, {ws, messages, closed}, fn
          {:text, json}, {ws, messages, closed} -> {ws, messages ++ [Jason.decode!(json)], closed}
          {:close, code, reason}, {ws, messages, _} -> {ws, messages, {code, reason}}
          _frame, acc -> acc
        end)

      _response, acc ->
        acc
    end)
  end

  defp describe({:error, {:closed, {4009, _}}}), do: {:error, "OBS rejected the password"}

  defp describe({:error, {:closed, {_, reason}}}) when reason not in [nil, ""],
    do: {:error, reason}

  defp describe({:error, %Mint.TransportError{reason: :econnrefused}}),
    do: {:error, "OBS isn't running, or its WebSocket server is off"}

  defp describe({:error, %Mint.WebSocket.UpgradeFailureError{}}),
    do: {:error, "that address answers, but it isn't OBS's WebSocket server"}

  defp describe({:error, :timeout}), do: {:error, "OBS didn't answer"}
  defp describe({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp describe({:error, reason}), do: {:error, inspect(reason)}
  defp describe(other), do: other
end
