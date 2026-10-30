defmodule ObsSlideshowOverlay.Library.TextStyle do
  @moduledoc """
  How one piece of a theme's text looks: the title, a list's names,
  details and footer, or a text slide's heading and body.

  `size` is in pixels, except for list names and details, which are sized
  to fit their list: there it's a percentage of that size.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :font, :string
    field :size, :integer
    field :weight, Ecto.Enum, values: [:normal, :bold], default: :normal
    field :italic, :boolean, default: false
    field :color, :string, default: "#FFFFFF"
    field :shadow, Ecto.Enum, values: [:none, :soft, :hard], default: :soft
    field :letter_spacing, :integer, default: 0
    field :uppercase, :boolean, default: false
  end

  @fields [:font, :size, :weight, :italic, :color, :shadow, :letter_spacing, :uppercase]

  def changeset(style, attrs) do
    style
    |> cast(attrs, @fields)
    |> validate_required([:font, :size, :color])
    # Font names go into CSS, so keep them to what a family name can hold.
    |> validate_format(:font, ~r/^[\w .\-]+$/u,
      message: "letters, numbers, spaces, dots and dashes"
    )
    |> validate_format(:color, ~r/^#[0-9a-fA-F]{6}$/)
    |> validate_number(:size, greater_than: 0, less_than_or_equal_to: 400)
    |> validate_number(:letter_spacing, greater_than_or_equal_to: -20, less_than_or_equal_to: 60)
  end

  # CSS's own families, which every computer has, unquoted (quoted, they'd
  # name a font called "serif").
  @generic ~w(serif sans-serif monospace cursive fantasy system-ui ui-serif
              ui-sans-serif ui-monospace ui-rounded math emoji fangsong)

  @doc "Whether a font name is one of CSS's generic families."
  def generic?(font), do: font in @generic

  @doc "The CSS for this style at `px` pixels (inline, for slides)."
  def css(%__MODULE__{} = style, px) do
    [
      "font-family: #{family(style.font)};",
      "font-size: #{px};",
      "font-weight: #{if style.weight == :bold, do: 700, else: 400};",
      "font-style: #{if style.italic, do: "italic", else: "normal"};",
      "color: #{style.color};",
      "letter-spacing: #{style.letter_spacing}px;",
      if(style.uppercase, do: "text-transform: uppercase;"),
      shadow(style.shadow)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp family(font), do: if(generic?(font), do: font, else: "'#{font}'")

  defp shadow(:none), do: "text-shadow: none;"
  defp shadow(:soft), do: "text-shadow: 0 3px 8px rgba(0, 0, 0, 0.8);"
  defp shadow(:hard), do: "text-shadow: 4px 4px 0 #000;"
end
