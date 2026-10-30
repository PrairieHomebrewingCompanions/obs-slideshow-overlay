defmodule ObsSlideshowOverlay.Library.Item do
  @moduledoc """
  A slide's place in a slideshow: its position, how long it stays on screen
  (`seconds`, or the slideshow's `slide_seconds` when blank), whether it's
  skipped, and whether it's pinned in place when the slideshow is
  auto-arranged.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "items" do
    belongs_to :slideshow, ObsSlideshowOverlay.Library.Slideshow
    belongs_to :slide, ObsSlideshowOverlay.Library.Slide
    field :position, :integer
    field :seconds, :integer
    field :skipped, :boolean, default: false
    field :pinned, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:seconds, :skipped, :pinned])
    |> validate_number(:seconds, greater_than: 0, less_than_or_equal_to: 600)
  end
end
