defmodule ObsSlideshowOverlay.Fonts do
  @moduledoc """
  The fonts on the computer running the app, so pages can use them in any
  browser. Safari only lets web pages use the fonts that come with macOS:
  serving the font files themselves (see ObsSlideshowOverlayWeb.FontController) means a
  theme's fonts show everywhere.

  Fonts are found in the usual font folders (or `:font_dirs` in the app's
  config), and among the Google Fonts downloaded (ObsSlideshowOverlay.GoogleFonts), and
  read for their family names and styles, which are kept until
  a file changes. The system's own fonts are listed but not served: every
  browser on that system already has them.
  """
  use Agent

  import Bitwise

  alias ObsSlideshowOverlay.Fonts.Face

  @extensions ~w(.ttf .otf .ttc .otc)

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Every font face found, system ones included."
  def faces do
    files = for {dir, system} <- dirs(), path <- files_in(dir), do: {path, system}
    known = Agent.get(__MODULE__, & &1)

    read =
      Map.new(files, fn {path, system} ->
        key = stat_key(path)

        case known do
          %{^path => {^key, faces}} -> {path, {key, faces}}
          _ -> {path, {key, read_faces(path, system)}}
        end
      end)

    Agent.update(__MODULE__, fn _ -> read end)
    read |> Map.values() |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort_by(&{&1.family, &1.weight})
  end

  @doc """
  The family names, for the Themes page's font menu. (macOS's own interface
  fonts, named with a leading dot, aren't for pages.)
  """
  def families do
    faces()
    |> Enum.map(& &1.family)
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
  end

  @doc "The faces a page can download: installed fonts, as single files."
  def servable, do: Enum.filter(faces(), &servable?/1)

  @doc "A servable face by its id, as used in its URL."
  def get(id), do: Enum.find(servable(), &(&1.id == id))

  defp servable?(%Face{system: system, path: path}),
    do: not system and String.downcase(Path.extname(path)) in ~w(.ttf .otf)

  defp dirs do
    installed =
      case Application.get_env(:obs_slideshow_overlay, :font_dirs) do
        nil -> default_dirs()
        dirs -> Enum.map(dirs, &{&1, false})
      end

    [{ObsSlideshowOverlay.GoogleFonts.dir(), false} | installed]
  end

  defp default_dirs do
    home = System.user_home!()

    case :os.type() do
      {:unix, :darwin} ->
        [
          {Path.join(home, "Library/Fonts"), false},
          {"/Library/Fonts", false},
          {"/System/Library/Fonts", true}
        ]

      {:win32, _} ->
        [
          {Path.join(System.get_env("LOCALAPPDATA", ""), "Microsoft/Windows/Fonts"), false},
          {Path.join(System.get_env("WINDIR", "C:/Windows"), "Fonts"), true}
        ]

      _ ->
        [
          {Path.join(home, ".local/share/fonts"), false},
          {Path.join(home, ".fonts"), false},
          {"/usr/local/share/fonts", false},
          {"/usr/share/fonts", true}
        ]
    end
  end

  defp files_in(dir) do
    Path.join(dir, "**/*")
    |> Path.wildcard()
    |> Enum.filter(&(String.downcase(Path.extname(&1)) in @extensions))
  end

  defp stat_key(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      _ -> nil
    end
  end

  ## Reading fonts (the OpenType spec's table directory, name and OS/2 tables)

  defp read_faces(path, system) do
    with {:ok, file} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        file
        |> font_offsets()
        |> Enum.with_index()
        |> Enum.flat_map(fn {offset, index} ->
          case read_face(file, offset) do
            {family, weight, italic} ->
              {weight, italic} = google_style(path, weight, italic)

              [
                %Face{
                  family: family,
                  weight: weight,
                  italic: italic,
                  path: path,
                  index: index,
                  system: system,
                  id: id(path, index)
                }
              ]

            nil ->
              []
          end
        end)
      rescue
        _ -> []
      after
        :file.close(file)
      end
    else
      _ -> []
    end
  end

  # A collection (.ttc) holds several fonts; anything else holds one.
  defp font_offsets(file) do
    case :file.pread(file, 0, 12) do
      {:ok, <<"ttcf", _version::32, count::32>>} ->
        {:ok, offsets} = :file.pread(file, 12, count * 4)
        for <<offset::32 <- offsets>>, do: offset

      {:ok, _} ->
        [0]
    end
  end

  defp read_face(file, offset) do
    {:ok, <<_sfnt::32, count::16, _::binary>>} = :file.pread(file, offset, 12)
    {:ok, records} = :file.pread(file, offset + 12, count * 16)

    tables =
      for <<tag::binary-4, _sum::32, at::32, length::32 <- records>>,
        into: %{},
        do: {tag, {at, length}}

    with {at, length} <- tables["name"],
         {:ok, name} <- :file.pread(file, at, length),
         family when is_binary(family) <- family(name) do
      {weight, italic} = style(file, tables["OS/2"])
      {family, weight, italic}
    else
      _ -> nil
    end
  end

  # The typographic family (name 16) groups a family's weights; older fonts
  # only have the basic one (name 1).
  defp family(<<_format::16, count::16, strings::16, rest::binary>> = table) do
    records =
      for <<platform::16, encoding::16, language::16, id::16, length::16,
            at::16 <- binary_part(rest, 0, count * 12)>>,
          id in [1, 16],
          do: {id, platform, encoding, language, binary_part(table, strings + at, length)}

    Enum.find_value([16, 1], fn wanted ->
      records
      |> Enum.filter(&(elem(&1, 0) == wanted))
      |> Enum.sort_by(fn {_, platform, _, language, _} -> {platform != 3, language != 0x409} end)
      |> Enum.find_value(&decode/1)
    end)
  end

  defp decode({_id, 3, _encoding, _language, utf16}),
    do: :unicode.characters_to_binary(utf16, {:utf16, :big}) |> clean()

  defp decode({_id, 0, _encoding, _language, utf16}),
    do: :unicode.characters_to_binary(utf16, {:utf16, :big}) |> clean()

  defp decode({_id, 1, 0, _language, latin}),
    do: :unicode.characters_to_binary(latin, :latin1) |> clean()

  defp decode(_record), do: nil

  defp clean(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      name -> name
    end
  end

  defp clean(_error), do: nil

  # Weight (100-900) and italics, from the OS/2 table.
  defp style(file, {at, length}) when length >= 64 do
    {:ok, <<_version::16, _avg::16, weight::16, _::binary-56, selection::16>>} =
      :file.pread(file, at, 64)

    {weight |> max(1) |> min(1000), (selection &&& 0b1000000001) != 0}
  end

  defp style(_file, _table), do: {400, false}

  # A downloaded Google Font's file is named for its weight and style
  # ("700i.ttf"), which is more exact than some fonts' own (thin weights
  # often all claim 250).
  defp google_style(path, weight, italic) do
    with true <- Path.dirname(Path.dirname(path)) == ObsSlideshowOverlay.GoogleFonts.dir(),
         [_, w, i] <- Regex.run(~r/\A(\d+)(i?)\./, Path.basename(path)) do
      {String.to_integer(w), i == "i"}
    else
      _ -> {weight, italic}
    end
  end

  defp id(path, index) do
    :crypto.hash(:sha256, "#{path}##{index}")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end
end
