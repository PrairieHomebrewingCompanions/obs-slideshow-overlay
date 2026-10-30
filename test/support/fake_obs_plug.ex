defmodule ObsSlideshowOverlay.FakeObsPlug do
  @moduledoc "Upgrades every request to ObsSlideshowOverlay.FakeObs's WebSocket."
  def init(opts), do: opts
  def call(conn, _opts), do: WebSockAdapter.upgrade(conn, ObsSlideshowOverlay.FakeObs, %{}, [])
end
