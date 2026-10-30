defmodule ObsSlideshowOverlayWeb.FontsHook do
  @moduledoc """
  Tells every page when the fonts change (a Google Font downloaded), so it
  reloads /fonts.css and slides in that font show (see assets/js/app.js).
  """
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ObsSlideshowOverlay.PubSub, "fonts")
    {:cont, attach_hook(socket, :fonts, :handle_info, &fonts_changed/2)}
  end

  defp fonts_changed({:fonts, :changed}, socket),
    do: {:halt, push_event(socket, "fonts_changed", %{})}

  defp fonts_changed(_message, socket), do: {:cont, socket}
end
