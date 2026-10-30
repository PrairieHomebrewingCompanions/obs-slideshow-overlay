defmodule ObsSlideshowOverlay.Repo.Migrations.CreateTables do
  use Ecto.Migration

  def change do
    # A slide in the library: an image, a list of names, or text.
    create table(:slides) do
      add :type, :string, null: false
      # Labels it in the gallery.
      add :name, :string
      # Its title; blank uses its slideshow's default title.
      add :title, :string
      add :image, :string
      add :width, :integer
      add :height, :integer
      add :style, :string, null: false, default: "auto"
      add :auto_style, :string
      add :size, :string, null: false, default: "auto"
      add :trim, :boolean, null: false, default: false
      add :heading, :string
      add :body, :text
      add :footer, :string
      add :max_per_page, :integer
      add :columns, :integer

      timestamps(type: :utc_datetime)
    end

    # A look: where the title and content sit, a style for each piece of
    # text (as JSON), and a background.
    create table(:themes) do
      add :name, :string, null: false, default: "Default"
      add :title_x, :integer, null: false, default: 120
      add :title_baseline, :integer, null: false, default: 990
      add :title_width, :integer, null: false, default: 1680
      add :content_x, :integer, null: false, default: 120
      add :content_y, :integer, null: false, default: 80
      add :content_width, :integer, null: false, default: 1680
      add :content_height, :integer, null: false, default: 800

      for style <- ~w(title_style name_style detail_style footer_style heading_style body_style)a,
          do: add(style, :map)

      add :background, :string
      add :background_scene, :string
      add :background_upload, :string
      add :background_in_player, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create table(:slideshows) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :slide_seconds, :integer, null: false, default: 6
      add :fade_ms, :integer, null: false, default: 800
      add :default_title, :string
      add :theme_id, references(:themes, on_delete: :nilify_all)
      # What Set up in OBS made for it.
      add :obs_scene, :string
      add :obs_input, :string
      add :obs_base, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:slideshows, [:slug])

    # A slide's place in a slideshow.
    create table(:items) do
      add :slideshow_id, references(:slideshows, on_delete: :delete_all), null: false
      add :slide_id, references(:slides, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :seconds, :integer
      add :skipped, :boolean, null: false, default: false
      add :pinned, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:items, [:slideshow_id, :slide_id])
    create index(:items, [:slideshow_id, :position])

    create table(:obs_settings) do
      add :url, :string, null: false, default: "ws://127.0.0.1:4455"
      add :password, :string

      timestamps(type: :utc_datetime)
    end
  end
end
