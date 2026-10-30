defmodule ObsSlideshowOverlay.FakeObs do
  @moduledoc """
  A small stand-in for OBS's WebSocket server: it authenticates like OBS and
  keeps scenes, scene items and inputs in an Agent, enough for ObsSlideshowOverlay.Obs.

      start_supervised!({ObsSlideshowOverlay.FakeObs, port: 4471, password: "secret", scenes: %{"Background" => []}})
      ObsSlideshowOverlay.FakeObs.state()

  Screenshots report which items were showing to the test process as
  `{:screenshot, scene, enabled_sources}`. `fail_next/1` makes the next
  request of a type fail, as OBS does when something goes wrong.
  """
  @behaviour WebSock

  @salt "salt"
  @challenge "challenge"
  @agent __MODULE__.State

  def child_spec(opts) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    scenes =
      Map.new(Keyword.get(opts, :scenes, %{}), fn {name, sources} ->
        {name, Enum.map(sources, &item/1)}
      end)

    state = %{
      scenes: scenes,
      inputs: Keyword.get(opts, :inputs, %{}),
      password: Keyword.fetch!(opts, :password),
      canvas: Keyword.get(opts, :canvas, {1920, 1080}),
      test: Keyword.fetch!(opts, :test),
      fail: MapSet.new()
    }

    children = [
      %{id: @agent, start: {Agent, :start_link, [fn -> state end, [name: @agent]]}},
      {Bandit,
       plug: ObsSlideshowOverlay.FakeObsPlug,
       port: Keyword.fetch!(opts, :port),
       startup_log: false}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  def state, do: Agent.get(@agent, & &1)

  def fail_next(type), do: Agent.update(@agent, &%{&1 | fail: MapSet.put(&1.fail, type)})

  defp item({source, kind}), do: item({source, kind, true})

  defp item({source, kind, enabled}),
    do: %{id: System.unique_integer([:positive]), source: source, kind: kind, enabled: enabled}

  @impl true
  def init(_) do
    hello = %{op: 0, d: %{rpcVersion: 1, authentication: %{challenge: @challenge, salt: @salt}}}
    {:push, {:text, Jason.encode!(hello)}, %{}}
  end

  @impl true
  def handle_in({json, _opts}, conn), do: handle(Jason.decode!(json), conn)

  @impl true
  def handle_info(_message, conn), do: {:ok, conn}

  defp handle(%{"op" => 1, "d" => d}, conn) do
    password = state().password
    secret = :crypto.hash(:sha256, password <> @salt) |> Base.encode64()

    if d["authentication"] == :crypto.hash(:sha256, secret <> @challenge) |> Base.encode64() do
      {:push, {:text, Jason.encode!(%{op: 2, d: %{negotiatedRpcVersion: 1}})}, conn}
    else
      {:stop, :normal, {4009, "Authentication failed."}, conn}
    end
  end

  defp handle(%{"op" => 6, "d" => %{"requestType" => type, "requestId" => id} = d}, conn) do
    status =
      case Agent.get_and_update(@agent, &failing_request(type, d["requestData"] || %{}, &1)) do
        {:ok, data} ->
          %{
            requestType: type,
            requestId: id,
            requestStatus: %{result: true, code: 100},
            responseData: data
          }

        {:error, comment} ->
          %{
            requestType: type,
            requestId: id,
            requestStatus: %{result: false, code: 600, comment: comment}
          }
      end

    {:push, {:text, Jason.encode!(%{op: 7, d: status})}, conn}
  end

  # A 1x1 PNG, for screenshots.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  defp failing_request(type, d, s) do
    if type in s.fail,
      do: {{:error, "#{type} failed"}, %{s | fail: MapSet.delete(s.fail, type)}},
      else: request(type, d, s)
  end

  defp request("GetVersion", _d, s), do: {{:ok, %{obsVersion: "32.0.0"}}, s}

  defp request("GetVideoSettings", _d, %{canvas: {w, h}} = s),
    do: {{:ok, %{baseWidth: w, baseHeight: h, outputWidth: w, outputHeight: h}}, s}

  defp request("GetSceneList", _d, s) do
    scenes =
      s.scenes
      |> Map.keys()
      |> Enum.sort()
      |> Enum.with_index()
      |> Enum.map(fn {n, i} -> %{sceneName: n, sceneIndex: i} end)

    {{:ok, %{scenes: scenes}}, s}
  end

  defp request("GetInputList", _d, s),
    do:
      {{:ok, %{inputs: Enum.map(s.inputs, fn {n, i} -> %{inputName: n, inputKind: i.kind} end)}},
       s}

  defp request("GetSceneItemList", %{"sceneName" => scene}, s) do
    with_scene(s, scene, fn items ->
      list =
        items
        |> Enum.with_index()
        |> Enum.map(fn {i, index} ->
          %{
            sceneItemId: i.id,
            sourceName: i.source,
            inputKind: i.kind,
            sceneItemEnabled: i.enabled,
            sceneItemIndex: index
          }
        end)

      {{:ok, %{sceneItems: list}}, s}
    end)
  end

  defp request("GetSceneItemId", %{"sceneName" => scene, "sourceName" => source}, s) do
    with_scene(s, scene, fn items ->
      case Enum.find(items, &(&1.source == source)) do
        nil -> {{:error, "No scene items were found"}, s}
        item -> {{:ok, %{sceneItemId: item.id}}, s}
      end
    end)
  end

  defp request("GetInputSettings", %{"inputName" => name}, s) do
    case s.inputs[name] do
      nil -> {{:error, "No source was found"}, s}
      input -> {{:ok, %{inputKind: input.kind, inputSettings: input.settings}}, s}
    end
  end

  defp request(
         "SetSceneItemEnabled",
         %{"sceneName" => scene, "sceneItemId" => id, "sceneItemEnabled" => on},
         s
       ),
       do:
         update_items(
           s,
           scene,
           &Enum.map(&1, fn i -> if i.id == id, do: %{i | enabled: on}, else: i end)
         )

  defp request("GetSourceScreenshot", %{"sourceName" => scene}, s) do
    with_scene(s, scene, fn items ->
      send(s.test, {:screenshot, scene, for(i <- items, i.enabled, do: i.source)})
      {{:ok, %{imageData: "data:image/png;base64," <> Base.encode64(@png)}}, s}
    end)
  end

  defp request("CreateScene", %{"sceneName" => scene}, s) do
    if Map.has_key?(s.scenes, scene) or Map.has_key?(s.inputs, scene),
      do: {{:error, "A source already exists by that name"}, s},
      else: {{:ok, %{}}, put_in(s.scenes[scene], [])}
  end

  defp request("RemoveScene", %{"sceneName" => scene}, s),
    do: {{:ok, %{}}, %{s | scenes: Map.delete(s.scenes, scene)}}

  defp request("SetSceneName", %{"sceneName" => old, "newSceneName" => new}, s) do
    {items, scenes} = Map.pop(s.scenes, old)
    scenes = Map.put(scenes, new, items)
    scenes = Map.new(scenes, fn {n, is} -> {n, Enum.map(is, &rename_source(&1, old, new))} end)
    {{:ok, %{}}, %{s | scenes: scenes}}
  end

  defp request("CreateSceneItem", %{"sceneName" => scene, "sourceName" => source}, s) do
    kind =
      cond do
        input = s.inputs[source] -> input.kind
        Map.has_key?(s.scenes, source) -> nil
        true -> :missing
      end

    if kind == :missing do
      {{:error, "No source was found"}, s}
    else
      new = item({source, kind})
      {{:ok, %{sceneItemId: new.id}}, update_in(s.scenes[scene], &(&1 ++ [new]))}
    end
  end

  defp request("RemoveSceneItem", %{"sceneName" => scene, "sceneItemId" => id}, s),
    do: update_items(s, scene, &Enum.reject(&1, fn i -> i.id == id end))

  defp request(
         "SetSceneItemIndex",
         %{"sceneName" => scene, "sceneItemId" => id, "sceneItemIndex" => index},
         s
       ) do
    update_items(s, scene, fn items ->
      {item, rest} = Enum.split_with(items, &(&1.id == id))
      List.insert_at(rest, index, hd(item))
    end)
  end

  defp request(
         "CreateInput",
         %{"sceneName" => scene, "inputName" => name, "inputKind" => kind} = d,
         s
       ) do
    if Map.has_key?(s.inputs, name) or Map.has_key?(s.scenes, name) do
      {{:error, "A source already exists by that name"}, s}
    else
      new = item({name, kind})
      s = put_in(s.inputs[name], %{kind: kind, settings: d["inputSettings"] || %{}})
      {{:ok, %{sceneItemId: new.id}}, update_in(s.scenes[scene], &(&1 ++ [new]))}
    end
  end

  defp request("SetInputName", %{"inputName" => old, "newInputName" => new}, s) do
    {input, inputs} = Map.pop(s.inputs, old)
    scenes = Map.new(s.scenes, fn {n, is} -> {n, Enum.map(is, &rename_source(&1, old, new))} end)
    {{:ok, %{}}, %{s | inputs: Map.put(inputs, new, input), scenes: scenes}}
  end

  defp request("SetInputSettings", %{"inputName" => name, "inputSettings" => settings}, s) do
    case s.inputs[name] do
      nil -> {{:error, "No source was found"}, s}
      _ -> {{:ok, %{}}, update_in(s.inputs[name].settings, &Map.merge(&1, settings))}
    end
  end

  defp request(type, _d, s), do: {{:error, "FakeObs doesn't do #{type}"}, s}

  defp with_scene(s, scene, fun) do
    case s.scenes[scene] do
      nil -> {{:error, "No source was found by the name of #{scene}"}, s}
      items -> fun.(items)
    end
  end

  defp update_items(s, scene, fun),
    do: with_scene(s, scene, fn items -> {{:ok, %{}}, put_in(s.scenes[scene], fun.(items))} end)

  defp rename_source(%{source: old} = item, old, new), do: %{item | source: new}
  defp rename_source(item, _old, _new), do: item
end
