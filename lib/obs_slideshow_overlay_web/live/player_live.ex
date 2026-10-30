defmodule ObsSlideshowOverlayWeb.PlayerLive do
  @moduledoc """
  A slideshow as OBS shows it: add `/play/<id>` as a 1920x1080 browser
  source. The address is a permalink: renaming the slideshow doesn't change
  it. Changes made in the gallery appear straight away.

  Addresses by slug (`/play/welcome`) work too, and keep playing the same
  slideshow after a rename. A slideshow that
  doesn't exist shows nothing, so the stream never shows an error.
  """
  use ObsSlideshowOverlayWeb, :live_view

  alias ObsSlideshowOverlay.Library
  import ObsSlideshowOverlayWeb.SlideComponents

  @impl true
  def mount(%{"key" => key}, _session, socket) do
    if connected?(socket), do: Library.subscribe()

    id =
      case Integer.parse(key) do
        {id, ""} -> id
        _ -> nil
      end

    {:ok, socket |> assign(key: key, id: id) |> load()}
  end

  @impl true
  def handle_info({:library, :changed}, socket), do: {:noreply, load(socket)}

  # Once found, a slideshow is followed by its id, whatever it's renamed to.
  defp load(socket) do
    slideshow =
      case socket.assigns.id do
        nil -> Library.get_slideshow(socket.assigns.key)
        id -> Library.get_slideshow_by_id(id)
      end

    assign(socket,
      id: if(slideshow, do: slideshow.id, else: socket.assigns.id),
      slideshow: slideshow,
      theme: if(slideshow, do: Library.theme_for(slideshow), else: Library.default_theme()),
      steps: if(slideshow, do: steps(slideshow), else: []),
      page_title: if(slideshow, do: slideshow.name, else: "Slideshow")
    )
  end

  # What plays, in order: each slide that isn't skipped, and each page of a
  # name list too long for one.
  defp steps(slideshow) do
    for item <- slideshow.items,
        !item.skipped,
        {_entries, page} <- Enum.with_index(pages(item.slide)),
        do: {item, page}
  end

  @impl true
  def render(%{slideshow: nil} = assigns) do
    ~H"""
    <%!-- Nothing on stream: this is OBS's output, not a place for errors. --%>
    <div id="player-missing" data-key={@key}></div>
    """
  end

  def render(assigns) do
    ~H"""
    <style>
      [data-item].on { opacity: 1 !important; }
    </style>
    <div id="player" phx-hook="Player">
      <div
        data-stage
        style="position: relative; width: 1920px; height: 1080px; transform-origin: 0 0;"
      >
        <%!-- Off by default: the OBS scene usually has its own background. --%>
        <.backdrop :if={@theme.background && @theme.background_in_player} theme={@theme} />
        <%!-- A long name list plays as several pages, each a step of its own. --%>
        <div
          :for={{item, page} <- @steps}
          id={"item-#{item.id}-#{page}"}
          data-item={"#{item.id}-#{page}"}
          data-seconds={item.seconds || @slideshow.slide_seconds}
          style={[
            "position: absolute; inset: 0; opacity: 0;",
            "transition: opacity #{@slideshow.fade_ms}ms ease-in-out;"
          ]}
        >
          <.slide
            slide={item.slide}
            theme={@theme}
            default_title={@slideshow.default_title}
            page={page}
          />
        </div>
      </div>
    </div>
    """
  end
end
