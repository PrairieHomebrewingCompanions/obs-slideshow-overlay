defmodule ObsSlideshowOverlay.Library.Theme do
  @moduledoc """
  A slideshow's look: a style for each piece of text (see
  ObsSlideshowOverlay.Library.TextStyle), where the title and content sit, and a background
  image for the previews (and, optionally, OBS). Fonts are font families by
  name: installed ones, downloaded Google Fonts, or the generic families
  every computer has (`system-ui`, `serif`, ...), which the defaults use.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ObsSlideshowOverlay.Library.TextStyle

  # Each piece of text, and how it looks until the theme says otherwise: a
  # plain look in fonts every computer has, to make your own from.
  @defaults %{
    title_style: %TextStyle{font: "system-ui", size: 72, weight: :bold},
    name_style: %TextStyle{font: "system-ui", size: 100},
    detail_style: %TextStyle{font: "system-ui", size: 100, color: "#C8CDD8"},
    footer_style: %TextStyle{font: "system-ui", size: 34, italic: true, color: "#C8CDD8"},
    heading_style: %TextStyle{font: "system-ui", size: 96, weight: :bold},
    body_style: %TextStyle{font: "system-ui", size: 52}
  }

  schema "themes" do
    field :name, :string, default: "Default"
    # The title runs along the bottom, below the content.
    field :title_x, :integer, default: 120
    field :title_baseline, :integer, default: 990
    # Longer titles shrink to fit this width.
    field :title_width, :integer, default: 1680
    # Where each slide's content goes, in slide pixels (see content_area/1).
    field :content_x, :integer, default: 120
    field :content_y, :integer, default: 80
    field :content_width, :integer, default: 1680
    field :content_height, :integer, default: 800

    for {name, _default} <- @defaults do
      embeds_one name, TextStyle, on_replace: :update
    end

    field :background, :string
    # Where it came from: an OBS scene, or an uploaded file's name.
    field :background_scene, :string
    field :background_upload, :string
    field :background_in_player, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc "The text styles, in the order the Themes page shows them."
  def styles,
    do: [:title_style, :name_style, :detail_style, :footer_style, :heading_style, :body_style]

  @doc "A theme's style for a piece of text, or the default if it has none."
  def style(%__MODULE__{} = theme, name), do: Map.get(theme, name) || Map.fetch!(@defaults, name)

  @doc "A theme with every style filled in, so the form has something to show."
  def with_defaults(%__MODULE__{} = theme) do
    Enum.reduce(styles(), theme, fn name, theme -> Map.put(theme, name, style(theme, name)) end)
  end

  @content_fields [:content_x, :content_y, :content_width, :content_height]

  # Contained images keep this share of the area's width and height free
  # around them, split evenly.
  @contained_margin {180 / 1680, 80 / 720}

  @doc """
  Where a slide's content goes, as `{x, y, width, height}` in slide pixels:
  the area images fill, and name lists and text are laid out in.
  """
  def content_area(theme) do
    defaults = %__MODULE__{}

    {Map.get(theme, :content_x) || defaults.content_x,
     Map.get(theme, :content_y) || defaults.content_y,
     Map.get(theme, :content_width) || defaults.content_width,
     Map.get(theme, :content_height) || defaults.content_height}
  end

  @doc "The smaller area, inside the content area, that contained images (logos) fit."
  def contained_area(theme) do
    {x, y, w, h} = content_area(theme)
    {mx, my} = @contained_margin
    {dx, dy} = {round(w * mx / 2), round(h * my / 2)}
    {x + dx, y + dy, w - 2 * dx, h - 2 * dy}
  end

  def changeset(theme, attrs) do
    theme
    |> with_defaults()
    |> cast(attrs, [
      :name,
      :title_x,
      :title_baseline,
      :title_width,
      :background_in_player | @content_fields
    ])
    |> validate_required([:name, :title_x, :title_baseline, :title_width | @content_fields])
    |> validate_number(:title_width, greater_than_or_equal_to: 100)
    |> validate_on_slide(:title_x, :title_width, 1920)
    |> validate_number(:title_x, greater_than_or_equal_to: 0, less_than: 1920)
    |> validate_number(:title_baseline, greater_than: 0, less_than_or_equal_to: 1080)
    |> validate_number(:content_x, greater_than_or_equal_to: 0)
    |> validate_number(:content_y, greater_than_or_equal_to: 0)
    |> validate_number(:content_width, greater_than_or_equal_to: 100)
    |> validate_number(:content_height, greater_than_or_equal_to: 100)
    |> validate_on_slide(:content_x, :content_width, 1920)
    |> validate_on_slide(:content_y, :content_height, 1080)
    |> cast_styles()
  end

  defp validate_on_slide(changeset, start, length, limit) do
    with a when is_integer(a) <- get_field(changeset, start),
         b when is_integer(b) <- get_field(changeset, length),
         true <- a + b > limit do
      add_error(changeset, length, "runs off the slide (#{limit}px)")
    else
      _ -> changeset
    end
  end

  defp cast_styles(changeset) do
    Enum.reduce(styles(), changeset, fn name, changeset ->
      cast_embed(changeset, name, with: &TextStyle.changeset/2)
    end)
  end
end
