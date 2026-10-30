defmodule ObsSlideshowOverlayWeb.NamesEditorComponent do
  @moduledoc """
  The editor for a name list slide: one row per person (name and detail),
  added, removed, dragged into order, sorted, pasted in from a spreadsheet or
  imported from a CSV file, with a live preview of the slide. Every change
  saves.

  The rows live here while it's open, so a half-typed row isn't lost when
  the save comes back as a library update.
  """
  use ObsSlideshowOverlayWeb, :live_component

  alias ObsSlideshowOverlay.{Csv, Library}
  import ObsSlideshowOverlayWeb.SlideComponents

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(pasting: false, page: 0, csv: nil)
     |> allow_upload(:csv,
       accept: ~w(.csv),
       max_entries: 1,
       max_file_size: 5_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:rows],
        do: socket,
        else:
          assign(socket,
            rows: Enum.map(names(assigns.slide.body), &row/1),
            footer: assigns.slide.footer || "",
            max_per_page: assigns.slide.max_per_page,
            columns: assigns.slide.columns
          )

    {:ok, socket}
  end

  defp row({name, detail}, new \\ false),
    do: %{key: System.unique_integer([:positive]), name: name, detail: detail || "", new: new}

  @impl true
  def handle_event("change", params, socket) do
    rows =
      socket.assigns.rows
      |> Enum.with_index()
      |> Enum.map(fn {row, i} ->
        case params["rows"]["#{i}"] do
          %{"name" => name, "detail" => detail} -> %{row | name: name, detail: detail}
          _ -> row
        end
      end)

    max_per_page = number(params["max_per_page"], 120)
    columns = number(params["columns"], 6)

    {:noreply,
     socket
     |> assign(rows: rows, footer: params["footer"] || "")
     |> assign(max_per_page: max_per_page, columns: columns)
     |> save()}
  end

  def handle_event("add", _params, socket) do
    {:noreply, assign(socket, rows: socket.assigns.rows ++ [row({"", ""}, true)])}
  end

  def handle_event("remove", %{"key" => key}, socket) do
    rows = Enum.reject(socket.assigns.rows, &("#{&1.key}" == key))
    {:noreply, socket |> assign(rows: rows) |> save()}
  end

  def handle_event("move", %{"from" => from, "to" => to}, socket) do
    {row, rows} = List.pop_at(socket.assigns.rows, from)
    {:noreply, socket |> assign(rows: List.insert_at(rows, to, row)) |> save()}
  end

  def handle_event("sort", %{"by" => by}, socket) do
    key =
      case by do
        "first" -> &String.downcase(&1.name)
        "last" -> &(&1.name |> String.split() |> List.last("") |> String.downcase())
      end

    {:noreply, socket |> assign(rows: Enum.sort_by(socket.assigns.rows, key)) |> save()}
  end

  def handle_event("page", %{"by" => by}, socket) do
    count = length(pages(socket.assigns.slide))
    page = Integer.mod(socket.assigns.page + String.to_integer(by), count)
    {:noreply, assign(socket, page: page)}
  end

  def handle_event("toggle_paste", _params, socket),
    do: {:noreply, assign(socket, pasting: !socket.assigns.pasting)}

  def handle_event("paste", %{"text" => text, "mode" => mode}, socket) do
    pasted = text |> String.split(~r/\R/) |> Enum.flat_map(&parse_line/1) |> Enum.map(&row/1)
    rows = if mode == "append", do: socket.assigns.rows ++ pasted, else: pasted
    {:noreply, socket |> assign(rows: rows, pasting: false) |> save()}
  end

  def handle_event("validate_csv", _params, socket), do: {:noreply, socket}

  # Picking which of the CSV's columns make the names and details.
  def handle_event("csv_columns", params, socket) do
    {:noreply, assign(socket, csv: csv_choice(socket.assigns.csv, params))}
  end

  def handle_event("csv_import", %{"mode" => mode} = params, socket) do
    %{file: file, names: names, details: details, headers?: headers?} =
      csv_choice(socket.assigns.csv, params)

    imported = file |> Csv.entries(names, details, headers?) |> Enum.map(&row/1)
    rows = if mode == "append", do: socket.assigns.rows ++ imported, else: imported
    {:noreply, socket |> assign(rows: rows, csv: nil) |> save()}
  end

  def handle_event("csv_cancel", _params, socket), do: {:noreply, assign(socket, csv: nil)}

  def handle_event("close", _params, socket) do
    send(self(), {:close_names_editor})
    {:noreply, socket}
  end

  # A whole number from `min` (1 unless given) to `max`, or nil (blank: use
  # the default).
  defp number(value, max, min \\ 1) do
    case Integer.parse(value || "") do
      {n, _} when n >= min and n <= max -> n
      _ -> nil
    end
  end

  # A spreadsheet's columns arrive tab-separated; typed lists use "|".
  defp parse_line(line) do
    parts =
      if String.contains?(line, "\t"),
        do: String.split(line, "\t", parts: 2),
        else: String.split(line, "|", parts: 2)

    case Enum.map(parts, &String.trim/1) do
      [""] -> []
      ["", _] -> []
      [name] -> [{name, ""}]
      [name, detail] -> [{name, detail}]
    end
  end

  # A CSV file is read, but nothing is imported until its columns are picked.
  defp handle_progress(:csv, entry, socket) when entry.done? do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Csv.parse(File.read!(path))}
      end)

    case result do
      {:ok, file} ->
        choice = %{file: file, names: Csv.guess_name_columns(file), details: [], headers?: true}
        {:noreply, assign(socket, csv: choice, pasting: false, import_error: nil)}

      {:error, message} ->
        {:noreply, assign(socket, import_error: message)}
    end
  end

  defp handle_progress(:csv, _entry, socket), do: {:noreply, socket}

  defp csv_choice(choice, params) do
    columns = fn key ->
      params |> Map.get(key, []) |> Enum.flat_map(&List.wrap(number(&1, 999, 0)))
    end

    %{
      choice
      | names: columns.("names"),
        details: columns.("details"),
        headers?: params["headers"] == "true"
    }
  end

  # Blank rows are kept while editing, but not saved.
  defp save(socket) do
    body =
      socket.assigns.rows
      |> Enum.reject(&(String.trim(&1.name) == ""))
      |> Enum.map_join("\n", fn
        %{name: name, detail: ""} -> String.trim(name)
        %{name: name, detail: detail} -> "#{String.trim(name)} | #{String.trim(detail)}"
      end)

    {:ok, slide} =
      Library.update_slide(socket.assigns.slide, %{
        body: body,
        footer: socket.assigns.footer,
        max_per_page: socket.assigns.max_per_page,
        columns: socket.assigns.columns
      })

    # The list may now have fewer pages than the one being previewed.
    page = min(socket.assigns.page, length(pages(slide)) - 1)
    assign(socket, slide: slide, page: page, import_error: nil)
  end

  @impl true
  def render(assigns) do
    named = Enum.count(assigns.rows, &(String.trim(&1.name) != ""))
    pages = pages(assigns.slide)

    assigns =
      assign(assigns,
        named: named,
        pages: length(pages),
        column_count: ObsSlideshowOverlay.Library.Slide.columns(assigns.slide),
        per_column:
          ceil(
            length(Enum.at(pages, 0, [])) /
              ObsSlideshowOverlay.Library.Slide.columns(assigns.slide)
          ),
        auto_per_page: default_per_page(assigns.slide),
        preview: %{assigns.slide | footer: assigns.footer},
        import_error: assigns[:import_error]
      )

    ~H"""
    <div
      id={@id}
      class="fixed inset-0 z-40 flex items-center justify-center bg-black/60 p-6"
      phx-window-keydown="close"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div class="flex max-h-full w-full max-w-7xl flex-col overflow-hidden rounded-box bg-base-100 shadow-xl">
        <div class="flex items-center gap-3 border-b border-base-300 px-5 py-3">
          <h2 class="text-lg font-semibold">{@slide.name || "Name list"}</h2>
          <span id="names-count" class="badge badge-ghost">
            {@named} {if @named == 1, do: "name", else: "names"}
            <span :if={@named > 0 and @pages == 1}>
              · {@column_count} {if @column_count == 1, do: "column", else: "columns"} of {@per_column}
            </span>
            <span :if={@pages > 1}>· {@pages} pages</span>
          </span>
          <button
            class="btn btn-sm btn-ghost ml-auto"
            phx-click="close"
            phx-target={@myself}
            aria-label="Close"
          >
            Done <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="grid min-h-0 flex-1 gap-6 overflow-hidden p-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
          <div class="flex min-h-0 flex-col gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <button class="btn btn-sm btn-primary" phx-click="add" phx-target={@myself}>
                <.icon name="hero-plus" class="size-4" /> Add name
              </button>
              <div class="dropdown">
                <div tabindex="0" role="button" class="btn btn-sm">
                  <.icon name="hero-bars-arrow-down" class="size-4" /> Sort
                </div>
                <ul
                  tabindex="0"
                  class="menu dropdown-content z-10 w-48 rounded-box bg-base-200 p-2 shadow"
                >
                  <li>
                    <button phx-click="sort" phx-value-by="first" phx-target={@myself}>
                      A–Z by first name
                    </button>
                  </li>
                  <li>
                    <button phx-click="sort" phx-value-by="last" phx-target={@myself}>
                      A–Z by last name
                    </button>
                  </li>
                </ul>
              </div>
              <button
                class={["btn btn-sm", @pasting && "btn-active"]}
                phx-click="toggle_paste"
                phx-target={@myself}
              >
                <.icon name="hero-clipboard-document" class="size-4" /> Paste a list
              </button>
              <form id="csv-upload-form" phx-change="validate_csv" phx-target={@myself}>
                <label for={@uploads.csv.ref} class="btn btn-sm">
                  <.icon name="hero-arrow-up-tray" class="size-4" /> Import a CSV file
                </label>
                <.live_file_input upload={@uploads.csv} class="sr-only" />
              </form>
            </div>

            <p :if={@import_error} class="text-sm text-error">{@import_error}</p>
            <p :for={err <- upload_errors(@uploads.csv)} class="text-sm text-error">
              {if err == :not_accepted, do: "Choose a .csv file", else: to_string(err)}
            </p>

            <.csv_import :if={@csv} csv={@csv} myself={@myself} />

            <form
              :if={@pasting}
              id="paste-form"
              phx-submit="paste"
              phx-target={@myself}
              class="space-y-2 rounded-box bg-base-200 p-3"
            >
              <textarea
                name="text"
                rows="8"
                class="textarea w-full font-mono text-sm"
                placeholder="Paste from a spreadsheet (name, then detail column),&#10;or type one per line: Avery Chen | Stage Crew"
                phx-mounted={JS.focus()}
              ></textarea>
              <div class="flex gap-2">
                <button name="mode" value="replace" class="btn btn-sm btn-primary">
                  Replace the list
                </button>
                <button name="mode" value="append" class="btn btn-sm">Add to the list</button>
              </div>
            </form>

            <form
              id="names-form"
              phx-change="change"
              phx-target={@myself}
              class="flex min-h-0 flex-1 flex-col gap-3"
            >
              <div class="min-h-0 flex-1 overflow-y-auto rounded-box border border-base-300">
                <div class="grid grid-cols-[1.5rem_1fr_1fr_2rem] items-center gap-2 border-b border-base-300 bg-base-200 px-2 py-1 text-xs font-semibold opacity-70">
                  <span></span><span>Name</span><span>Detail (optional: rank, role…)</span><span></span>
                </div>
                <p :if={@rows == []} class="p-6 text-center text-sm opacity-60">
                  No names yet. Add one, paste a list, or import a CSV file.
                </p>
                <div id="name-rows" phx-hook="NameRows" phx-target={@myself}>
                  <div
                    :for={{row, i} <- Enum.with_index(@rows)}
                    id={"name-row-#{row.key}"}
                    class="grid grid-cols-[1.5rem_1fr_1fr_2rem] items-center gap-2 border-b border-base-300 px-2 py-1 last:border-b-0"
                  >
                    <span
                      class="row-handle cursor-grab opacity-40 hover:opacity-80"
                      title="Drag to reorder"
                    >
                      <.icon name="hero-bars-2" class="size-4" />
                    </span>
                    <input
                      type="text"
                      name={"rows[#{i}][name]"}
                      value={row.name}
                      placeholder="Name"
                      class="input input-sm w-full"
                      phx-debounce="300"
                      phx-mounted={row.new && JS.focus()}
                    />
                    <input
                      type="text"
                      name={"rows[#{i}][detail]"}
                      value={row.detail}
                      placeholder="Detail"
                      class="input input-sm w-full italic"
                      phx-debounce="300"
                    />
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs btn-square"
                      phx-click="remove"
                      phx-value-key={row.key}
                      phx-target={@myself}
                      aria-label={"Remove #{row.name}"}
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                </div>
              </div>
              <div class="grid grid-cols-[1fr_7rem_10rem] gap-3">
                <label class="text-sm">
                  <span class="mb-1 block opacity-70">Footer line (optional)</span>
                  <input
                    type="text"
                    name="footer"
                    value={@footer}
                    placeholder="None (e.g. And thank you to everyone who helped!)"
                    class="input input-sm w-full"
                    phx-debounce="300"
                  />
                </label>
                <label class="text-sm">
                  <span class="mb-1 block opacity-70">Columns</span>
                  <input
                    type="number"
                    name="columns"
                    value={@columns}
                    min="1"
                    max="6"
                    placeholder="3"
                    class="input input-sm w-full"
                    phx-debounce="300"
                  />
                </label>
                <label class="text-sm">
                  <span class="mb-1 block opacity-70">Max names per page</span>
                  <input
                    type="number"
                    name="max_per_page"
                    value={@max_per_page}
                    min="1"
                    max="120"
                    placeholder={"Auto (#{@auto_per_page})"}
                    class="input input-sm w-full"
                    phx-debounce="300"
                  />
                </label>
              </div>
            </form>
          </div>

          <div class="min-h-0 overflow-y-auto">
            <div
              id="names-preview"
              phx-hook="Settle"
              class="slide-frame relative overflow-hidden rounded-md"
              style="width: 100%; aspect-ratio: 16 / 9;"
            >
              <div style="position: absolute; left: 0; top: 0; width: 1920px; height: 1080px; transform-origin: 0 0; transform: scale(var(--preview-scale, 0.3));">
                <.backdrop theme={@theme} hideable />
                <.slide slide={@preview} theme={@theme} page={@page} />
              </div>
            </div>
            <div :if={@pages > 1} id="names-pages" class="mt-2 flex items-center gap-2 text-sm">
              <button
                class="btn btn-xs btn-square"
                phx-click="page"
                phx-value-by="-1"
                phx-target={@myself}
                aria-label="Previous page"
              >
                <.icon name="hero-chevron-left" class="size-3" />
              </button>
              <span class="tabular-nums">Page {@page + 1} of {@pages}</span>
              <button
                class="btn btn-xs btn-square"
                phx-click="page"
                phx-value-by="1"
                phx-target={@myself}
                aria-label="Next page"
              >
                <.icon name="hero-chevron-right" class="size-3" />
              </button>
              <span class="opacity-60">Each page plays for the slide's full time.</span>
            </div>
            <p class="mt-2 text-xs opacity-60">
              Saves as you type. Names shrink to fit when they're long, and a list too long for
              one page is split evenly across pages.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :csv, :map, required: true
  attr :myself, :any, required: true

  # Which columns make the names and details, with what they'd import.
  defp csv_import(assigns) do
    %{file: file, names: names, details: details, headers?: headers?} = assigns.csv
    entries = Csv.entries(file, names, details, headers?)
    sample = if headers?, do: Enum.at(file.rows, 0, []), else: file.headers

    assigns =
      assign(assigns,
        columns: Enum.with_index(file.headers),
        sample: sample,
        count: length(entries),
        preview: Enum.take(entries, 3)
      )

    ~H"""
    <form
      id="csv-form"
      phx-change="csv_columns"
      phx-submit="csv_import"
      phx-target={@myself}
      class="space-y-3 rounded-box bg-base-200 p-3"
    >
      <div class="flex items-center gap-2">
        <h3 class="font-semibold">Import a CSV file</h3>
        <label class="ml-auto flex cursor-pointer items-center gap-2 text-sm">
          <input type="hidden" name="headers" value="false" />
          <input
            type="checkbox"
            name="headers"
            value="true"
            checked={@csv.headers?}
            class="checkbox checkbox-xs"
          /> First row is column names
        </label>
      </div>
      <p class="text-xs opacity-70">
        Tick the columns that make each name (first and last name together, say) and any to show
        beneath it. Nothing else in the file is kept.
      </p>
      <div class="max-h-56 overflow-y-auto rounded-box border border-base-300 bg-base-100">
        <div class="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_3.5rem_3.5rem] gap-2 border-b border-base-300 px-3 py-1 text-xs font-semibold opacity-70">
          <span>Column</span><span>First row</span><span>Name</span><span>Detail</span>
        </div>
        <div
          :for={{header, i} <- @columns}
          id={"csv-column-#{i}"}
          class="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_3.5rem_3.5rem] items-center gap-2 px-3 py-1 text-sm"
        >
          <span class="truncate font-medium">
            {if @csv.headers? and header != "", do: header, else: "Column #{i + 1}"}
          </span>
          <span class="truncate opacity-60">{Enum.at(@sample, i, "")}</span>
          <input
            type="checkbox"
            name="names[]"
            value={i}
            checked={i in @csv.names}
            aria-label="Name"
            class="checkbox checkbox-sm"
          />
          <input
            type="checkbox"
            name="details[]"
            value={i}
            checked={i in @csv.details}
            aria-label="Detail"
            class="checkbox checkbox-sm"
          />
        </div>
      </div>
      <div id="csv-preview" class="text-sm">
        <span class="font-medium">{@count} {if @count == 1, do: "name", else: "names"}</span>
        <span :if={@preview != []} class="opacity-70">
          : {Enum.map_join(@preview, ", ", fn
            {name, ""} -> name
            {name, detail} -> "#{name} (#{detail})"
          end)}{if @count > 3, do: ", …"}
        </span>
      </div>
      <div class="flex gap-2">
        <button name="mode" value="replace" class="btn btn-sm btn-primary" disabled={@count == 0}>
          Replace the list
        </button>
        <button name="mode" value="append" class="btn btn-sm" disabled={@count == 0}>
          Add to the list
        </button>
        <button type="button" class="btn btn-sm btn-ghost" phx-click="csv_cancel" phx-target={@myself}>
          Cancel
        </button>
      </div>
    </form>
    """
  end
end
