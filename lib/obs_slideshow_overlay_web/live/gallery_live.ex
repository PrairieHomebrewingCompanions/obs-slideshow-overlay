defmodule ObsSlideshowOverlayWeb.GalleryLive do
  @moduledoc """
  The main screen: the slideshows, the selected one's slides as a grid to
  reorder and select, and a panel to edit the selection.

  Selection lives in the browser (SortableJS, see assets/js/slides.js) and
  is mirrored here so the panel can edit it.
  """
  use ObsSlideshowOverlayWeb, :live_view

  alias ObsSlideshowOverlay.{Library, Obs}
  alias ObsSlideshowOverlay.Library.Slide
  import ObsSlideshowOverlayWeb.SlideComponents
  import ObsSlideshowOverlayWeb.SidebarComponents

  @thumb_scale 0.125
  @image_types ~w(.png .jpg .jpeg .webp .gif .heic .heif)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe()

    {:ok,
     socket
     |> assign(selected: MapSet.new(), panel: nil, theme: nil)
     |> assign(obs?: Obs.configured?(), obs_scenes: nil, obs_busy: false, editing_names: nil)
     |> assign(renaming: nil)
     |> assign(new_form: to_form(%{"name" => ""}, as: :new))
     |> allow_upload(:images,
       accept: @image_types,
       max_entries: 100,
       max_file_size: 50_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    case Library.get_slideshow(slug) do
      nil ->
        {:noreply,
         socket |> put_flash(:error, "No slideshow at #{slug}") |> push_navigate(to: ~p"/")}

      slideshow ->
        {:noreply, socket |> assign(selected: MapSet.new(), panel: nil) |> load(slideshow)}
    end
  end

  def handle_params(_params, _uri, socket) do
    case Library.list_slideshows() do
      [first | _] -> {:noreply, push_patch(socket, to: ~p"/s/#{first.slug}", replace: true)}
      [] -> {:noreply, assign(socket, slideshows: [], slideshow: nil, page_title: "Slideshows")}
    end
  end

  defp load(socket, slideshow) do
    ids = MapSet.new(slideshow.items, & &1.id)

    socket
    |> assign(
      slideshow: slideshow,
      slideshows: Library.list_slideshows(),
      selected: MapSet.intersection(socket.assigns.selected, ids),
      settings_form: to_form(Library.change_slideshow(slideshow)),
      theme: Library.theme_for(slideshow),
      themes: Library.list_themes(),
      page_title: slideshow.name
    )
    |> assign_library()
  end

  defp reload(%{assigns: %{slideshow: nil}} = socket),
    do: assign(socket, slideshows: Library.list_slideshows())

  defp reload(socket) do
    case Library.get_slideshow(socket.assigns.slideshow.slug) do
      nil -> push_navigate(socket, to: ~p"/")
      slideshow -> load(socket, slideshow)
    end
  end

  defp assign_library(%{assigns: %{panel: :library, slideshow: slideshow}} = socket),
    do: assign(socket, library: Library.slides_not_in(slideshow))

  defp assign_library(socket), do: assign(socket, library: [])

  @impl true
  def handle_info({:close_names_editor}, socket),
    do: {:noreply, assign(socket, editing_names: nil)}

  def handle_info({:library, :changed}, socket) do
    {:noreply, reload(socket)}
  end

  ## Slideshows

  @impl true
  def handle_event("new_slideshow", %{"new" => %{"name" => name}}, socket) do
    case Library.create_slideshow(%{name: name}) do
      {:ok, slideshow} ->
        {:noreply,
         socket
         |> assign(new_form: to_form(%{"name" => ""}, as: :new))
         |> push_patch(to: ~p"/s/#{slideshow.slug}")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, error_text(changeset))}
    end
  end

  def handle_event("rename_start", %{"id" => id}, socket),
    do: {:noreply, assign(socket, renaming: String.to_integer("#{id}"))}

  def handle_event("rename_cancel", _params, socket),
    do: {:noreply, assign(socket, renaming: nil)}

  # From Enter ("name") or leaving the box ("value").
  def handle_event("rename_save", params, socket) do
    id = String.to_integer("#{params["item_id"] || params["id"]}")
    name = String.trim(params["name"] || params["value"] || "")
    show = Enum.find(socket.assigns.slideshows, &(&1.id == id))

    cond do
      socket.assigns.renaming != id or show == nil ->
        {:noreply, socket}

      name == "" or name == show.name ->
        {:noreply, assign(socket, renaming: nil)}

      true ->
        case Library.update_slideshow(show, %{name: name}) do
          {:ok, renamed} ->
            socket = assign(socket, renaming: nil)

            # The open slideshow's address follows its name.
            if socket.assigns.slideshow && socket.assigns.slideshow.id == id,
              do:
                {:noreply,
                 socket
                 |> assign(slideshow: %{socket.assigns.slideshow | slug: renamed.slug})
                 |> push_patch(to: ~p"/s/#{renamed.slug}", replace: true)},
              else: {:noreply, socket}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, error_text(changeset))}
        end
    end
  end

  def handle_event("save_settings", %{"slideshow" => params}, socket) do
    case Library.update_slideshow(socket.assigns.slideshow, params) do
      {:ok, slideshow} ->
        {:noreply, socket |> assign(panel: nil) |> push_patch(to: ~p"/s/#{slideshow.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, settings_form: to_form(changeset))}
    end
  end

  def handle_event("edit_names", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_names: String.to_integer(id))}
  end

  # A double-click (or Enter) on a slide: a name list opens its editor, and
  # anything else puts the cursor in its main field in the side panel.
  def handle_event("open_item", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.slideshow.items, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      %{slide: %{type: :names} = slide} ->
        {:noreply, assign(socket, selected: MapSet.new([id]), editing_names: slide.id)}

      %{slide: slide} ->
        field = if slide.type == :text, do: "heading", else: "name"

        {:noreply,
         socket
         |> assign(selected: MapSet.new([id]))
         |> push_event("focus", %{selector: "#slide-form [name='slide[#{field}]']"})}
    end
  end

  def handle_event("set_up_in_obs", %{"base" => base}, socket) do
    slideshow = socket.assigns.slideshow

    {:noreply,
     socket
     |> assign(obs_busy: true)
     |> start_async(:set_up, fn -> Obs.set_up(slideshow, base) end)}
  end

  def handle_event("delete_slideshow", _params, socket) do
    {:ok, _} = Library.delete_slideshow(socket.assigns.slideshow)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("panel", %{"panel" => panel}, socket) do
    panel = Map.fetch!(%{"library" => :library, "settings" => :settings}, panel)
    panel = if socket.assigns.panel == panel, do: nil, else: panel
    {:noreply, socket |> assign(panel: panel) |> assign_library() |> load_obs_scenes()}
  end

  ## Adding slides

  def handle_event("add_from_library", %{"ids" => ids}, socket) do
    Library.add_to_slideshow(socket.assigns.slideshow, Enum.map(ids, &String.to_integer/1))
    {:noreply, assign(socket, panel: nil)}
  end

  def handle_event("add_from_library", _params, socket), do: {:noreply, socket}

  def handle_event("add_slide", %{"type" => type}, socket) do
    attrs =
      case type do
        "names" -> %{type: :names, name: "Thank-you list", body: "Name | Detail"}
        "text" -> %{type: :text, name: "Text", heading: "Heading"}
      end

    {:ok, _} = Library.add_slide(socket.assigns.slideshow, attrs)
    {:noreply, socket}
  end

  # Uploads start on their own (auto_upload); this only satisfies the form.
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  ## Selection and order

  def handle_event("select", %{"ids" => ids}, socket) do
    {:noreply, assign(socket, selected: MapSet.new(ids, &String.to_integer/1))}
  end

  def handle_event("reorder", %{"ids" => ids}, socket) do
    Library.reorder(socket.assigns.slideshow, Enum.map(ids, &String.to_integer/1))
    {:noreply, socket}
  end

  ## Editing the selection

  def handle_event("save_slide", %{"slide" => params}, socket) do
    [item] = selected_items(socket.assigns)
    {:ok, _} = Library.update_slide(item.slide, params)
    {:noreply, socket}
  end

  def handle_event("save_item", %{"item" => params}, socket) do
    Library.update_items(MapSet.to_list(socket.assigns.selected), params)
    {:noreply, socket}
  end

  def handle_event("set_slides", %{"slides" => params}, socket) do
    params = Map.reject(params, fn {_k, v} -> v == "" end)
    Library.update_slides(selected_slide_ids(socket.assigns), params)
    {:noreply, socket}
  end

  def handle_event("set_items", params, socket) do
    attrs = Map.take(params, ~w(seconds skipped))
    Library.update_items(MapSet.to_list(socket.assigns.selected), attrs)
    {:noreply, socket}
  end

  def handle_event("remove", _params, socket) do
    Library.remove_items(MapSet.to_list(socket.assigns.selected))
    {:noreply, socket |> assign(selected: MapSet.new()) |> push_event("select-none", %{})}
  end

  def handle_event("delete", _params, socket) do
    Library.delete_slides(selected_slide_ids(socket.assigns))
    {:noreply, socket |> assign(selected: MapSet.new()) |> push_event("select-none", %{})}
  end

  def handle_event("delete_from_library", %{"id" => id}, socket) do
    Library.delete_slides([String.to_integer(id)])
    {:noreply, socket}
  end

  # The settings panel asks OBS for its scenes when it opens, without
  # holding the page up.
  defp load_obs_scenes(%{assigns: %{panel: :settings, obs?: true}} = socket) do
    start_async(socket, :obs_scenes, &Obs.scenes/0)
  end

  defp load_obs_scenes(socket), do: socket

  @impl true
  def handle_async(:obs_scenes, {:ok, result}, socket) do
    {:noreply, assign(socket, obs_scenes: result)}
  end

  def handle_async(:obs_scenes, {:exit, _}, socket) do
    {:noreply, assign(socket, obs_scenes: {:error, "couldn't reach OBS"})}
  end

  def handle_async(:set_up, {:ok, {:ok, slideshow, canvas}}, socket) do
    message =
      "OBS has a scene called \"#{slideshow.obs_scene}\" playing this slideshow. " <>
        Obs.describe_canvas(canvas)

    {:noreply,
     socket
     |> assign(obs_busy: false)
     |> put_flash(if(canvas.widescreen, do: :info, else: :error), message)
     |> reload()}
  end

  def handle_async(:set_up, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(obs_busy: false) |> put_flash(:error, "OBS: #{reason}")}
  end

  def handle_async(:set_up, {:exit, _}, socket) do
    {:noreply, socket |> assign(obs_busy: false) |> put_flash(:error, "Couldn't reach OBS")}
  end

  defp handle_progress(:images, entry, socket) when entry.done? do
    {_slides, errors} =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Library.add_images(socket.assigns.slideshow, [{path, entry.client_name}])}
      end)

    socket =
      Enum.reduce(errors, socket, fn {name, reason}, socket ->
        put_flash(socket, :error, "#{name}: #{reason}")
      end)

    {:noreply, socket}
  end

  defp handle_progress(_kind, _entry, socket), do: {:noreply, socket}

  defp editing_slide(_slideshow, nil), do: nil

  defp editing_slide(slideshow, slide_id),
    do: Enum.find_value(slideshow.items, &(&1.slide_id == slide_id && &1.slide))

  defp selected_items(%{slideshow: slideshow, selected: selected}),
    do: Enum.filter(slideshow.items, &MapSet.member?(selected, &1.id))

  defp selected_slide_ids(assigns), do: assigns |> selected_items() |> Enum.map(& &1.slide_id)

  defp error_text(changeset) do
    changeset.errors |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        thumb_scale: @thumb_scale,
        names_slide:
          assigns[:slideshow] && editing_slide(assigns.slideshow, assigns.editing_names),
        selection: if(assigns[:slideshow], do: selected_items(assigns), else: [])
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- Fills the window: only the grid of slides scrolls. --%>
      <div class="flex h-full gap-6">
        <aside class="w-52 shrink-0 space-y-4 overflow-y-auto">
          <h2 class="text-xs font-semibold uppercase tracking-wider opacity-60">Slideshows</h2>
          <ul class="menu menu-sm w-full p-0">
            <.item
              :for={show <- @slideshows}
              id={"slideshow-#{show.id}"}
              item_id={show.id}
              name={show.name}
              patch={~p"/s/#{show.slug}"}
              active={@slideshow && @slideshow.id == show.id}
              editing={@renaming == show.id}
            />
          </ul>
          <.form for={@new_form} id="new-slideshow-form" phx-submit="new_slideshow" class="flex gap-1">
            <input
              type="text"
              name={@new_form[:name].name}
              value={@new_form[:name].value}
              placeholder="New slideshow"
              required
              class="input input-sm flex-1 min-w-0"
            />
            <button class="btn btn-sm btn-square" aria-label="Add slideshow">
              <.icon name="hero-plus" class="size-4" />
            </button>
          </.form>
        </aside>

        <section :if={!@slideshow} class="flex-1 py-24 text-center">
          <.icon name="hero-presentation-chart-bar" class="size-12 opacity-30" />
          <p class="mt-4 text-lg">Create a slideshow to start.</p>
          <p class="opacity-60">Name it on the left, e.g. "Welcome", "Sponsors" or "Intermission".</p>
        </section>

        <section :if={@slideshow} class="flex min-h-0 min-w-0 flex-1 flex-col gap-4">
          <div class="shrink-0 space-y-4">
            <div class="flex flex-wrap items-center gap-2">
              <h1 class="mr-2 text-2xl font-semibold">{@slideshow.name}</h1>
              <span class="badge badge-ghost">{length(@slideshow.items)} slides</span>
              <div class="ml-auto flex flex-wrap gap-2">
                <label for={@uploads.images.ref} class="btn btn-sm btn-primary">
                  <.icon name="hero-photo" class="size-4" /> Add images
                </label>
                <button class="btn btn-sm" phx-click="add_slide" phx-value-type="names">
                  <.icon name="hero-list-bullet" class="size-4" /> Name list
                </button>
                <button class="btn btn-sm" phx-click="add_slide" phx-value-type="text">
                  <.icon name="hero-document-text" class="size-4" /> Text
                </button>
                <button
                  class={["btn btn-sm", @panel == :library && "btn-active"]}
                  phx-click="panel"
                  phx-value-panel="library"
                >
                  <.icon name="hero-rectangle-stack" class="size-4" /> From library
                </button>
                <button
                  class={["btn btn-sm btn-square", @panel == :settings && "btn-active"]}
                  phx-click="panel"
                  phx-value-panel="settings"
                  aria-label="Slideshow settings"
                >
                  <.icon name="hero-cog-6-tooth" class="size-4" />
                </button>
              </div>
            </div>

            <form id="upload-form" phx-change="validate_upload" class="hidden">
              <.live_file_input upload={@uploads.images} />
            </form>

            <div class="flex items-center gap-2 text-sm">
              <span class="opacity-70">OBS browser source:</span>
              <input
                id="obs-url"
                readonly
                value={url(~p"/play/#{@slideshow.id}")}
                class="input input-xs w-80 font-mono"
              />
              <button
                class="btn btn-xs"
                phx-click={JS.dispatch("phx:copy", to: "#obs-url")}
              >
                Copy
              </button>
              <.link href={~p"/play/#{@slideshow.id}"} target="_blank" class="btn btn-xs btn-ghost">
                Preview <.icon name="hero-arrow-top-right-on-square" class="size-3" />
              </.link>
              <div class="ml-auto"><.backdrop_toggle id="gallery-backdrop-toggle" /></div>
            </div>

            <.settings_panel
              :if={@panel == :settings}
              form={@settings_form}
              themes={@themes}
              slideshow={@slideshow}
              obs?={@obs?}
              obs_scenes={@obs_scenes}
              obs_busy={@obs_busy}
            />
            <.library_panel
              :if={@panel == :library}
              slides={@library}
              theme={@theme}
              scale={@thumb_scale}
            />

            <div
              :for={entry <- @uploads.images.entries}
              :if={!entry.done?}
              class="text-sm opacity-70"
            >
              Adding {entry.client_name}… {entry.progress}%
            </div>

            <div
              :if={@slideshow.items == []}
              class="rounded-box border-2 border-dashed border-base-300 py-16 text-center opacity-70"
            >
              Drop logos or photos anywhere on this page, or use <b>Add images</b> above.
            </div>
          </div>

          <div class="min-h-0 flex-1 overflow-y-auto">
            <div
              id="grid"
              phx-hook="Gallery"
              class="flex flex-wrap content-start gap-4 pb-6 select-none"
            >
              <div
                :for={item <- @slideshow.items}
                id={"item-#{item.id}"}
                data-item={item.id}
                title="Double-click to edit"
                class={[
                  "group w-fit cursor-grab rounded-box border-2 border-transparent p-1",
                  "[&.is-selected]:border-primary [&.is-selected]:bg-primary/10",
                  MapSet.member?(@selected, item.id) && "is-selected"
                ]}
              >
                <.thumbnail
                  slide={item.slide}
                  theme={@theme}
                  scale={@thumb_scale}
                  default_title={@slideshow.default_title}
                  class={item.skipped && "opacity-30"}
                />
                <div
                  class="mt-1 flex items-center gap-1 px-1 text-xs"
                  style={"width: #{1920 * @thumb_scale}px;"}
                >
                  <span class="truncate font-medium">{label(item.slide)}</span>
                  <span :if={item.slide.type == :image} class="badge badge-xs badge-ghost">
                    {style_label(Slide.style(item.slide))}{if Slide.size(item.slide) == :contained,
                      do: ", contained"}
                  </span>
                  <span :if={item.seconds} class="badge badge-xs badge-info">{item.seconds}s</span>
                  <span
                    :if={length(pages(item.slide)) > 1}
                    class="badge badge-xs badge-accent"
                    title="Too many names for one page: each page plays in turn"
                  >
                    {length(pages(item.slide))} pages
                  </span>
                  <span :if={item.skipped} class="badge badge-xs badge-warning">skipped</span>
                </div>
              </div>
            </div>
          </div>
        </section>

        <aside :if={@slideshow} class="w-80 shrink-0 overflow-y-auto">
          <.selection_panel
            selection={@selection}
            theme={@theme}
            default_title={@slideshow.default_title}
            default_seconds={@slideshow.slide_seconds}
          />
        </aside>
      </div>

      <.live_component
        :if={@names_slide}
        module={ObsSlideshowOverlayWeb.NamesEditorComponent}
        id="names-editor"
        slide={@names_slide}
        theme={@theme}
      />

      <div
        :if={@slideshow}
        id="drop-overlay"
        phx-hook="FileDrag"
        class="fixed inset-0 z-50 hidden gap-6 bg-base-100/80 p-6 backdrop-blur-sm"
      >
        <div
          phx-drop-target={@uploads.images.ref}
          class="flex flex-1 flex-col items-center justify-center gap-2 rounded-box border-4 border-dashed border-primary text-2xl font-semibold"
        >
          Drop to add to {@slideshow.name}
          <span class="text-base font-normal opacity-70">
            Each image's style is picked from its pixels: change it after if it's wrong.
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :slide, Slide, required: true
  attr :theme, :map, required: true
  attr :scale, :float, required: true
  attr :default_title, :string, default: nil
  attr :class, :any, default: nil

  # A slide drawn full size and scaled down, over the theme's background (or
  # a stand-in) so its placement reads.
  defp thumbnail(assigns) do
    ~H"""
    <div
      class={["slide-frame relative overflow-hidden rounded-md", @class]}
      style={"width: #{1920 * @scale}px; height: #{1080 * @scale}px;"}
    >
      <div style={"position: absolute; left: 0; top: 0; transform: scale(#{@scale}); transform-origin: 0 0;"}>
        <.backdrop theme={@theme} hideable />
        <.slide slide={@slide} theme={@theme} default_title={@default_title} />
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :themes, :list, required: true
  attr :slideshow, :map, required: true
  attr :obs?, :boolean, required: true
  attr :obs_scenes, :any, required: true
  attr :obs_busy, :boolean, required: true

  defp settings_panel(assigns) do
    ~H"""
    <div class="rounded-box bg-base-200 p-4">
      <.form
        for={@form}
        id="settings-form"
        phx-submit="save_settings"
        class="grid gap-x-4 sm:grid-cols-5"
      >
        <.input field={@form[:name]} label="Name" />
        <.input
          field={@form[:default_title]}
          label="Default title"
          placeholder="For slides without their own"
        />
        <.input
          field={@form[:theme_id]}
          type="select"
          label="Theme"
          options={Enum.map(@themes, &{&1.name, &1.id})}
        />
        <.input field={@form[:slide_seconds]} type="number" label="Seconds per slide" />
        <.input field={@form[:fade_ms]} type="number" label="Fade (ms)" />
        <div class="flex gap-2 sm:col-span-5">
          <button class="btn btn-sm btn-primary">Save</button>
          <button
            type="button"
            class="btn btn-sm btn-ghost text-error ml-auto"
            phx-click="delete_slideshow"
            data-confirm="Delete this slideshow? Its slides stay in the library."
          >
            Delete slideshow
          </button>
        </div>
      </.form>

      <div class="mt-4 border-t border-base-300 pt-4 text-sm">
        <p :if={!@obs?} class="opacity-70">
          <.link navigate={~p"/obs"} class="link">Connect to OBS</.link>
          to set this slideshow up in OBS with one click.
        </p>
        <%= if @obs? do %>
          <form id="obs-setup-form" phx-submit="set_up_in_obs" class="space-y-2">
            <p class="font-semibold">OBS</p>
            <p class="opacity-70">
              Makes a scene called "Slideshow: {@slideshow.name}" in OBS: the scene you pick (your
              background, and anything else under the slides) with this slideshow on top. Run it
              again after a rename to rename the scene.
            </p>
            <%= case @obs_scenes do %>
              <% nil -> %>
                <p class="opacity-60">Asking OBS for its scenes…</p>
              <% {:error, reason} -> %>
                <p class="text-error">{reason}</p>
              <% {:ok, scenes} -> %>
                <div class="flex flex-wrap items-center gap-2">
                  <label for="obs-base">On top of</label>
                  <select id="obs-base" name="base" class="select select-sm w-64">
                    <option
                      :for={scene <- Enum.reject(scenes, &String.starts_with?(&1, "Slideshow: "))}
                      value={scene}
                      selected={scene == @slideshow.obs_base}
                    >
                      {scene}
                    </option>
                  </select>
                  <button class="btn btn-sm btn-primary" disabled={@obs_busy}>
                    {cond do
                      @obs_busy -> "Working…"
                      @slideshow.obs_scene -> "Update in OBS"
                      true -> "Set up in OBS"
                    end}
                  </button>
                </div>
            <% end %>
            <p :if={@slideshow.obs_scene} class="opacity-70">
              In OBS as "{@slideshow.obs_scene}", on top of "{@slideshow.obs_base}".
            </p>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  attr :slides, :list, required: true
  attr :theme, :map, required: true
  attr :scale, :float, required: true

  defp library_panel(assigns) do
    ~H"""
    <div class="max-h-[45vh] shrink-0 overflow-y-auto rounded-box bg-base-200 p-4">
      <p :if={@slides == []} class="text-sm opacity-70">
        Every slide in the library is already in this slideshow.
      </p>
      <form :if={@slides != []} id="library-form" phx-submit="add_from_library" class="space-y-3">
        <p class="text-sm opacity-70">Slides from other slideshows. Tick the ones to add.</p>
        <div class="flex flex-wrap gap-3">
          <label :for={slide <- @slides} class="cursor-pointer">
            <.thumbnail slide={slide} theme={@theme} scale={@scale * 0.75} />
            <span class="mt-1 flex items-center gap-1 text-xs">
              <input type="checkbox" name="ids[]" value={slide.id} class="checkbox checkbox-xs" />
              <span class="truncate">{label(slide)}</span>
            </span>
          </label>
        </div>
        <button class="btn btn-sm btn-primary">Add to slideshow</button>
      </form>
    </div>
    """
  end

  attr :selection, :list, required: true
  attr :theme, :map, required: true
  attr :default_title, :string, default: nil
  attr :default_seconds, :integer, required: true

  defp selection_panel(%{selection: []} = assigns) do
    ~H"""
    <div class="rounded-box bg-base-200 p-4 text-sm opacity-70 space-y-2">
      <p>Click a slide to select it; double-click (or press Enter) to edit it.</p>
      <p>
        <kbd class="kbd kbd-xs">⌘</kbd>/<kbd class="kbd kbd-xs">Ctrl</kbd>-click to add to the
        selection, <kbd class="kbd kbd-xs">Shift</kbd>-click for a range, then drag to reorder or
        change them all at once. <kbd class="kbd kbd-xs">Esc</kbd> clears.
      </p>
    </div>
    """
  end

  defp selection_panel(%{selection: [item]} = assigns) do
    assigns =
      assign(assigns,
        item: item,
        slide: item.slide,
        slide_form: to_form(Library.change_slide(item.slide)),
        item_form: to_form(ObsSlideshowOverlay.Library.Item.changeset(item, %{}))
      )

    ~H"""
    <div id={"edit-#{@item.id}"} class="rounded-box bg-base-200 p-4 space-y-4">
      <div class="flex items-center justify-between">
        <h2 class="font-semibold">{type_label(@slide.type)}</h2>
        <span class="text-xs opacity-60">{label(@slide)}</span>
      </div>

      <.form for={@slide_form} id="slide-form" phx-change="save_slide" phx-submit="save_slide">
        <.input
          field={@slide_form[:name]}
          label={name_label(@slide.type)}
          phx-debounce="400"
        />
        <%= if @slide.type == :image do %>
          <div class="grid grid-cols-2 gap-x-3">
            <.input
              field={@slide_form[:style]}
              type="select"
              label="Style"
              options={style_options(@slide)}
            />
            <.input
              field={@slide_form[:size]}
              type="select"
              label="Size"
              options={size_options(@slide)}
            />
          </div>
          <.input field={@slide_form[:trim]} type="checkbox" label="Trim 3px off each edge" />
        <% end %>
        <%= if @slide.type == :names do %>
          <div class="mb-2 flex items-center gap-2 rounded-box bg-base-100 px-3 py-2 text-sm">
            <span id="names-summary" class="flex-1">
              {length(names(@slide.body))} names{if @slide.footer not in [nil, ""],
                do: ", with a footer"}
            </span>
            <button
              id="edit-names"
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="edit_names"
              phx-value-id={@slide.id}
            >
              <.icon name="hero-pencil-square" class="size-4" /> Edit names…
            </button>
          </div>
        <% end %>
        <%= if @slide.type == :text do %>
          <.input field={@slide_form[:heading]} label="Heading" phx-debounce="400" />
          <.input field={@slide_form[:body]} type="textarea" label="Text" rows="5" phx-debounce="400" />
        <% end %>
        <.input
          field={@slide_form[:title]}
          label="Title"
          placeholder={@default_title || "None"}
          phx-debounce="400"
        />
      </.form>

      <.form for={@item_form} id="item-form" phx-change="save_item">
        <.input
          field={@item_form[:seconds]}
          type="number"
          label="Seconds on screen"
          placeholder={"#{@default_seconds} (default)"}
          min="1"
          phx-debounce="400"
        />
        <.input field={@item_form[:skipped]} type="checkbox" label="Skip in this slideshow" />
      </.form>

      <.selection_actions />
    </div>
    """
  end

  defp selection_panel(assigns) do
    assigns = assign(assigns, images?: Enum.all?(assigns.selection, &(&1.slide.type == :image)))

    ~H"""
    <div id="edit-many" class="rounded-box bg-base-200 p-4 space-y-4">
      <h2 class="font-semibold">{length(@selection)} slides selected</h2>

      <form
        :if={@images?}
        id="bulk-style-form"
        phx-change="set_slides"
        class="grid grid-cols-2 gap-x-3"
      >
        <label class="label text-sm">Style for all</label>
        <label class="label text-sm">Size for all</label>
        <select name="slides[style]" class="select select-sm w-full">
          <option value="">Keep each one's</option>
          <option :for={{label, value} <- style_choices()} value={value}>{label}</option>
        </select>
        <select name="slides[size]" class="select select-sm w-full">
          <option value="">Keep each one's</option>
          <option :for={{label, value} <- size_choices()} value={value}>{label}</option>
        </select>
      </form>

      <form id="bulk-title-form" phx-submit="set_slides" class="space-y-1">
        <label class="label text-sm">Title for all</label>
        <div class="flex gap-1">
          <input type="text" name="slides[title]" class="input input-sm flex-1" placeholder="Title" />
          <button class="btn btn-sm">Set</button>
        </div>
      </form>

      <form id="bulk-seconds-form" phx-submit="set_items" class="space-y-1">
        <label class="label text-sm">Seconds on screen for all</label>
        <div class="flex gap-1">
          <input
            type="number"
            name="seconds"
            min="1"
            class="input input-sm flex-1"
            placeholder={"#{@default_seconds} (default)"}
          />
          <button class="btn btn-sm">Set</button>
          <button
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="set_items"
            phx-value-seconds=""
          >
            Use default
          </button>
        </div>
      </form>

      <div class="flex flex-wrap gap-1">
        <button class="btn btn-xs" phx-click="set_items" phx-value-skipped="true">Skip</button>
        <button class="btn btn-xs" phx-click="set_items" phx-value-skipped="false">Don't skip</button>
      </div>

      <.selection_actions />
    </div>
    """
  end

  defp selection_actions(assigns) do
    ~H"""
    <div class="flex gap-2 border-t border-base-300 pt-3">
      <button class="btn btn-xs" phx-click="remove">Remove from slideshow</button>
      <button
        class="btn btn-xs btn-ghost text-error ml-auto"
        phx-click="delete"
        data-confirm="Delete from the library, and every slideshow it's in?"
      >
        Delete
      </button>
    </div>
    """
  end

  defp label(%Slide{name: name}) when name not in [nil, ""], do: name
  defp label(%Slide{type: type}), do: type_label(type)

  defp type_label(:image), do: "Image"
  defp type_label(:names), do: "Name list"
  defp type_label(:text), do: "Text"

  defp name_label(_type), do: "Name (labels it in the gallery)"

  defp style_choices,
    do: [
      {"Automatic", "auto"},
      {"Framed", "framed"},
      {"Cut-out", "cutout"},
      {"White card", "card"}
    ]

  defp size_choices,
    do: [
      {"Automatic", "auto"},
      {"Fill", "fill"},
      {"Contained", "contained"}
    ]

  # "Automatic (fill)": what automatic comes to for this image.
  defp size_options(slide) do
    [{auto_label, "auto"} | rest] = size_choices()
    auto = slide |> Map.put(:size, :auto) |> Slide.size()
    [{"#{auto_label} (#{auto})", "auto"} | rest]
  end

  defp style_options(slide) do
    [{auto_label, "auto"} | rest] = style_choices()
    auto = if slide.auto_style, do: " (#{style_label(slide.auto_style)})", else: ""
    [{auto_label <> auto, "auto"} | rest]
  end

  defp style_label(:framed), do: "framed"
  defp style_label(:cutout), do: "cut-out"
  defp style_label(:card), do: "card"
end
