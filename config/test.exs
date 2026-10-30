import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :obs_slideshow_overlay, :data_dir, Path.expand("../tmp/test_data", __DIR__)

# Tests bring their own fonts, and never reach Google (Req.Test stubs it).
config :obs_slideshow_overlay, :font_dirs, []

config :obs_slideshow_overlay, :google_fonts_req,
  plug: {Req.Test, ObsSlideshowOverlay.GoogleFonts}

config :obs_slideshow_overlay, ObsSlideshowOverlay.Repo,
  database: Path.expand("../obs_slideshow_overlay_test.db", __DIR__),
  pool_size: 5,
  # SQLite's default journal: switching a brand-new file to WAL from five
  # connections at once has them lock each other out on the first run.
  journal_mode: :delete,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :obs_slideshow_overlay, ObsSlideshowOverlayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "lz2PQ/Y5nE3PunrKKUbZxPcxYu7hddP2ib4WKMjP090F8ai98zHmPb/0ewqItMM0",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests migrate through the test alias, not on start
config :obs_slideshow_overlay, :migrate_on_start, false
