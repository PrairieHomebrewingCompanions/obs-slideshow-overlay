defmodule ObsSlideshowOverlayWeb.ThemeLive do
  @moduledoc """
  The Themes page: a theme's look, one section at a time, beside a preview
  that shows which text each section draws (outlined) on real slides.
  Clicking text in the preview opens its section; the title can be
  dragged into place. Changes save as they're made, with Undo.

  Fonts are chosen by family name: the generic families every computer
  has, installed fonts, and Google Fonts, downloaded when picked (see
  ObsSlideshowOverlay.Fonts and ObsSlideshowOverlay.GoogleFonts).
  """
  use ObsSlideshowOverlayWeb, :live_view

  alias ObsSlideshowOverlay.{Library, Obs}
  alias ObsSlideshowOverlay.Library.{Slide, Theme}
  import ObsSlideshowOverlayWeb.SlideComponents
  import ObsSlideshowOverlayWeb.SidebarComponents

  # Shown when the library has no slide of that kind yet. (The names are
  # made up.)
  @samples %{
    names: %Slide{
      type: :names,
      title: "Thank You to Our Volunteers",
      body: """
      Avery Chen | Stage Crew
      Priya Natarajan | Registration
      Sam Rivera | Photography
      Jordan Okafor | Hospitality
      Lena Fischer | Sound
      Theo Martin | Host
      """,
      footer: "And thank you to everyone who helped along the way!"
    },
    text: %Slide{
      type: :text,
      name: "Sample text",
      title: "Coming Up",
      heading: "Keynote at 7:30",
      body: "Avery Chen on what comes next"
    }
  }

  # The preview's buttons: each kind of slide the theme has to suit.
  @kinds [
    image: "Image",
    names: "Name list",
    text: "Text"
  ]

  # The page's sections: the content area or each text style (with what its
  # size means), and which slides show it.
  @sections [
    {:title_style, "Title", "Size (px)", :any},
    {:content_area, "Content area", nil, :any},
    {:name_style, "List names", "Size (% of fit)", :names},
    {:detail_style, "List details", "Size (% of fit)", :names},
    {:footer_style, "List footer", "Size (px)", :names},
    {:heading_style, "Text heading", "Size (px)", :text},
    {:body_style, "Text body", "Size (px)", :text}
  ]

  @section_names Map.new(@sections, fn {name, _, _, _} -> {Atom.to_string(name), name} end)

  # How many changes Undo can step back through.
  @undo_depth 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Library.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Themes", theme: nil, renaming: nil)
     |> assign(obs?: Obs.configured?(), obs_scenes: nil, grabbing: nil)
     |> assign(kind: :names, index: 0, open: :title_style, undo: [], saved: nil)
     |> assign(background_open: false)
     |> load_obs_scenes()
     |> allow_upload(:background,
       accept: ~w(.png .jpg .jpeg .webp),
       max_entries: 1,
       max_file_size: 50_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    with {id, ""} <- Integer.parse(id),
         %Theme{} = theme <- Library.get_theme(id) do
      changed_theme? = socket.assigns.theme && socket.assigns.theme.id != theme.id
      socket = if changed_theme?, do: assign(socket, undo: [], saved: nil), else: socket
      {:noreply, show_theme(socket, theme)}
    else
      _ -> {:noreply, push_navigate(socket, to: ~p"/themes")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, push_patch(socket, to: ~p"/themes/#{Library.default_theme().id}", replace: true)}
  end

  defp show_theme(socket, theme) do
    socket
    |> assign(theme: theme, preview: theme, page_title: theme.name)
    |> assign(form: to_form(Library.change_theme(theme)))
    |> load_themes()
    |> load_slides()
  end

  defp load_themes(socket) do
    assign(socket, themes: Library.list_themes(), usage: Library.theme_usage())
  end

  # This theme, the others, or the slides may have changed (saves here
  # included): show them as they are now.
  @impl true
  def handle_info({:library, :changed}, socket) do
    case Library.get_theme(socket.assigns.theme.id) do
      nil -> {:noreply, push_patch(socket, to: ~p"/themes")}
      theme -> {:noreply, show_theme(socket, theme)}
    end
  end

  # The library's slides by kind, for the preview's buttons.
  defp load_slides(socket) do
    slides = Library.list_slides()

    by_kind =
      Map.new(@kinds, fn {kind, _label} ->
        matching = Enum.filter(slides, &(kind_of(&1) == kind))
        {kind, if(matching == [] and @samples[kind], do: [@samples[kind]], else: matching)}
      end)

    # The title a slide without one gets, from a slideshow that uses
    # this theme.
    default_title =
      case socket.assigns.usage[socket.assigns.theme.id] do
        [first | _] -> first.default_title
        _ -> nil
      end

    index = min(socket.assigns.index, max(length(by_kind[socket.assigns.kind]) - 1, 0))
    assign(socket, by_kind: by_kind, index: index, default_title: default_title)
  end

  defp kind_of(%Slide{type: type}), do: type

  ## Editing: every valid change saves, and can be undone

  @impl true
  def handle_event("change", %{"theme" => params}, socket) do
    changeset = Library.change_theme(socket.assigns.theme, params)

    if changeset.valid? and changeset.changes != %{} do
      {:noreply, save(socket, params)}
    else
      {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
    end
  end

  def handle_event("change", _params, socket), do: {:noreply, socket}

  # Dragging and resizing in the preview reply with where things ended up,
  # which ThemePreview puts back: a move the slide's edge stopped changes
  # nothing here, so no update would undo the drag on the page.
  def handle_event("move_title", %{"dx" => dx, "dy" => dy}, socket) do
    theme = socket.assigns.theme

    socket
    |> assign(open: :title_style)
    |> save(%{
      # The title, all of its width, stays on the slide.
      "title_x" => clamp(theme.title_x + dx, 0, 1920 - theme.title_width),
      "title_baseline" => clamp(theme.title_baseline + dy, 1, 1080)
    })
    |> placed()
  end

  # The content area's box, dragged or resized in the preview.
  def handle_event("set_content_area", %{"x" => x, "y" => y, "w" => w, "h" => h}, socket) do
    w = clamp(round(w), 100, 1920)
    h = clamp(round(h), 100, 1080)

    socket
    |> assign(open: :content_area)
    |> save(%{
      "content_x" => clamp(round(x), 0, 1920 - w),
      "content_y" => clamp(round(y), 0, 1080 - h),
      "content_width" => w,
      "content_height" => h
    })
    |> placed()
  end

  # The title's width limit, dragged by its handle in the preview.
  def handle_event("set_title_width", %{"w" => w}, socket) do
    w = clamp(round(w), 100, 1920 - socket.assigns.theme.title_x)
    socket |> assign(open: :title_style) |> save(%{"title_width" => w}) |> placed()
  end

  def handle_event("undo", _params, socket) do
    case socket.assigns.undo do
      [] ->
        {:noreply, socket}

      [previous | rest] ->
        {:ok, theme} = Library.update_theme(socket.assigns.theme, previous)
        {:noreply, socket |> assign(undo: rest, saved: :undone) |> show_theme(theme)}
    end
  end

  # A section's heading opens it, or closes it if it's open. (Clicking text
  # in the preview only ever opens.)
  def handle_event("toggle_section", %{"section" => section}, socket) do
    case @section_names[section] do
      nil -> {:noreply, socket}
      open when open == socket.assigns.open -> {:noreply, assign(socket, open: nil)}
      section -> {:noreply, open_section(socket, section)}
    end
  end

  # A Google Font picked in a font menu: its files download, then the style
  # changes to it (with Undo), so the slides never show it before it's here.
  # If it can't download, the font box goes back to the style's font.
  def handle_event("add_google_font", %{"family" => family, "style" => style} = params, socket) do
    case Enum.find(Theme.styles(), &(Atom.to_string(&1) == style)) do
      nil ->
        {:noreply, socket}

      style ->
        {:noreply,
         socket
         |> put_flash(:info, "Downloading #{family} from Google Fonts…")
         |> start_async({:google_font, family, style, params["input"]}, fn ->
           ObsSlideshowOverlay.GoogleFonts.install(family)
         end)}
    end
  end

  def handle_event("open_section", %{"section" => section}, socket) do
    case @section_names[section] do
      nil -> {:noreply, socket}
      section -> {:noreply, open_section(socket, section)}
    end
  end

  ## Themes

  def handle_event("rename_start", %{"id" => id}, socket),
    do: {:noreply, assign(socket, renaming: String.to_integer("#{id}"))}

  def handle_event("rename_cancel", _params, socket),
    do: {:noreply, assign(socket, renaming: nil)}

  # From Enter ("name") or leaving the box ("value").
  def handle_event("rename_save", params, socket) do
    id = String.to_integer("#{params["item_id"] || params["id"]}")
    name = String.trim(params["name"] || params["value"] || "")
    theme = Enum.find(socket.assigns.themes, &(&1.id == id))

    cond do
      socket.assigns.renaming != id or theme == nil ->
        {:noreply, socket}

      name == "" or name == theme.name ->
        {:noreply, assign(socket, renaming: nil)}

      true ->
        {:ok, renamed} = Library.update_theme(theme, %{name: name})
        socket = assign(socket, renaming: nil)

        if renamed.id == socket.assigns.theme.id,
          do: {:noreply, show_theme(socket, renamed)},
          else: {:noreply, load_themes(socket)}
    end
  end

  def handle_event("new_theme", _params, socket) do
    from = socket.assigns.theme

    case Library.create_theme(from, "#{from.name} copy") do
      {:ok, theme} -> {:noreply, push_patch(socket, to: ~p"/themes/#{theme.id}")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't make a new theme")}
    end
  end

  def handle_event("delete_theme", _params, socket) do
    case Library.delete_theme(socket.assigns.theme) do
      {:ok, _} -> {:noreply, push_patch(socket, to: ~p"/themes")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Can't delete it: #{reason}")}
    end
  end

  ## The preview's slides

  def handle_event("show_kind", %{"kind" => kind}, socket) do
    kind = Enum.find_value(@kinds, fn {k, _} -> if Atom.to_string(k) == kind, do: k end)
    {:noreply, assign(socket, kind: kind || socket.assigns.kind, index: 0)}
  end

  def handle_event("step", %{"by" => by}, socket) do
    count = length(socket.assigns.by_kind[socket.assigns.kind])
    index = Integer.mod(socket.assigns.index + String.to_integer(by), max(count, 1))
    {:noreply, assign(socket, index: index)}
  end

  ## Background

  def handle_event("toggle_background", _params, socket),
    do: {:noreply, assign(socket, background_open: !socket.assigns.background_open)}

  # Choosing a scene applies it straight away.
  def handle_event("grab", %{"scene" => scene}, socket) when scene != "",
    do: {:noreply, grab(socket, scene)}

  def handle_event("grab", _params, socket), do: {:noreply, socket}

  def handle_event("refresh_background", _params, socket),
    do: {:noreply, grab(socket, socket.assigns.theme.background_scene)}

  def handle_event("set_in_player", params, socket) do
    on = params["in_player"] == "true"
    {:ok, theme} = Library.update_theme(socket.assigns.theme, %{background_in_player: on})
    {:noreply, assign(socket, theme: theme)}
  end

  def handle_event("remove_background", _params, socket) do
    {:ok, theme} = Library.remove_theme_background(socket.assigns.theme)
    {:noreply, background_changed(socket, theme)}
  end

  def handle_event("validate_background", _params, socket), do: {:noreply, socket}

  defp save(socket, params) do
    before = snapshot(socket.assigns.theme)

    case Library.update_theme(socket.assigns.theme, params) do
      {:ok, theme} ->
        undo = Enum.take([before | socket.assigns.undo], @undo_depth)
        socket |> assign(undo: undo, saved: :saved) |> show_theme(theme)

      {:error, changeset} ->
        assign(socket, form: to_form(changeset, action: :validate))
    end
  end

  defp placed(socket) do
    theme = socket.assigns.theme

    {:reply,
     %{
       title_x: theme.title_x,
       title_width: theme.title_width,
       content: [theme.content_x, theme.content_y, theme.content_width, theme.content_height]
     }, socket}
  end

  # What Undo puts back: the styles and where the title and images go (not
  # the name or background, which have their own controls).
  defp snapshot(theme) do
    styles = Map.new(Theme.styles(), &{&1, Map.from_struct(Theme.style(theme, &1))})

    Map.merge(
      styles,
      Map.take(theme, [
        :title_x,
        :title_baseline,
        :title_width,
        :content_x,
        :content_y,
        :content_width,
        :content_height
      ])
    )
  end

  # Opening a section shows a slide that has its text, if this one doesn't.
  defp open_section(socket, section) do
    {_, _, _, shows_on} = Enum.find(@sections, fn {name, _, _, _} -> name == section end)
    socket = assign(socket, open: section)

    if shows_on == :any or socket.assigns.kind == shows_on,
      do: socket,
      else: assign(socket, kind: shows_on, index: 0)
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  # OBS is asked only when this page opens, and without holding it up.
  defp load_obs_scenes(%{assigns: %{obs?: true}} = socket) do
    if connected?(socket), do: start_async(socket, :obs_scenes, &Obs.scenes/0), else: socket
  end

  defp load_obs_scenes(socket), do: socket

  @impl true
  def handle_async(:obs_scenes, {:ok, {:ok, scenes}}, socket),
    do: {:noreply, assign(socket, obs_scenes: scenes)}

  def handle_async(:obs_scenes, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, obs_scenes: {:error, reason})}

  def handle_async(:obs_scenes, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, obs_scenes: {:error, "couldn't reach OBS"})}

  def handle_async({:google_font, family, style, _input}, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> save(%{Atom.to_string(style) => %{"font" => family}})
     |> put_flash(:info, "#{family} is downloaded, and kept with the show.")}
  end

  def handle_async({:google_font, family, style, input}, result, socket) do
    reason =
      case result do
        {:ok, {:error, reason}} -> ": #{reason}"
        _ -> ""
      end

    {:noreply,
     socket
     |> push_event("font_failed", %{
       input: input,
       font: Theme.style(socket.assigns.theme, style).font
     })
     |> put_flash(:error, "Couldn't download #{family}#{reason}. The font is unchanged.")}
  end

  def handle_async(:grab, {:ok, {scene, {:ok, png}}}, socket) do
    path =
      Path.join(System.tmp_dir!(), "slides-obs-grab-#{System.unique_integer([:positive])}.png")

    File.write!(path, png)
    result = Library.set_theme_background(socket.assigns.theme, path, {:obs, scene})
    File.rm(path)

    case result do
      {:ok, theme} ->
        {:noreply, socket |> assign(grabbing: nil) |> background_changed(theme)}

      {:error, reason} ->
        {:noreply,
         socket |> assign(grabbing: nil) |> put_flash(:error, "Couldn't use it: #{reason}")}
    end
  end

  def handle_async(:grab, {:ok, {_scene, {:error, reason}}}, socket),
    do: {:noreply, socket |> assign(grabbing: nil) |> put_flash(:error, "OBS: #{reason}")}

  def handle_async(:grab, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(grabbing: nil) |> put_flash(:error, "Couldn't reach OBS")}

  defp grab(socket, scene) do
    socket
    |> assign(grabbing: scene)
    |> start_async(:grab, fn -> {scene, Obs.grab_scene(scene)} end)
  end

  defp background_changed(socket, theme),
    do:
      assign(socket,
        theme: theme,
        preview: %{socket.assigns.preview | background: theme.background}
      )

  defp handle_progress(:background, entry, socket) when entry.done? do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok,
         Library.set_theme_background(socket.assigns.theme, path, {:upload, entry.client_name})}
      end)

    case result do
      {:ok, theme} ->
        {:noreply, background_changed(socket, theme)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't use that image: #{reason}")}
    end
  end

  defp handle_progress(:background, _entry, socket), do: {:noreply, socket}

  ## Page

  @impl true
  def render(assigns) do
    slides = assigns.by_kind[assigns.kind]

    assigns =
      assign(assigns,
        sections: @sections,
        kinds: @kinds,
        slides: slides,
        shown: Enum.at(slides, assigns.index),
        colors: Theme.styles() |> Enum.map(&Theme.style(assigns.theme, &1).color) |> Enum.uniq(),
        fonts: Theme.styles() |> Enum.map(&Theme.style(assigns.theme, &1).font) |> Enum.uniq()
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <div :if={@theme} class="flex h-full gap-6">
        <aside class="w-52 shrink-0 space-y-4 overflow-y-auto">
          <h2 class="text-xs font-semibold uppercase tracking-wider opacity-60">Themes</h2>
          <ul id="theme-list" class="menu menu-sm w-full p-0">
            <.item
              :for={theme <- @themes}
              id={"theme-#{theme.id}"}
              item_id={theme.id}
              name={theme.name}
              patch={~p"/themes/#{theme.id}"}
              active={theme.id == @theme.id}
              editing={@renaming == theme.id}
            >
              <:badge>
                <span :if={theme.id == hd(@themes).id} class="badge badge-xs badge-ghost">
                  default
                </span>
              </:badge>
            </.item>
          </ul>
          <button id="new-theme" class="btn btn-sm w-full" phx-click="new_theme">
            <.icon name="hero-plus" class="size-4" /> New theme
          </button>
          <p class="text-xs opacity-60">A new theme starts as a copy of the one you're looking at.</p>
        </aside>

        <%!-- The form scrolls on the left; the preview stays put on the right. --%>
        <div class="grid min-w-0 flex-1 gap-6 lg:grid-cols-[minmax(22rem,30rem)_minmax(0,1fr)]">
          <div class="min-h-0 space-y-4 overflow-y-auto pr-1 pb-6">
            <div class="flex items-start gap-3">
              <div class="flex-1">
                <h1 class="text-2xl font-semibold">{@theme.name}</h1>
                <p id="theme-usage" class="text-sm opacity-70">
                  <%= case @usage[@theme.id] do %>
                    <% nil -> %>
                      Not used by any slideshow yet: choose it in a slideshow's settings.
                    <% shows -> %>
                      Used by {Enum.map_join(shows, ", ", & &1.name)}.
                  <% end %>
                  <span :if={@theme.id == hd(@themes).id}>
                    The default: slideshows that haven't chosen a theme use it.
                  </span>
                </p>
              </div>
              <button
                :if={length(@themes) > 1}
                id="delete-theme"
                class="btn btn-sm btn-ghost text-error"
                phx-click="delete_theme"
                data-confirm={"Delete #{@theme.name}? Slideshows using it go back to the default theme."}
              >
                Delete
              </button>
            </div>

            <div id="save-status" class="flex h-8 items-center gap-2 text-sm">
              <span :if={@saved == :saved} class="flex items-center gap-1 text-success">
                <.icon name="hero-check" class="size-4" /> Saved
              </span>
              <span :if={@saved == :undone} class="opacity-70">Undone</span>
              <span :if={@saved == nil} class="opacity-60">Changes save as you make them.</span>
              <button
                :if={@undo != []}
                id="undo"
                class="btn btn-xs btn-ghost ml-auto"
                phx-click="undo"
              >
                <.icon name="hero-arrow-uturn-left" class="size-3" /> Undo
              </button>
            </div>

            <datalist id="theme-colors">
              <option :for={color <- @colors} value={color}></option>
            </datalist>

            <.form for={@form} id="theme-form" phx-change="change" phx-submit="change">
              <div id="theme-sections" phx-hook="ThemeSections" class="space-y-2">
                <%= for {name, label, size_label, shows_on} <- @sections do %>
                  <section
                    id={"section-#{name}"}
                    class={[
                      "rounded-box border border-base-300",
                      @open == name && "border-primary/60 bg-base-200"
                    ]}
                  >
                    <button
                      type="button"
                      id={"open-#{name}"}
                      data-section={name}
                      class="flex w-full items-center gap-3 px-4 py-2 text-left"
                      phx-click="toggle_section"
                      phx-value-section={name}
                      aria-expanded={to_string(@open == name)}
                    >
                      <.icon
                        name={if @open == name, do: "hero-chevron-down", else: "hero-chevron-right"}
                        class="size-4 shrink-0 opacity-60"
                      />
                      <span class="font-semibold">{label}</span>
                      <span class="ml-auto truncate text-xs opacity-60">
                        {summary(@theme, name)}
                      </span>
                    </button>

                    <div :if={@open == name} class="space-y-3 px-4 pb-4">
                      <p
                        :if={shows_on != :any and @kind != shows_on}
                        class="text-sm opacity-70"
                      >
                        Not on this slide.
                        <button
                          type="button"
                          class="link"
                          phx-click="show_kind"
                          phx-value-kind={shows_on}
                        >
                          Show {kind_name(shows_on)}
                        </button>
                      </p>
                      <%= if name == :content_area do %>
                        <.content_place form={@form} />
                      <% else %>
                        <.inputs_for :let={style} field={@form[name]}>
                          <.style_fields style={style} size_label={size_label} fonts={@fonts} />
                        </.inputs_for>
                        <.title_place :if={name == :title_style} form={@form} />
                      <% end %>
                    </div>
                  </section>
                <% end %>
              </div>
            </.form>
          </div>

          <%!-- The preview: outlines show what the open section styles. --%>
          <div
            id="theme-pane"
            phx-hook="ThemePreview"
            data-open={@open}
            data-highlight={@open}
            tabindex="0"
            class="min-w-0 space-y-3 self-start outline-none"
          >
            <div id="preview-controls" class="flex flex-wrap items-center gap-2">
              <div class="join flex-wrap">
                <button
                  :for={{kind, label} <- @kinds}
                  id={"show-#{kind}"}
                  class={["btn btn-sm join-item", kind == @kind && "btn-active btn-primary"]}
                  phx-click="show_kind"
                  phx-value-kind={kind}
                  disabled={@by_kind[kind] == []}
                >
                  {label}
                </button>
              </div>
              <div :if={length(@slides) > 1} class="flex items-center gap-1 text-sm">
                <button
                  class="btn btn-sm btn-square"
                  phx-click="step"
                  phx-value-by="-1"
                  aria-label="Previous"
                >
                  <.icon name="hero-chevron-left" class="size-4" />
                </button>
                <span class="tabular-nums opacity-70">{@index + 1} of {length(@slides)}</span>
                <button
                  class="btn btn-sm btn-square"
                  phx-click="step"
                  phx-value-by="1"
                  aria-label="Next"
                >
                  <.icon name="hero-chevron-right" class="size-4" />
                </button>
              </div>
              <div class="ml-auto flex items-center gap-1">
                <button
                  id="configure-background"
                  type="button"
                  class={["btn btn-sm", @background_open && "btn-active"]}
                  phx-click="toggle_background"
                  aria-expanded={to_string(@background_open)}
                >
                  <.icon name="hero-photo" class="size-4" /> Background
                </button>
                <.backdrop_toggle id="theme-backdrop-toggle" />
              </div>
            </div>

            <div
              :if={@background_open}
              id="background-panel"
              class="space-y-2 rounded-box border border-primary/60 bg-base-200 px-4 py-3"
            >
              <div class="flex items-center gap-2">
                <h2 class="font-semibold">Background</h2>
                <span class="text-xs opacity-60">
                  Behind the previews: your OBS scene without the slides looks most like the show.
                </span>
                <button
                  type="button"
                  class="btn btn-xs btn-ghost ml-auto"
                  phx-click="toggle_background"
                >
                  Done
                </button>
              </div>
              <.background_section
                theme={@theme}
                obs?={@obs?}
                obs_scenes={@obs_scenes}
                grabbing={@grabbing}
                uploads={@uploads}
              />
            </div>

            <div
              id="theme-preview"
              phx-hook="Settle"
              class="slide-frame relative overflow-hidden rounded-box"
              style="width: 100%; aspect-ratio: 16 / 9;"
            >
              <div
                data-preview
                style="position: absolute; left: 0; top: 0; width: 1920px; height: 1080px; transform-origin: 0 0; transform: scale(var(--preview-scale, 0.4));"
              >
                <.backdrop theme={@preview} hideable />
                <.slide
                  :if={@shown}
                  id={"preview-slide-#{@kind}-#{@index}"}
                  slide={@shown}
                  theme={@preview}
                  default_title={@default_title}
                />
                <.title_limit :if={@open == :title_style} theme={@preview} />
                <.content_area_box
                  :if={@kind == :image or @open == :content_area}
                  theme={@preview}
                  contained={@kind == :image}
                />
              </div>
            </div>
            <p class="text-xs opacity-60">
              <span :if={@shown && @shown.name}>{@shown.name} · </span>
              Click text to edit its style.
              <span :if={@open == :title_style}>
                Drag the title into place, or nudge it with the arrow keys (Shift for 10px).
              </span>
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # A one-line summary of a section, for its heading.
  defp summary(theme, :content_area) do
    {x, y, w, h} = Theme.content_area(theme)
    "#{w}×#{h} at #{x}, #{y}"
  end

  defp summary(theme, name) do
    s = Theme.style(theme, name)
    unit = if name in [:name_style, :detail_style], do: "%", else: "px"

    [
      s.font,
      "#{s.size}#{unit}",
      s.weight == :bold && "bold",
      s.italic && "italic",
      s.uppercase && "caps"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  attr :style, :any, required: true
  attr :size_label, :string, required: true
  attr :fonts, :list, required: true, doc: "the theme's fonts, suggested first"

  defp style_fields(assigns) do
    ~H"""
    <div class="space-y-1">
      <%!-- Saved when a font is picked or the box is left, not as it's typed
           (FontInput in js/slides.js holds back the typing). --%>
      <.input
        field={@style[:font]}
        label="Font"
        phx-hook="FontInput"
        autocomplete="off"
        spellcheck="false"
        role="combobox"
        aria-autocomplete="list"
        aria-expanded="false"
        data-fonts={Jason.encode!(@fonts)}
      />
      <p id={"#{@style[:font].id}-warning"} hidden class="-mt-1 text-xs text-warning">
        Not installed on this computer, so it shows in a stand-in font. Install it on the computer
        running this app.
      </p>
    </div>
    <div class="grid grid-cols-3 gap-x-3">
      <.input field={@style[:size]} type="number" label={@size_label} phx-debounce="300" />
      <.input
        field={@style[:weight]}
        type="select"
        label="Weight"
        options={[{"Regular", "normal"}, {"Bold", "bold"}]}
      />
      <.input
        field={@style[:shadow]}
        type="select"
        label="Shadow"
        options={[{"None", "none"}, {"Soft", "soft"}, {"Hard", "hard"}]}
      />
      <.color_field field={@style[:color]} />
      <.input field={@style[:letter_spacing]} type="number" label="Spacing (px)" phx-debounce="300" />
    </div>
    <div class="flex gap-6">
      <.input field={@style[:italic]} type="checkbox" label="Italic" />
      <.input field={@style[:uppercase]} type="checkbox" label="Capitals" />
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  # A colour swatch and its hex code, kept in step (ColorField in
  # js/slides.js); the code is what's saved, so one can be pasted in. The
  # swatch suggests the theme's other colours.
  defp color_field(assigns) do
    ~H"""
    <fieldset class="fieldset col-span-2 mb-2">
      <label class="label mb-1" for={@field.id}>Colour</label>
      <div id={"#{@field.id}-color"} phx-hook="ColorField" class="flex gap-2">
        <input
          type="color"
          value={@field.value}
          list="theme-colors"
          aria-label="Pick a colour"
          class="h-9 w-12 shrink-0 cursor-pointer rounded border border-base-300 bg-transparent"
        />
        <input
          type="text"
          id={@field.id}
          name={@field.name}
          value={@field.value}
          phx-debounce="300"
          pattern="#[0-9a-fA-F]{6}"
          class="input input-sm w-full font-mono"
        />
      </div>
    </fieldset>
    """
  end

  defp kind_name(:image), do: "an image"
  defp kind_name(:names), do: "a name list"
  defp kind_name(:text), do: "a text slide"

  attr :theme, :any, required: true
  attr :contained, :boolean, default: false, doc: "show where contained images fit"

  # The content area over the preview: click it to open its section; drag it,
  # or its edges and corners, to place it (ThemePreview in js/slides.js).
  # Over an image, the inner box shows where contained ones (logos) fit.
  # (Over lists and text it's only there while its section is open, so their
  # text can still be clicked.)
  defp content_area_box(assigns) do
    {x, y, w, h} = Theme.content_area(assigns.theme)
    {cx, cy, cw, ch} = Theme.contained_area(assigns.theme)
    assigns = assign(assigns, x: x, y: y, w: w, h: h, inner: {cx - x, cy - y, cw, ch})

    ~H"""
    <div
      id="content-area-box"
      data-style="content_area"
      data-box={Jason.encode!([@x, @y, @w, @h])}
      style={"position: absolute; left: #{@x}px; top: #{@y}px; width: #{@w}px; height: #{@h}px;"}
    >
      <div
        :if={@contained}
        class="content-area-inner"
        style={"left: #{elem(@inner, 0)}px; top: #{elem(@inner, 1)}px; width: #{elem(@inner, 2)}px; height: #{elem(@inner, 3)}px;"}
      />
      <span :for={handle <- ~w(nw n ne e se s sw w)} class="content-area-handle" data-handle={handle} />
    </div>
    """
  end

  attr :theme, :any, required: true

  # How wide the title may be, over the preview while its section is open:
  # drag the handle to change it (ThemePreview in js/slides.js).
  defp title_limit(assigns) do
    size = Theme.style(assigns.theme, :title_style).size

    assigns =
      assign(assigns, top: assigns.theme.title_baseline - size, height: round(size * 1.25))

    ~H"""
    <div
      id="title-limit"
      data-width={@theme.title_width}
      style={"left: #{@theme.title_x}px; top: #{@top}px; width: #{@theme.title_width}px; height: #{@height}px;"}
    >
      <span class="title-limit-handle" data-title-handle title="Drag to change the title's width" />
    </div>
    """
  end

  attr :form, :any, required: true

  defp content_place(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-x-3">
      <.input field={@form[:content_x]} type="number" label="Left edge (px)" phx-debounce="300" />
      <.input field={@form[:content_y]} type="number" label="Top edge (px)" phx-debounce="300" />
      <.input field={@form[:content_width]} type="number" label="Width (px)" phx-debounce="300" />
      <.input field={@form[:content_height]} type="number" label="Height (px)" phx-debounce="300" />
      <p class="col-span-2 -mt-1 text-xs opacity-70">
        Where every slide's content goes: images set to fill take the whole area, and contained ones
        (logos) fit the dotted box inside it. Name lists and text are laid out inside it. Drag the
        area in the preview, or its edges and corners to resize it.
      </p>
    </div>
    """
  end

  attr :form, :any, required: true

  defp title_place(assigns) do
    ~H"""
    <div class="grid grid-cols-3 gap-x-3 border-t border-base-300 pt-3">
      <.input field={@form[:title_x]} type="number" label="Left edge (px)" phx-debounce="300" />
      <.input field={@form[:title_baseline]} type="number" label="Baseline (px)" phx-debounce="300" />
      <.input field={@form[:title_width]} type="number" label="Width (px)" phx-debounce="300" />
      <p class="col-span-3 -mt-1 text-xs opacity-70">
        In slide pixels from the top left: slides are a 1920×1080 grid that OBS scales to fit its
        canvas. A title wider than its width shrinks to fit. Or drag the title in the preview, and
        the handle at the end of its dashed box to change its width.
      </p>
    </div>
    """
  end

  attr :theme, :any, required: true
  attr :obs?, :boolean, required: true
  attr :obs_scenes, :any, required: true
  attr :grabbing, :any, required: true
  attr :uploads, :any, required: true

  defp background_section(assigns) do
    ~H"""
    <form id="background-form" phx-change="validate_background" class="flex flex-wrap gap-4">
      <div
        id="background-thumbnail"
        class="relative shrink-0 overflow-hidden rounded-md"
        style="width: 160px; height: 90px;"
      >
        <div style="position: absolute; transform: scale(0.08333); transform-origin: 0 0;">
          <.backdrop theme={@theme} />
        </div>
        <div
          :if={@grabbing}
          class="absolute inset-0 flex items-center justify-center bg-base-100/70 text-xs"
        >
          Grabbing…
        </div>
      </div>

      <div class="min-w-64 flex-1 space-y-2">
        <p id="background-source" class="text-sm font-medium">
          <%= cond do %>
            <% @theme.background_scene -> %>
              From the OBS scene "{@theme.background_scene}"
            <% @theme.background_upload -> %>
              Uploaded image: {@theme.background_upload}
            <% @theme.background -> %>
              Uploaded image
            <% true -> %>
              None: the previews use a plain stand-in
          <% end %>
        </p>

        <div class="flex flex-wrap items-center gap-2">
          <div :if={@obs?} id="grab-form" class="contents">
            <%= case @obs_scenes do %>
              <% nil -> %>
                <span class="text-xs opacity-60">Asking OBS for its scenes…</span>
              <% {:error, reason} -> %>
                <span class="text-xs text-error">OBS: {reason}</span>
              <% scenes -> %>
                <select
                  name="scene"
                  class="select select-sm w-56"
                  disabled={@grabbing != nil}
                  aria-label="Use an OBS scene"
                  phx-change="grab"
                >
                  <option value="" selected={!@theme.background_scene}>Use an OBS scene…</option>
                  <option
                    :for={scene <- scenes}
                    value={scene}
                    selected={scene == @theme.background_scene}
                  >
                    {scene}
                  </option>
                </select>
                <button
                  :if={@theme.background_scene}
                  id="refresh-background"
                  type="button"
                  class="btn btn-sm btn-square"
                  phx-click="refresh_background"
                  disabled={@grabbing != nil}
                  title="Grab the scene again"
                  aria-label="Refresh from OBS"
                >
                  <.icon name="hero-arrow-path" class="size-4" />
                </button>
            <% end %>
          </div>
          <label for={@uploads.background.ref} class="btn btn-sm">
            <.icon name="hero-arrow-up-tray" class="size-4" /> Upload…
          </label>
          <.live_file_input upload={@uploads.background} class="sr-only" />
          <button
            :if={@theme.background}
            id="remove-background"
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="remove_background"
          >
            Remove
          </button>
          <span
            :for={entry <- @uploads.background.entries}
            :if={!entry.done?}
            class="text-xs opacity-70"
          >
            {entry.progress}%
          </span>
        </div>
        <p :for={err <- upload_errors(@uploads.background)} class="text-xs text-error">
          {upload_error(err)}
        </p>
        <p :if={!@obs?} class="text-xs opacity-70">
          <.link navigate={~p"/obs"} class="link">Connect to OBS</.link> to use one of its scenes.
        </p>

        <label
          :if={@theme.background}
          class="flex cursor-pointer items-center gap-2 text-sm"
          title="Leave this off when the OBS scene has its own background under the slides."
        >
          <input
            type="checkbox"
            name="in_player"
            value="true"
            checked={@theme.background_in_player}
            class="checkbox checkbox-xs"
            phx-click="set_in_player"
            phx-value-in_player={to_string(!@theme.background_in_player)}
          /> Also show it in OBS, behind the slides
        </label>
      </div>
    </form>
    """
  end

  defp upload_error(:not_accepted), do: "use a PNG, JPEG or WebP image"
  defp upload_error(:too_large), do: "that image is too large"
  defp upload_error(err), do: to_string(err)
end
