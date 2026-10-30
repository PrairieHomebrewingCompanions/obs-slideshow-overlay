defmodule ObsSlideshowOverlay.Library.Slide do
  @moduledoc """
  One slide in the library. A slide can appear in any number of slideshows.

  Types:

    * `:image` - a logo, photo or any other picture, with `name` labelling it
      in the gallery. `style` is `:auto` (use `auto_style`, read from the
      pixels), `:framed` (a rounded rectangle with a shadow), `:cutout`
      (transparent, straight on the background) or `:card` (on a white
      card). `size` is `:fill` (as large as the slide allows), `:contained`
      (logo-sized, with room around it) or `:auto` (framed images fill, the
      rest are contained). `trim` cuts 3px off each edge, for images cut from
      a scan or PDF with a stray border.
    * `:names` - a list of names in columns, each with an optional detail
      line (`body`, one "Name | detail" per line) and an optional `footer`.
      It uses `columns` columns (blank is three), and a list longer than
      `max_per_page` plays as several pages.
    * `:text` - a `heading` and `body`.

  `title` is the slide's title; when blank, the slideshow's `default_title`
  is used.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types [:image, :names, :text]
  @styles [:auto, :framed, :cutout, :card]
  @sizes [:auto, :fill, :contained]

  schema "slides" do
    field :type, Ecto.Enum, values: @types
    field :name, :string
    field :title, :string
    field :image, :string
    field :width, :integer
    field :height, :integer
    field :style, Ecto.Enum, values: @styles, default: :auto
    field :auto_style, Ecto.Enum, values: [:framed, :cutout, :card]
    field :size, Ecto.Enum, values: @sizes, default: :auto
    field :trim, :boolean, default: false
    field :heading, :string
    field :body, :string
    field :footer, :string
    field :max_per_page, :integer
    field :columns, :integer

    timestamps(type: :utc_datetime)
  end

  def types, do: @types
  def styles, do: @styles
  def sizes, do: @sizes

  @doc "Changes made by editing a slide."
  def changeset(slide, attrs) do
    slide
    |> cast(attrs, changeset_fields())
    |> validate_number(:max_per_page, greater_than: 0, less_than_or_equal_to: 120)
    |> validate_number(:columns, greater_than: 0, less_than_or_equal_to: 6)
  end

  @doc "A new slide, including the fields set when an image is stored."
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:type, :image, :width, :height, :auto_style | changeset_fields()])
    |> validate_required([:type])
  end

  defp changeset_fields,
    do: [:name, :title, :style, :size, :trim, :heading, :body, :footer, :max_per_page, :columns]

  @doc "How many columns a name list uses."
  def columns(%__MODULE__{columns: columns}) when is_integer(columns), do: columns
  def columns(%__MODULE__{}), do: 3

  @doc "The style an image is drawn in, after `:auto` is resolved."
  def style(%__MODULE__{style: :auto, auto_style: auto}), do: auto || :cutout
  def style(%__MODULE__{style: style}), do: style

  @doc "How much of the slide an image takes, after `:auto` is resolved."
  def size(%__MODULE__{size: size}) when size in [:fill, :contained], do: size
  def size(%__MODULE__{} = slide), do: if(style(slide) == :framed, do: :fill, else: :contained)
end
