defmodule ObsSlideshowOverlay.Fixtures do
  @moduledoc "Test images, drawn on the fly."

  alias ObsSlideshowOverlay.Library

  @doc """
  Writes a 400x200 PNG and returns its path:

    * `:solid` - an opaque image with its own background (framed)
    * `:light` - light shapes on transparency (cut-out)
    * `:dark` - dark shapes on transparency (white card)
  """
  def png(kind, name \\ nil) do
    dir = Path.join(System.tmp_dir!(), "slides-fixtures")
    File.mkdir_p!(dir)
    path = Path.join(dir, name || "#{kind}-#{System.unique_integer([:positive])}.png")

    image =
      case kind do
        :solid ->
          Image.new!(400, 200, color: [200, 30, 40])

        shade when shade in [:light, :dark] ->
          v = if shade == :light, do: 240, else: 20

          Image.new!(400, 200, color: [0, 0, 0, 0])
          |> Image.Draw.rect!(100, 50, 200, 100, color: [v, v, v, 255])
      end

    Image.write!(image, path)
    path
  end

  def slideshow(name \\ "Sponsors") do
    {:ok, slideshow} = Library.create_slideshow(%{name: name})
    slideshow
  end

  @doc """
  Writes a minimal font file to `dir`: just the tables ObsSlideshowOverlay.Fonts reads (a
  family name, and a weight and italics), which is all a test needs.
  """
  def font(dir, file, family, weight \\ 400, italic \\ false) do
    utf16 = :unicode.characters_to_binary(family, :utf8, {:utf16, :big})

    name =
      <<0::16, 1::16, 18::16, 3::16, 1::16, 0x409::16, 1::16, byte_size(utf16)::16, 0::16>> <>
        utf16

    selection = if italic, do: 1, else: 0
    os2 = <<4::16, 500::16, weight::16, 0::size(56 * 8), selection::16>>

    tables = [{"OS/2", os2}, {"name", name}]
    start = 12 + 16 * length(tables)

    {records, _} =
      Enum.map_reduce(tables, start, fn {tag, data}, at ->
        {<<tag::binary, 0::32, at::32, byte_size(data)::32>>, at + byte_size(data)}
      end)

    path = Path.join(dir, file)
    File.mkdir_p!(Path.dirname(path))
    data = Enum.map(tables, &elem(&1, 1))
    File.write!(path, [<<0x00010000::32, length(tables)::16, 0::48>>, records, data])
    path
  end
end
