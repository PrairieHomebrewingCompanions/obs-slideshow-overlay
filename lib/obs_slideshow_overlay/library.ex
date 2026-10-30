defmodule ObsSlideshowOverlay.Library do
  @moduledoc """
  Slides and the slideshows they play in.

  Every change is broadcast on `"library"` as `{:library, :changed}`, so the
  gallery and any open players (OBS browser sources) update straight away.
  """
  import Ecto.Query

  alias ObsSlideshowOverlay.{Media, Repo}
  alias ObsSlideshowOverlay.Library.{Item, Slide, Slideshow, Theme}

  @topic "library"

  def subscribe, do: Phoenix.PubSub.subscribe(ObsSlideshowOverlay.PubSub, @topic)

  defp changed(result) do
    Phoenix.PubSub.broadcast(ObsSlideshowOverlay.PubSub, @topic, {:library, :changed})
    result
  end

  ## Slideshows

  def list_slideshows,
    do: Repo.all(from s in Slideshow, order_by: [asc: s.inserted_at, asc: s.id])

  @doc "A slideshow by slug, with its items and their slides in order, or nil."
  def get_slideshow(slug) do
    Slideshow
    |> Repo.get_by(slug: slug)
    |> Repo.preload(items: :slide)
  end

  @doc "A slideshow by id, with its items and their slides in order, or nil."
  def get_slideshow_by_id(id) do
    Slideshow
    |> Repo.get(id)
    |> Repo.preload(items: :slide)
  end

  def create_slideshow(attrs) do
    %Slideshow{} |> Slideshow.changeset(attrs) |> Repo.insert() |> changed()
  end

  def update_slideshow(%Slideshow{} = slideshow, attrs) do
    slideshow |> Slideshow.changeset(attrs) |> Repo.update() |> changed()
  end

  def change_slideshow(%Slideshow{} = slideshow, attrs \\ %{}),
    do: Slideshow.changeset(slideshow, attrs)

  @doc "Deletes a slideshow. Its slides stay in the library."
  def delete_slideshow(%Slideshow{} = slideshow), do: slideshow |> Repo.delete() |> changed()

  ## Themes

  @doc """
  The default theme, the first made: slideshows without a theme use it.
  It's created the first time it's asked for.
  """
  def default_theme do
    Repo.one(from t in Theme, order_by: [asc: t.id], limit: 1) || Repo.insert!(%Theme{})
  end

  @doc "Every theme, the default first."
  def list_themes do
    default_theme()
    Repo.all(from t in Theme, order_by: [asc: t.id])
  end

  def get_theme(id), do: Repo.get(Theme, id)

  @doc "The theme a slideshow plays in: its own, or the default."
  def theme_for(%Slideshow{theme_id: id}) when is_integer(id),
    do: get_theme(id) || default_theme()

  def theme_for(%Slideshow{}), do: default_theme()

  @doc "The slideshows each theme is used by, as `%{theme_id => [slideshow]}`."
  def theme_usage do
    default_id = default_theme().id
    Enum.group_by(list_slideshows(), &(&1.theme_id || default_id))
  end

  @doc """
  A new theme, starting as a copy of `from` (with its own copy of the
  background, so either can change it).
  """
  def create_theme(%Theme{} = from, name) do
    fields = Map.take(from, Theme.__schema__(:fields) -- [:id, :inserted_at, :updated_at])

    background =
      if from.background do
        copy =
          String.replace(
            from.background,
            ~r/^[^.]+/,
            Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
          )

        File.cp!(Media.path(from.background), Media.path(copy))
        copy
      end

    struct(Theme, %{fields | name: name, background: background})
    |> Repo.insert()
    |> changed()
  end

  @doc "Deletes a theme; its slideshows go back to the default. The last one stays."
  def delete_theme(%Theme{} = theme) do
    if Repo.aggregate(Theme, :count) <= 1 do
      {:error, "the last theme can't be deleted"}
    else
      with {:ok, theme} <- Repo.delete(theme) do
        Media.delete(theme.background)
        changed({:ok, theme})
      end
    end
  end

  def change_theme(%Theme{} = theme, attrs \\ %{}), do: Theme.changeset(theme, attrs)

  def update_theme(%Theme{} = theme, attrs) do
    theme |> Theme.changeset(attrs) |> Repo.update() |> changed()
  end

  @doc """
  Stores an image as the theme's background, replacing any old one. `source`
  says where it came from: `{:obs, scene}` or `{:upload, file_name}`.
  """
  def set_theme_background(%Theme{} = theme, path, source) do
    {scene, upload} =
      case source do
        {:obs, scene} -> {scene, nil}
        {:upload, name} -> {nil, name}
      end

    with {:ok, %{image: name}} <- Media.store(path, :background) do
      Media.delete(theme.background)

      theme
      |> Ecto.Changeset.change(
        background: name,
        background_scene: scene,
        background_upload: upload
      )
      |> Repo.update()
      |> changed()
    end
  end

  def remove_theme_background(%Theme{} = theme) do
    Media.delete(theme.background)

    theme
    |> Ecto.Changeset.change(background: nil, background_scene: nil, background_upload: nil)
    |> Repo.update()
    |> changed()
  end

  ## Slides

  @doc """
  Stores uploaded images as new image slides at the end of the slideshow.
  `files` is a list of `{path, client_name}`; returns `{added, errors}`,
  errors as `{client_name, reason}`.
  """
  def add_images(%Slideshow{} = slideshow, files) do
    results =
      Enum.map(files, fn {path, client_name} ->
        with {:ok, info} <- Media.store(path, :image) do
          attrs = Map.merge(info, %{type: :image, name: default_name(client_name)})
          slide = attrs |> Slide.create_changeset() |> Repo.insert!()
          {:ok, slide}
        else
          {:error, reason} -> {:error, {client_name, reason}}
        end
      end)

    slides = for {:ok, slide} <- results, do: slide
    append(slideshow, Enum.map(slides, & &1.id))
    changed({slides, for({:error, error} <- results, do: error)})
  end

  # "07-acme-coffee-roasters.trim.png" -> "Acme Coffee Roasters", as a
  # starting point for the image's name.
  defp default_name(client_name) do
    client_name
    |> String.split(".")
    |> hd()
    |> String.replace(~r/^\d+[-_ ]*/, "")
    |> String.replace(~r/[-_]+/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc "Creates a slide without an image (a name list or text slide) at the end of the slideshow."
  def add_slide(%Slideshow{} = slideshow, attrs) do
    with {:ok, slide} <- attrs |> Slide.create_changeset() |> Repo.insert() do
      append(slideshow, [slide.id])
      changed({:ok, slide})
    end
  end

  def change_slide(%Slide{} = slide, attrs \\ %{}), do: Slide.changeset(slide, attrs)

  def update_slide(%Slide{} = slide, attrs) do
    slide |> Slide.changeset(attrs) |> Repo.update() |> changed()
  end

  @doc "Applies the same changes to several slides, e.g. a style to a selection of images."
  def update_slides(ids, attrs) do
    Repo.transact(fn ->
      for slide <- Repo.all(from s in Slide, where: s.id in ^ids) do
        Repo.update(Slide.changeset(slide, attrs))
      end

      {:ok, length(ids)}
    end)
    |> changed()
  end

  @doc "Deletes slides from the library and every slideshow, with their images."
  def delete_slides(ids) do
    slides = Repo.all(from s in Slide, where: s.id in ^ids)
    Repo.delete_all(from s in Slide, where: s.id in ^ids)
    Enum.each(slides, &Media.delete(&1.image))
    changed(:ok)
  end

  @doc "Every slide in the library, oldest first."
  def list_slides, do: Repo.all(from s in Slide, order_by: [asc: s.id])

  @doc "Library slides that aren't in the slideshow, newest first."
  def slides_not_in(%Slideshow{id: id}) do
    in_show = from i in Item, where: i.slideshow_id == ^id, select: i.slide_id
    Repo.all(from s in Slide, where: s.id not in subquery(in_show), order_by: [desc: s.id])
  end

  ## Items: slides' places in a slideshow

  @doc "Adds library slides to the end of a slideshow."
  def add_to_slideshow(%Slideshow{} = slideshow, slide_ids) do
    append(slideshow, slide_ids)
    changed(:ok)
  end

  defp append(%Slideshow{id: id}, slide_ids) do
    last = Repo.one(from i in Item, where: i.slideshow_id == ^id, select: max(i.position)) || 0

    already =
      MapSet.new(Repo.all(from i in Item, where: i.slideshow_id == ^id, select: i.slide_id))

    now = DateTime.utc_now(:second)

    rows =
      slide_ids
      |> Enum.reject(&MapSet.member?(already, &1))
      |> Enum.uniq()
      |> Enum.with_index(last + 1)
      |> Enum.map(fn {slide_id, position} ->
        %{
          slideshow_id: id,
          slide_id: slide_id,
          position: position,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Item, rows)
  end

  @doc "Puts a slideshow's items in the given order (item ids, first to last)."
  def reorder(%Slideshow{id: id}, item_ids) do
    Repo.transact(fn ->
      item_ids
      |> Enum.with_index(1)
      |> Enum.each(fn {item_id, position} ->
        Repo.update_all(from(i in Item, where: i.id == ^item_id and i.slideshow_id == ^id),
          set: [position: position]
        )
      end)

      {:ok, :ok}
    end)
    |> changed()
  end

  @doc "Changes seconds, skipped or pinned on several items at once."
  def update_items(ids, attrs) do
    Repo.transact(fn ->
      # Invalid values (say, 0 seconds) leave an item as it was.
      for item <- Repo.all(from i in Item, where: i.id in ^ids) do
        Repo.update(Item.changeset(item, attrs))
      end

      {:ok, length(ids)}
    end)
    |> changed()
  end

  @doc "Takes items out of their slideshow; the slides stay in the library."
  def remove_items(ids) do
    Repo.delete_all(from i in Item, where: i.id in ^ids)
    changed(:ok)
  end
end
