defmodule ObsSlideshowOverlay.GoogleFonts do
  @moduledoc """
  Google Fonts, as more fonts for themes. Picking one downloads its files
  into the data folder (`dir/0`), where ObsSlideshowOverlay.Fonts finds them like any
  installed font: the show never needs the internet, and a copied data
  folder takes its fonts along. Google Fonts are openly licensed, so
  keeping copies is fine.

  The catalogue of families is fetched from Google and kept for a week (and
  used as it is when Google can't be reached).
  """

  alias ObsSlideshowOverlay.Media

  @catalogue_url "https://fonts.google.com/metadata/fonts"
  @css_url "https://fonts.googleapis.com/css2"
  @catalogue_max_age 7 * 24 * 60 * 60

  @doc "Where downloaded fonts are kept."
  def dir, do: Path.join(Media.dir(), "fonts")

  @doc "The families Google has, as `[%{family: ..., category: ...}]`."
  def catalogue do
    with {:ok, data} <- catalogue_data() do
      fonts =
        for %{"family" => family} = font <- data["familyMetadataList"] || [],
            do: %{family: family, category: font["category"]}

      {:ok, fonts}
    end
  end

  @doc """
  Downloads a family's files, every weight and style, unless it's here
  already. Tells pages to reload their fonts when it's done.
  """
  def install(family) do
    with {:ok, data} <- catalogue_data(),
         %{} = font <- Enum.find(data["familyMetadataList"] || [], &(&1["family"] == family)) do
      if installed?(family), do: :ok, else: download(family, Map.keys(font["fonts"] || %{}))
    else
      nil -> {:error, "Google Fonts has no #{family}"}
      error -> error
    end
  end

  def installed?(family), do: File.dir?(family_dir(family))

  defp download(family, variants) do
    params = [family: "#{family}:ital,wght@#{axes(variants)}"]

    with {:ok, %{status: 200, body: css}} <- get(@css_url, params: params),
         files = font_files(css),
         true <- files != [] || {:error, "Google Fonts sent no files for #{family}"},
         {:ok, fonts} <- fetch_all(files) do
      tmp = family_dir(family) <> ".part"
      File.rm_rf!(tmp)
      File.mkdir_p!(tmp)
      for {name, data} <- fonts, do: File.write!(Path.join(tmp, name), data)
      File.rename!(tmp, family_dir(family))
      Phoenix.PubSub.broadcast(ObsSlideshowOverlay.PubSub, "fonts", {:fonts, :changed})
      :ok
    else
      {:ok, %{status: status}} -> {:error, "Google Fonts answered #{status}"}
      {:error, %{__exception__: true} = e} -> {:error, Exception.message(e)}
      {:error, reason} -> {:error, reason}
    end
  end

  # "400", "700i", ... as css2 wants them: "0,400;0,700;1,700", in order.
  defp axes(variants) do
    variants
    |> Enum.map(fn v ->
      {weight, italic} = Integer.parse(v)
      {if(italic == "i", do: 1, else: 0), weight}
    end)
    |> Enum.sort()
    |> Enum.map_join(";", fn {ital, weight} -> "#{ital},#{weight}" end)
  end

  # Each @font-face's file, named for its weight and style.
  defp font_files(css) do
    for block <- String.split(css, "@font-face"),
        [_, url] <- [Regex.run(~r/src:\s*url\(([^)]+)\)/, block)],
        [_, weight] <- [Regex.run(~r/font-weight:\s*(\d+)/, block)] do
      italic = if block =~ ~r/font-style:\s*italic/, do: "i", else: ""
      {"#{weight}#{italic}#{Path.extname(URI.parse(url).path)}", url}
    end
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp fetch_all(files) do
    Enum.reduce_while(files, {:ok, []}, fn {name, url}, {:ok, done} ->
      case get(url) do
        {:ok, %{status: 200, body: data}} -> {:cont, {:ok, [{name, data} | done]}}
        {:ok, %{status: status}} -> {:halt, {:error, "Google Fonts answered #{status}"}}
        error -> {:halt, error}
      end
    end)
  end

  defp family_dir(family),
    do: Path.join(dir(), String.replace(family, ~r/[^A-Za-z0-9]+/, "-"))

  defp catalogue_data do
    path = Path.join(Media.dir(), "google-fonts.json")

    if fresh?(path) do
      {:ok, path |> File.read!() |> Jason.decode!()}
    else
      case get(@catalogue_url) do
        {:ok, %{status: 200, body: body}} ->
          # It starts with ")]}'" to stop it being run as a script.
          json = body |> to_string() |> String.replace_prefix(")]}'", "")
          data = Jason.decode!(json)
          File.write!(path, json)
          {:ok, data}

        _ ->
          if File.exists?(path),
            do: {:ok, path |> File.read!() |> Jason.decode!()},
            else: {:error, "couldn't reach Google Fonts"}
      end
    end
  end

  defp fresh?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime < @catalogue_max_age
      _ -> false
    end
  end

  # Google sends plain TrueType files to clients that aren't browsers.
  defp get(url, opts \\ []) do
    [url: url, decode_body: false, retry: false, receive_timeout: 30_000]
    |> Keyword.merge(opts)
    |> Keyword.merge(Application.get_env(:obs_slideshow_overlay, :google_fonts_req, []))
    |> Req.get()
  end
end
