defmodule ObsSlideshowOverlay.Media do
  @moduledoc """
  The show's image files: storing uploads and reading what the slides need
  from them.

  Uploads are turned the right way up and stripped of camera metadata
  (including GPS location), and kept up to 3000px so a logo's small print
  stays sharp. Images with transparency stay PNG; the rest become JPEG.
  Files are stored under `dir/0` with generated names; slides refer to them
  by name.
  """

  alias Vix.Vips.Operation

  @image_max 3000
  @background_max 3840

  @doc "Where the database and images live (see config/runtime.exs)."
  def dir, do: Application.fetch_env!(:obs_slideshow_overlay, :data_dir)

  def images_dir, do: Path.join(dir(), "images")

  def path(name), do: Path.join(images_dir(), name)

  @doc """
  Stores an uploaded image for a slide or a theme's background. Returns the
  stored file's name, its size and, for slides, the style its pixels
  suggest.
  """
  def store(source, kind) when kind in [:image, :background] do
    with {:ok, image} <- Image.open(source),
         {:ok, {image, _}} <- Image.autorotate(image),
         {:ok, image} <- Image.thumbnail(image, max_size(kind), resize: :down),
         {:ok, image} <- Image.to_colorspace(image, :srgb) do
      # Without transparency, JPEG keeps them small.
      {image, ext} =
        if not Image.has_alpha?(image),
          do: {flatten(image), ".jpg"},
          else: {image, ".png"}

      name = random_name() <> ext
      File.mkdir_p!(images_dir())

      with {:ok, _} <- Image.write(image, path(name), quality: 90, strip_metadata: true) do
        {:ok,
         %{
           image: name,
           width: Image.width(image),
           height: Image.height(image),
           auto_style: if(kind == :image, do: auto_style(image))
         }}
      end
    end
    |> case do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  def delete(nil), do: :ok

  def delete(name) do
    _ = File.rm(path(name))
    :ok
  end

  defp max_size(:image), do: @image_max
  defp max_size(:background), do: @background_max

  defp flatten(image) do
    if Image.has_alpha?(image), do: Image.flatten!(image, background_color: :white), else: image
  end

  defp random_name, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  defp describe(reason) do
    if inspect(reason) =~ "HEVC",
      do: "HEIC photos aren't supported; convert to JPEG first",
      else: "couldn't read the image"
  end

  @doc """
  The style an image's pixels suggest: one with its own background is
  framed; a transparent one is cut out, straight on the background, unless
  it's dark enough to vanish there, when it gets a white card.
  """
  def auto_style(image) do
    {clear, lum} = analyse(image)

    cond do
      clear <= 0.15 -> :framed
      lum < 0.4 -> :card
      true -> :cutout
    end
  end

  # The share of transparent pixels, and the mean luminance (0..1) of the
  # opaque ones.
  defp analyse(image) do
    if Image.has_alpha?(image) do
      {rgb, alpha} = Image.split_alpha(image)
      opaque = Operation.relational_const!(alpha, :VIPS_OPERATION_RELATIONAL_MOREEQ, [25.5])
      opaque_share = Operation.avg!(opaque) / 255

      lit =
        Operation.avg!(
          Operation.multiply!(luminance(rgb), Operation.linear!(opaque, [1 / 255], [0]))
        )

      {1 - opaque_share, if(opaque_share > 0, do: lit / opaque_share / 255, else: 0)}
    else
      {0.0, Operation.avg!(luminance(image)) / 255}
    end
  end

  defp luminance(rgb) do
    [r, g, b] = for band <- 0..2, do: Operation.extract_band!(rgb, band)

    Operation.add!(
      Operation.add!(Operation.linear!(r, [0.2126], [0]), Operation.linear!(g, [0.7152], [0])),
      Operation.linear!(b, [0.0722], [0])
    )
  end
end
