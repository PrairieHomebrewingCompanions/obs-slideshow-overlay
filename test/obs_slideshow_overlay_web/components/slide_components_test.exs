defmodule ObsSlideshowOverlayWeb.SlideComponentsTest do
  use ExUnit.Case, async: true

  alias ObsSlideshowOverlay.Library.Slide
  import ObsSlideshowOverlayWeb.SlideComponents, only: [pages: 1]

  defp list(count, detail \\ nil, max \\ nil, columns \\ nil) do
    body =
      Enum.map_join(1..count, "\n", fn i ->
        if detail, do: "Name #{i} | #{detail}", else: "Name #{i}"
      end)

    %Slide{type: :names, body: body, max_per_page: max, columns: columns}
  end

  defp sizes(slide), do: slide |> pages() |> Enum.map(&length/1)

  test "a list that fits is one page" do
    assert sizes(list(30, "Helper")) == [30]
    assert sizes(list(36)) == [36]
  end

  test "longer lists split evenly, by what reads well with or without details" do
    assert sizes(list(45, "Helper")) == [23, 22]
    assert sizes(list(37)) == [19, 18]
    assert sizes(list(61, "Helper")) == [21, 20, 20]
  end

  test "the list can set its own page size" do
    assert sizes(list(20, nil, 8)) == [7, 7, 6]
  end

  test "an empty list is still one (empty) page" do
    assert pages(%Slide{type: :names, body: ""}) == [[]]
  end

  test "fewer columns hold fewer names per page; more hold more" do
    assert sizes(list(31, nil, nil, 2)) == [16, 15]
    assert sizes(list(31, nil, nil, 1)) == [11, 10, 10]
    assert sizes(list(45, "Helper", nil, 5)) == [45]
  end
end
