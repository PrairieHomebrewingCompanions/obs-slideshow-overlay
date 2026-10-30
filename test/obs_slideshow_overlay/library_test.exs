defmodule ObsSlideshowOverlay.LibraryTest do
  use ObsSlideshowOverlay.DataCase, async: false

  alias ObsSlideshowOverlay.{Library, Media}
  alias ObsSlideshowOverlay.Library.Slide
  import ObsSlideshowOverlay.Fixtures

  test "a slideshow's address follows its name" do
    slideshow = slideshow("Sponsors + Photos!")
    assert slideshow.slug == "sponsors-photos"

    {:ok, renamed} = Library.update_slideshow(slideshow, %{name: "Preshow"})
    assert renamed.slug == "preshow"
  end

  test "images get a style and size from their pixels, and a name from their file" do
    slideshow = slideshow()

    files = [
      {png(:solid), "01-acme-brewing.png"},
      {png(:light), "02-big-hops.trim.png"},
      {png(:dark), "03_night_malt.png"}
    ]

    {slides, []} = Library.add_images(slideshow, files)

    assert Enum.map(slides, &Slide.style/1) == [:framed, :cutout, :card]
    assert Enum.map(slides, &Slide.size/1) == [:fill, :contained, :contained]
    # Only images with transparency need PNG.
    assert Enum.map(slides, &Path.extname(&1.image)) == [".jpg", ".png", ".png"]
    assert Enum.map(slides, & &1.name) == ["Acme Brewing", "Big Hops", "Night Malt"]
    assert Enum.all?(slides, &File.exists?(Media.path(&1.image)))

    items = Library.get_slideshow(slideshow.slug).items
    assert Enum.map(items, & &1.slide_id) == Enum.map(slides, & &1.id)
  end

  test "an unreadable file is reported, not added" do
    slideshow = slideshow()
    bad = Path.join(System.tmp_dir!(), "not-an-image.png")
    File.write!(bad, "nope")

    assert {[], [{"not-an-image.png", _reason}]} =
             Library.add_images(slideshow, [{bad, "not-an-image.png"}])

    assert Library.get_slideshow(slideshow.slug).items == []
  end

  test "reordering, timing and skipping items" do
    slideshow = slideshow()

    {slides, []} =
      Library.add_images(slideshow, for(_ <- 1..3, do: {png(:solid), "x.png"}))

    [a, b, c] = Library.get_slideshow(slideshow.slug).items

    Library.reorder(slideshow, [c.id, a.id, b.id])
    Library.update_items([c.id], %{"seconds" => "12", "skipped" => "true"})

    items = Library.get_slideshow(slideshow.slug).items
    assert Enum.map(items, & &1.id) == [c.id, a.id, b.id]
    assert {hd(items).seconds, hd(items).skipped} == {12, true}

    Library.update_items([c.id], %{"seconds" => ""})
    assert hd(Library.get_slideshow(slideshow.slug).items).seconds == nil
    assert length(slides) == 3
  end

  test "a slide can be in several slideshows; removing keeps it, deleting doesn't" do
    sponsors = slideshow("Sponsors")
    photos = slideshow("Photos")
    {[slide], []} = Library.add_images(sponsors, [{png(:solid), "acme.png"}])

    assert [%{id: id}] = Library.slides_not_in(photos)
    Library.add_to_slideshow(photos, [id])
    assert Library.slides_not_in(photos) == []

    [item] = Library.get_slideshow("photos").items
    Library.remove_items([item.id])
    assert Library.get_slideshow("photos").items == []
    assert [_] = Library.get_slideshow("sponsors").items

    Library.delete_slides([slide.id])
    assert Library.get_slideshow("sponsors").items == []
    refute File.exists?(Media.path(slide.image))
  end

  test "changes are broadcast" do
    Library.subscribe()
    slideshow()
    assert_receive {:library, :changed}
  end
end
