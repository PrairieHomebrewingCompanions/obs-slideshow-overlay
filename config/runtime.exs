import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/slides start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :obs_slideshow_overlay, ObsSlideshowOverlayWeb.Endpoint, server: true
end

# 4100, so it can run next to apps on Phoenix's usual 4000.
config :obs_slideshow_overlay, ObsSlideshowOverlayWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4100"))]

# The show's database and its images live together in one folder, so a show
# is backed up or moved by copying it. SLIDESHOW_DATA points elsewhere.
if config_env() != :test do
  data = System.get_env("SLIDESHOW_DATA", Path.expand("../data", __DIR__))
  config :obs_slideshow_overlay, :data_dir, data
  config :obs_slideshow_overlay, ObsSlideshowOverlay.Repo, database: Path.join(data, "slides.db")

  # The key that signs sessions is made for each install and kept with its
  # data (SECRET_KEY_BASE overrides it), never committed with the code.
  key_file = Path.join(data, "secret_key_base")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      case File.read(key_file) do
        {:ok, key} ->
          String.trim(key)

        {:error, _} ->
          key = :crypto.strong_rand_bytes(48) |> Base.encode64()
          File.mkdir_p!(data)
          File.write!(key_file, key)
          File.chmod!(key_file, 0o600)
          key
      end

  config :obs_slideshow_overlay, ObsSlideshowOverlayWeb.Endpoint, secret_key_base: secret_key_base
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :obs_slideshow_overlay, ObsSlideshowOverlayWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/slides_web/router\.ex$"E,
        ~r"lib/slides_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/slides/slides.db
      """

  config :obs_slideshow_overlay, ObsSlideshowOverlay.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  host = System.get_env("PHX_HOST") || "example.com"

  config :obs_slideshow_overlay, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :obs_slideshow_overlay, ObsSlideshowOverlayWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :obs_slideshow_overlay, ObsSlideshowOverlayWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :obs_slideshow_overlay, ObsSlideshowOverlayWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
