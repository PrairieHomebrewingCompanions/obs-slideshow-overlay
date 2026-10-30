defmodule ObsSlideshowOverlayWeb.NamesEditorTest do
  use ObsSlideshowOverlayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ObsSlideshowOverlay.Fixtures

  alias ObsSlideshowOverlay.Library

  # A sign-up sheet's export: the names are split, and there's more in it
  # than belongs on a slide.
  @signups_csv """
  First Name,Last Name,Email,Role
  Avery,Chen,avery@example.com,Stage Crew
  Priya,Natarajan,priya@example.com,Registration
  ,,,
  Mina,Park,mina@example.com,
  """

  setup %{conn: conn} do
    s = slideshow()

    {:ok, slide} =
      Library.add_slide(s, %{
        type: :names,
        name: "Volunteers",
        body: "Avery Chen | Crew\nSam Abbott"
      })

    [item] = Library.get_slideshow("sponsors").items
    {:ok, view, _html} = live(conn, ~p"/s/sponsors")
    render_hook(view, "select", %{"ids" => ["#{item.id}"]})
    {:ok, view: view, slide: slide}
  end

  defp body(slide),
    do: ObsSlideshowOverlay.Repo.get!(ObsSlideshowOverlay.Library.Slide, slide.id).body

  defp open(view) do
    view |> element("#edit-names") |> render_click()
    assert has_element?(view, "#names-editor")
    view
  end

  test "the side panel sums up the list and opens the editor", %{view: view} do
    assert has_element?(view, "#names-summary", "2 names")
    open(view)
    assert has_element?(view, "#names-count", "2 names · 3 columns of 1")
    assert has_element?(view, "#names-preview", "Avery Chen")
  end

  test "rows are added, typed into, and removed", %{view: view, slide: slide} do
    open(view)
    view |> element("#names-editor button", "Add name") |> render_click()

    view
    |> form("#names-form", %{
      "rows" => %{
        "0" => %{"name" => "Avery Chen", "detail" => "Crew"},
        "1" => %{"name" => "Sam Abbott", "detail" => "Lead"},
        "2" => %{"name" => "Theo Martin", "detail" => ""}
      },
      "footer" => "Thanks!"
    })
    |> render_change()

    assert body(slide) == "Avery Chen | Crew\nSam Abbott | Lead\nTheo Martin"
    assert has_element?(view, "#names-preview", "Theo Martin")

    view |> element("#names-editor button[aria-label='Remove Sam Abbott']") |> render_click()
    assert body(slide) == "Avery Chen | Crew\nTheo Martin"
  end

  test "sorting by last name, and dragging a row", %{view: view, slide: slide} do
    open(view)
    view |> element("#names-editor button", "A–Z by last name") |> render_click()
    assert body(slide) == "Sam Abbott\nAvery Chen | Crew"

    view |> element("#name-rows") |> render_hook("move", %{"from" => 1, "to" => 0})
    assert body(slide) == "Avery Chen | Crew\nSam Abbott"
  end

  test "pasting from a spreadsheet replaces or adds to the list", %{view: view, slide: slide} do
    open(view)
    view |> element("#names-editor button", "Paste a list") |> render_click()

    view
    |> form("#paste-form", %{
      "text" => "Lena Fischer\tHospitality\n\nJordan Okafor | Speakers\n"
    })
    |> render_submit(%{"mode" => "append"})

    assert body(slide) ==
             "Avery Chen | Crew\nSam Abbott\nLena Fischer | Hospitality\nJordan Okafor | Speakers"
  end

  defp upload_csv(view, csv) do
    view
    |> file_input("#csv-upload-form", :csv, [%{name: "list.csv", content: csv, type: "text/csv"}])
    |> render_upload("list.csv")
  end

  test "a CSV file comes in from the columns picked, and nothing else", %{
    view: view,
    slide: slide
  } do
    open(view)
    upload_csv(view, @signups_csv)

    # First and Last are picked as the name to start with.
    assert has_element?(view, "#csv-preview", "3 names")
    assert has_element?(view, "#csv-preview", "Avery Chen")

    # Role as the detail.
    view
    |> form("#csv-form", %{"names" => ["0", "1"], "details" => ["3"], "headers" => "true"})
    |> render_change()

    assert has_element?(view, "#csv-preview", "Avery Chen (Stage Crew)")

    view
    |> form("#csv-form", %{"names" => ["0", "1"], "details" => ["3"], "headers" => "true"})
    |> render_submit(%{"mode" => "replace"})

    assert body(slide) == "Avery Chen | Stage Crew\nPriya Natarajan | Registration\nMina Park"
    refute body(slide) =~ "@"
    refute has_element?(view, "#csv-form")
  end

  test "a CSV file without column names can be added to the list", %{view: view, slide: slide} do
    open(view)
    upload_csv(view, "Lena Fischer,Hospitality\nJordan Okafor,Speakers\n")

    view
    |> form("#csv-form", %{"names" => ["0"], "details" => ["1"], "headers" => "false"})
    |> render_submit(%{"mode" => "append"})

    assert body(slide) ==
             "Avery Chen | Crew\nSam Abbott\nLena Fischer | Hospitality\nJordan Okafor | Speakers"
  end

  test "an empty file says so", %{view: view} do
    open(view)
    upload_csv(view, "\n\n")
    assert has_element?(view, "#names-editor", "That file is empty")
  end

  test "Done closes it", %{view: view} do
    open(view)
    view |> element("#names-editor button[aria-label='Close']") |> render_click()
    refute has_element?(view, "#names-editor")
  end

  test "a long list shows its pages, and can set its page size", %{view: view, slide: slide} do
    body = Enum.map_join(1..45, "\n", &"Name #{&1} | Helper")
    Library.update_slide(slide, %{body: body})
    assert has_element?(view, "#grid", "2 pages")

    open(view)
    assert has_element?(view, "#names-count", "45 names · 2 pages")
    assert has_element?(view, "#names-preview", "Name 1")
    refute has_element?(view, "#names-preview", "Name 24")

    view |> element("#names-pages button[aria-label='Next page']") |> render_click()
    assert has_element?(view, "#names-pages", "Page 2 of 2")
    assert has_element?(view, "#names-preview", "Name 24")

    rows = Map.new(0..44, &{"#{&1}", %{"name" => "Name #{&1 + 1}", "detail" => "Helper"}})
    view |> form("#names-form", %{"rows" => rows, "max_per_page" => "15"}) |> render_change()

    assert ObsSlideshowOverlay.Repo.get!(ObsSlideshowOverlay.Library.Slide, slide.id).max_per_page ==
             15

    assert has_element?(view, "#names-count", "45 names · 3 pages")
  end

  test "the number of columns can be set", %{view: view, slide: slide} do
    open(view)
    assert has_element?(view, "#names-count", "3 columns of 1")

    rows = %{
      "0" => %{"name" => "Avery Chen", "detail" => "Crew"},
      "1" => %{"name" => "Sam Abbott", "detail" => ""}
    }

    view |> form("#names-form", %{"rows" => rows, "columns" => "1"}) |> render_change()
    assert ObsSlideshowOverlay.Repo.get!(ObsSlideshowOverlay.Library.Slide, slide.id).columns == 1
    assert has_element?(view, "#names-count", "1 column of 2")

    view |> form("#names-form", %{"rows" => rows, "columns" => ""}) |> render_change()

    assert ObsSlideshowOverlay.Repo.get!(ObsSlideshowOverlay.Library.Slide, slide.id).columns ==
             nil
  end
end
