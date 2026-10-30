defmodule ObsSlideshowOverlayWeb.ObsLive do
  @moduledoc """
  The optional connection to OBS. With it, the Theme page can take its
  background from an OBS scene, and a slideshow can set up its own scene in
  OBS. Without it, nothing else changes.
  """
  use ObsSlideshowOverlayWeb, :live_view

  alias ObsSlideshowOverlay.Obs

  @impl true
  def mount(_params, _session, socket) do
    settings = Obs.settings()

    {:ok,
     assign(socket,
       page_title: "OBS",
       settings: settings,
       form: to_form(Obs.change_settings(settings), as: :obs),
       status: nil
     )}
  end

  @impl true
  def handle_event("save", %{"obs" => params}, socket) do
    case Obs.save_settings(params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> assign(settings: settings, form: to_form(Obs.change_settings(settings), as: :obs))
         |> check()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :obs))}
    end
  end

  def handle_event("check", _params, socket), do: {:noreply, check(socket)}

  def handle_event("forget_password", _params, socket) do
    {:ok, settings} = Obs.forget_password()
    {:noreply, assign(socket, settings: settings, status: nil)}
  end

  defp check(socket) do
    status =
      case Obs.check() do
        {:ok, %{version: version, scenes: scenes, canvas: canvas}} ->
          text =
            "Connected to OBS #{version}, with #{scenes} scenes. #{Obs.describe_canvas(canvas)}"

          {if(canvas.widescreen, do: :ok, else: :warning), text}

        {:error, reason} ->
          {:error, "Couldn't connect: #{reason}."}
      end

    assign(socket, status: status)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-2xl space-y-6">
        <div>
          <h1 class="text-2xl font-semibold">OBS</h1>
          <p class="opacity-70">
            Optional. Connected, the Theme page can take its background from an OBS scene, and each
            slideshow can set up its own scene in OBS. In OBS: Tools → WebSocket Server Settings →
            Show Connect Info.
          </p>
        </div>

        <.form for={@form} id="obs-form" phx-submit="save" class="space-y-2">
          <.input field={@form[:url]} label="WebSocket address" class="input w-full font-mono" />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            value=""
            placeholder={if @settings.password, do: "Saved (leave blank to keep it)", else: "None"}
            autocomplete="off"
          />
          <div class="flex items-center gap-2">
            <button class="btn btn-primary">Save and connect</button>
            <button :if={@settings.id} type="button" class="btn" phx-click="check">
              Test again
            </button>
            <button
              :if={@settings.password}
              id="forget-obs-password"
              type="button"
              class="btn btn-ghost ml-auto"
              phx-click="forget_password"
            >
              Forget the password
            </button>
          </div>
        </.form>

        <div
          :if={@status}
          id="obs-status"
          role="status"
          class={[
            "alert",
            case elem(@status, 0) do
              :ok -> "alert-success"
              :warning -> "alert-warning"
              :error -> "alert-error"
            end
          ]}
        >
          {elem(@status, 1)}
        </div>

        <p class="text-sm opacity-70">
          OBS loads slideshows from {ObsSlideshowOverlayWeb.Endpoint.url()}, so for now it needs to run on this
          computer.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
