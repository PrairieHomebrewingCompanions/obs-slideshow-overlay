defmodule ObsSlideshowOverlayWeb.SlideComponents do
  @moduledoc """
  Draws slides as 1920x1080 HTML, transparent around their content so they
  sit over whatever OBS puts underneath. The gallery's thumbnails and the
  OBS player use the same component, so what you see is what plays.

  Positions are in slide pixels. Three things are finished in the browser
  (assets/js/slides.js), because they depend on the fonts: a title longer
  than the theme's title width shrinks to fit it, the title is moved so its
  baseline sits on the theme's baseline, and name lists shrink until their
  columns fit.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  import ObsSlideshowOverlayWeb.CoreComponents, only: [icon: 1]
  alias ObsSlideshowOverlay.Library.{Slide, TextStyle, Theme}

  # Content goes in the theme's content area (Theme.content_area/1). Images
  # fill it, or are contained with room around them (contained_area/1);
  # lists and text keep this much clear inside it, {sides, top and bottom}.
  @list_padding {0, 30}
  @text_padding {40, 30}
  # A list with a footer ends this far above the padded area's bottom, and
  # the footer starts this far above it.
  @footer_room 70
  @footer_top 52
  # Upscaling small images further than this blurs them.
  @max_upscale 2.2
  @card_pad 56
  @trim 3

  attr :theme, :map, required: true
  attr :hideable, :boolean, default: false, doc: "hidden by the backdrop toggle"

  @doc """
  What goes behind a slide in a preview, at slide size: the theme's
  background image, or without one a plain dark stand-in.
  """
  def backdrop(%{theme: %{background: background}} = assigns) when is_binary(background) do
    ~H"""
    <img
      class={@hideable && "slide-backdrop"}
      src={"/media/#{@theme.background}"}
      draggable="false"
      style="position: absolute; left: 0; top: 0; width: 1920px; height: 1080px; max-width: none; object-fit: cover;"
    />
    """
  end

  def backdrop(assigns) do
    ~H"""
    <div
      class={@hideable && "slide-backdrop"}
      style="position: absolute; left: 0; top: 0; width: 1920px; height: 1080px; background: radial-gradient(circle at 50% 35%, #3b4252, #15171d 75%);"
    />
    """
  end

  attr :id, :string, required: true

  @doc """
  Shows or hides the background behind previews (`hideable` backdrops), so
  only what this app draws is left, over a checkerboard. It's a preference
  of this browser, kept across pages (see assets/js/app.js).
  """
  def backdrop_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class="btn btn-sm btn-square"
      phx-click={JS.dispatch("slides:toggle-backdrop")}
    >
      <span class="backdrop-on" title="Background shown: click to hide it">
        <.icon name="hero-eye" class="size-4" />
        <span class="sr-only">Hide background</span>
      </span>
      <span class="backdrop-off" title="Background hidden: click to show it">
        <.icon name="hero-eye-slash" class="size-4" />
        <span class="sr-only">Show background</span>
      </span>
    </button>
    """
  end

  attr :slide, Slide, required: true
  attr :theme, :map, required: true
  attr :default_title, :string, default: nil, doc: "for slides without their own"
  attr :page, :integer, default: 0, doc: "which page of a long name list"
  attr :rest, :global

  def slide(assigns) do
    assigns = assign(assigns, :title, title(assigns.slide, assigns.default_title))

    ~H"""
    <div
      style="position: relative; width: 1920px; height: 1080px; overflow: hidden;"
      {@rest}
    >
      <.content slide={@slide} theme={@theme} page={@page} />
      <div
        :if={@title}
        data-style="title_style"
        data-baseline={@theme.title_baseline}
        data-max-width={@theme.title_width}
        style={[
          "position: absolute; white-space: nowrap; line-height: 1;",
          "left: #{@theme.title_x}px; top: #{@theme.title_baseline - style(@theme, :title_style).size}px;",
          css(@theme, :title_style, style(@theme, :title_style).size)
        ]}
      >
        {@title}
      </div>
    </div>
    """
  end

  defp title(%Slide{title: title}, _default) when title not in [nil, ""], do: title
  defp title(_slide, default) when default not in [nil, ""], do: default
  defp title(_slide, _default), do: nil

  attr :slide, Slide, required: true
  attr :theme, :map, required: true
  attr :page, :integer, default: 0

  defp content(%{slide: %Slide{type: :image, image: image}} = assigns) when is_binary(image) do
    slide = assigns.slide
    style = Slide.style(slide)
    size = Slide.size(slide)
    {w, h} = trimmed_size(slide)

    area =
      if size == :fill,
        do: Theme.content_area(assigns.theme),
        else: Theme.contained_area(assigns.theme)

    area = if style == :card, do: inset(area, @card_pad), else: area

    # A filling image is as large as the slide allows; a contained one stops
    # before small logos blur.
    {x, y, dw, dh} = fit({w, h}, area, if(size == :fill, do: :infinity, else: @max_upscale))
    scale = dw / w

    radius =
      cond do
        style != :framed -> 0
        size == :fill -> 24
        true -> min(dw, dh) * 0.05
      end

    assigns =
      assign(assigns, style: style, x: x, y: y, w: dw, h: dh, scale: scale, radius: radius)

    ~H"""
    <div
      :if={@style == :card}
      style={[
        "position: absolute; background: #fff; border-radius: 22px;",
        "box-shadow: 0 12px 34px rgba(0, 0, 0, 0.55);",
        box_style(@x - 56, @y - 56, @w + 112, @h + 112)
      ]}
    />
    <div style={[
      "position: absolute; border-radius: #{@radius}px;",
      box_style(@x, @y, @w, @h),
      shadow(@style)
    ]}>
      <div style={[
        "position: relative; overflow: hidden; width: 100%; height: 100%;",
        "border-radius: #{@radius}px;"
      ]}>
        <.trimmed_image slide={@slide} scale={@scale} />
      </div>
    </div>
    """
  end

  defp content(%{slide: %Slide{type: :names}} = assigns) do
    entries = assigns.slide |> pages() |> Enum.at(assigns.page, [])
    footer = present(assigns.slide.footer)
    {x, y, w, h} = assigns.theme |> Theme.content_area() |> inset(@list_padding)
    {top, bottom} = {y, if(footer, do: y + h - @footer_room, else: y + h)}
    columns = Slide.columns(assigns.slide)
    rows = max(ceil(length(entries) / columns), 1)
    # A list of plain names (a list of sponsors, say) has no detail lines to make room
    # for, so its names fill their rows.
    details? = Enum.any?(entries, fn {_name, detail} -> detail end)
    pitch = min((bottom - top) / rows, if(details?, do: 120, else: 80))
    name_size = round(pitch * if(details?, do: 0.5, else: 0.72))

    assigns =
      assign(assigns,
        entries: entries,
        footer: footer,
        left: x,
        width: w,
        footer_top: y + h - @footer_top,
        top: top,
        height: bottom - top,
        rows: rows,
        pitch: pitch,
        name_size: name_size
      )

    ~H"""
    <div
      data-fit
      style={[
        "position: absolute; left: #{@left}px; width: #{@width}px; display: grid;",
        "grid-auto-flow: column; justify-content: space-evenly; align-content: center;",
        "grid-template-rows: repeat(#{@rows}, #{@pitch}px); column-gap: 60px;",
        "top: #{@top}px; height: #{@height}px;"
      ]}
    >
      <div :for={{name, detail} <- @entries} style="white-space: nowrap; line-height: 1.15;">
        <div
          data-style="name_style"
          style={css(@theme, :name_style, fitted(@name_size, style(@theme, :name_style).size))}
        >
          {name}
        </div>
        <div
          :if={detail}
          data-style="detail_style"
          style={css(@theme, :detail_style, fitted(@pitch * 0.34, style(@theme, :detail_style).size))}
        >
          {detail}
        </div>
      </div>
    </div>
    <div
      :if={@footer}
      data-style="footer_style"
      style={[
        "position: absolute; text-align: center;",
        "left: #{@left}px; width: #{@width}px; top: #{@footer_top}px;",
        css(@theme, :footer_style, style(@theme, :footer_style).size)
      ]}
    >
      {@footer}
    </div>
    """
  end

  defp content(%{slide: %Slide{type: :text}} = assigns) do
    {x, y, w, h} = assigns.theme |> Theme.content_area() |> inset(@text_padding)
    assigns = assign(assigns, box: box_style(x, y, w, h))

    ~H"""
    <div style={[
      "position: absolute;",
      @box,
      "display: flex; flex-direction: column; justify-content: center; gap: 36px;",
      "text-align: center;"
    ]}>
      <div
        :if={present(@slide.heading)}
        data-style="heading_style"
        style={["line-height: 1.1;", css(@theme, :heading_style, style(@theme, :heading_style).size)]}
      >
        {@slide.heading}
      </div>
      <div
        :if={present(@slide.body)}
        data-style="body_style"
        style={[
          "line-height: 1.3; white-space: pre-line;",
          css(@theme, :body_style, style(@theme, :body_style).size)
        ]}
      >
        {@slide.body}
      </div>
    </div>
    """
  end

  defp content(assigns), do: ~H""

  attr :slide, Slide, required: true
  attr :scale, :float, required: true

  # The whole image, scaled, and shifted so a trimmed edge falls outside the
  # clipping box around it.
  defp trimmed_image(assigns) do
    t = if assigns.slide.trim, do: @trim * assigns.scale, else: 0
    assigns = assign(assigns, t: t)

    ~H"""
    <img
      src={"/media/#{@slide.image}"}
      draggable="false"
      style={[
        "position: absolute; max-width: none; left: #{-@t}px; top: #{-@t}px;",
        "width: #{@slide.width * @scale}px; height: #{@slide.height * @scale}px;"
      ]}
    />
    """
  end

  defp shadow(:cutout), do: "filter: drop-shadow(0 12px 12px rgba(0, 0, 0, 0.55));"
  defp shadow(_style), do: "box-shadow: 0 12px 34px rgba(0, 0, 0, 0.55);"

  defp trimmed_size(%Slide{width: w, height: h, trim: true}), do: {w - 2 * @trim, h - 2 * @trim}
  defp trimmed_size(%Slide{width: w, height: h}), do: {w, h}

  defp inset(box, {px, py}), do: inset(box, px, py)
  defp inset(box, pad), do: inset(box, pad, pad)
  defp inset({x, y, w, h}, px, py), do: {x + px, y + py, w - 2 * px, h - 2 * py}

  # Scales {w, h} to fit the box, centred, at whole-pixel positions.
  defp fit({w, h}, {bx, by, bw, bh}, max_upscale) do
    scale = Enum.min([bw / w, bh / h, max_upscale])
    {dw, dh} = {round(w * scale), round(h * scale)}
    {round(bx + (bw - dw) / 2), round(by + (bh - dh) / 2), dw, dh}
  end

  defp box_style(x, y, w, h), do: "left: #{x}px; top: #{y}px; width: #{w}px; height: #{h}px;"

  # Names per column when a list doesn't set its page size: as many as still
  # read from the back of a room.
  @per_column_with_details 10
  @per_column_plain 12

  @doc """
  A name list's entries split into pages: as many as it takes to keep each
  under the list's `max_per_page` (or a size that reads well), as even as
  possible (45 names make pages of 23 and 22, not 30 and 15). Always at least
  one page.
  """
  def pages(%Slide{type: :names} = slide) do
    entries = names(slide.body)
    max = slide.max_per_page || default_per_page(slide)
    count = max(ceil(length(entries) / max), 1)
    # Spread the remainder over the first pages: 31 makes 11, 10 and 10.
    {base, extra} = {div(length(entries), count), rem(length(entries), count)}

    {pages, []} =
      Enum.map_reduce(0..(count - 1), entries, fn page, rest ->
        Enum.split(rest, base + if(page < extra, do: 1, else: 0))
      end)

    pages
  end

  def pages(_slide), do: [nil]

  @doc "How many names a page holds when the list doesn't say."
  def default_per_page(%Slide{} = slide) do
    per_column =
      if Enum.any?(names(slide.body), fn {_name, detail} -> detail end),
        do: @per_column_with_details,
        else: @per_column_plain

    Slide.columns(slide) * per_column
  end

  defp style(theme, name), do: Theme.style(theme, name)

  # CSS for a piece of text: a size in pixels, or a CSS size expression.
  defp css(theme, name, px) when is_number(px), do: css(theme, name, "#{px}px")
  defp css(theme, name, size), do: TextStyle.css(style(theme, name), size)

  # A list's names and details are sized to fit, then scaled by the theme's
  # percentage, then shrunk further if their columns are still too wide.
  defp fitted(auto, percent), do: "calc(var(--fit, 1) * #{round(auto * percent / 100)}px)"

  @doc "A name list's lines: one \"Name | detail\" per line."
  def names(nil), do: []

  def names(body) do
    for line <- String.split(body, "\n"), line = String.trim(line), line != "" do
      case String.split(line, "|", parts: 2) do
        [name, detail] -> {String.trim(name), present(String.trim(detail))}
        [name] -> {name, nil}
      end
    end
  end

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value
end
