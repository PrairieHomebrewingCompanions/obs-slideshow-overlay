# Adds existing files to a slideshow from the command line, for bringing a
# folder of logos or photos in at once. (Dragging files onto the gallery
# does the same.) Creates the slideshow if it doesn't exist.
#
#     mix run priv/import.exs "Sponsors" images ~/event/logos/*
#     mix run priv/import.exs "Intermission" images --title "Highlights" ~/event/photos/*.jpg
#     mix run priv/import.exs "Sponsors" names "Thank You to Our Volunteers" volunteers.txt [footer]
#
# Image file names can carry tags before the extension: 14-acme.card.png
# (or .framed, .cutout; .full and .clear also work, as older names for them)
# sets the style, .fill or .contained the size, and .trim trims the edges.
# A names file has one "Name | detail" per line.

alias ObsSlideshowOverlay.Library
alias ObsSlideshowOverlay.Library.{Slide, Slideshow}

{name, args} =
  case System.argv() do
    [name | args] when args != [] -> {name, args}
    _ -> raise "usage: see the top of priv/import.exs"
  end

slideshow =
  Library.get_slideshow(Slideshow.slugify(name)) ||
    elem(Library.create_slideshow(%{name: name}), 1)

tags = fn path ->
  [_name | tags] = path |> Path.basename() |> Path.rootname() |> String.split(".")
  tags
end

case args do
  ["images" | rest] ->
    {opts, files} = OptionParser.parse!(rest, strict: [title: :string])

    for file <- Enum.sort(files) do
      case Library.add_images(slideshow, [{file, Path.basename(file)}]) do
        {[slide], []} ->
          t = tags.(file)
          # .full and .clear are older names for framed and cut-out.
          style =
            cond do
              Enum.any?(~w(framed full), &(&1 in t)) -> "framed"
              Enum.any?(~w(cutout clear), &(&1 in t)) -> "cutout"
              "card" in t -> "card"
              true -> "auto"
            end

          size = Enum.find(~w(fill contained), "auto", &(&1 in t))

          {:ok, slide} =
            Library.update_slide(slide, %{
              style: style,
              size: size,
              trim: "trim" in t,
              title: opts[:title]
            })

          IO.puts("#{Path.basename(file)}: #{Slide.style(slide)}, #{Slide.size(slide)}")

        {[], [{f, reason}]} ->
          IO.puts(:stderr, "#{f}: #{reason}")
      end
    end

  ["names", title, file | footer] ->
    {:ok, _} =
      Library.add_slide(slideshow, %{
        type: :names,
        name: title,
        title: title,
        body: File.read!(file),
        footer: List.first(footer)
      })

  _ ->
    raise "usage: see the top of priv/import.exs"
end
