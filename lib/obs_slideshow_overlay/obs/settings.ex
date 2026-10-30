defmodule ObsSlideshowOverlay.Obs.Settings do
  @moduledoc "How to reach OBS's WebSocket server (Tools > WebSocket Server Settings)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "obs_settings" do
    field :url, :string, default: "ws://127.0.0.1:4455"
    field :password, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:url, :password])
    |> validate_required([:url])
    |> validate_format(:url, ~r{\Awss?://[^/\s]+},
      message: "should look like ws://127.0.0.1:4455"
    )
  end
end
