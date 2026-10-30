defmodule ObsSlideshowOverlay.Library.Slideshow do
  @moduledoc """
  A named, ordered set of slides that plays in an OBS browser source at
  `/play/<id>`, which stays the same when it's renamed. (The slug names it
  in the gallery's address.)
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "slideshows" do
    field :name, :string
    field :slug, :string
    field :slide_seconds, :integer, default: 6
    field :fade_ms, :integer, default: 800
    # The title for slides that don't set their own.
    field :default_title, :string
    # Blank uses the default theme (see ObsSlideshowOverlay.Library.theme_for/1).
    belongs_to :theme, ObsSlideshowOverlay.Library.Theme
    # What "Set up in OBS" made for it (see ObsSlideshowOverlay.Obs.set_up/3)
    field :obs_scene, :string
    field :obs_input, :string
    field :obs_base, :string

    has_many :items, ObsSlideshowOverlay.Library.Item, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def changeset(slideshow, attrs) do
    slideshow
    |> cast(attrs, [:name, :slide_seconds, :fade_ms, :default_title, :theme_id])
    |> validate_required([:name])
    |> validate_number(:slide_seconds, greater_than: 0, less_than_or_equal_to: 600)
    |> validate_number(:fade_ms, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000)
    |> put_slug()
    |> unique_constraint(:slug, message: "another slideshow has a name too close to this one")
  end

  # The slug is the OBS browser source's address, so it follows the name.
  defp put_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, slugify(name))
    end
  end

  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "slideshow"
      slug -> slug
    end
  end
end
