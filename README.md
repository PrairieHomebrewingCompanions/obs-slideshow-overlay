# obs-slideshow-overlay

Slideshows for OBS: the logos, photos, lists of names and short
announcements a livestream shows between its live parts. You arrange them
in a gallery in your browser, style them with a theme, and OBS plays them
through a browser source. Every edit shows up in OBS straight away; there's
nothing to export or rebuild.

- **Slides** are images (logos, photos, anything), lists of names (paged
  automatically when long), or a heading with some text. A slide can appear
  in any number of slideshows.
- **Themes** set every piece of text's font, size, colour and shadow, and
  where the title and the content sit, by dragging them on a live preview.
  Use any font on your computer, or any of Google Fonts.
- **OBS** plays a slideshow as a transparent browser source over your own
  scene. Optionally, the app can connect to OBS to set that scene up for
  you, and to use a scene as a theme's background.

It runs on your own computer, for one person: there are no accounts, and
only that computer can reach it.

## Running it

You need [Elixir](https://elixir-lang.org/install.html) 1.17 or newer (with
Erlang/OTP). Everything else, including image processing, is fetched on the
first run. It works on macOS, Linux and Windows.

```sh
git clone <this repository> obs-slideshow-overlay
cd obs-slideshow-overlay
mix setup        # the first time only
mix phx.server
```

Then open http://localhost:4100. Set `PORT` to use another port.

### Your data

Everything you make (the database, uploaded images, downloaded fonts) is
kept in the `data/` folder inside the app's folder, which git ignores. Copy
that folder to back up a show or move it to another computer. **Deleting or
re-cloning the app's folder deletes it too**, so to keep your shows
elsewhere, set `SLIDESHOW_DATA` to another folder:

```sh
SLIDESHOW_DATA=~/Documents/Slideshows mix phx.server
```

## Making a slideshow

1. Name a new slideshow on the left, say "Welcome" or "Intermission".
2. Drag images anywhere onto the page, or use **Add images**. Images are
   turned the right way up and stripped of camera data (including GPS
   location). iPhone HEIC photos need converting to JPEG first.
3. **Name list** and **Text** add slides you fill in on the right.
4. **From library** adds slides already in another slideshow; editing a slide
   changes it everywhere it's used.

Every slide stays up for the slideshow's seconds per slide (the cog sets it,
along with its theme), unless you give it its own **Seconds on screen**.
Click a slide to edit it on the right; double-click (or Enter) opens it.
Cmd-click (Ctrl-click on Windows) adds to the selection and Shift-click
selects a range; drag to reorder everything selected, or change them all at
once on the right. Esc clears the selection.

### Images

Each image's style is picked from its pixels, and shown under its thumbnail:

- **framed**: images with their own background (photos, most JPEG logos),
  as a rounded rectangle with a shadow.
- **cut-out**: transparent images, straight on the background.
- **card**: transparent images too dark to show up, on a white card.

Its **size** is **fill** (as large as the theme's content area allows) or
**contained** (logo-sized, with room around it). Automatic fills framed
images and contains the rest. If it picks wrong, choose another style or
size. **Trim** cuts 3px off each edge, for images cut from a scan or PDF
with a stray border.

### Name lists

A name list shows names in columns, each with an optional detail line (a
role, a team, a thank-you). **Edit names…** opens its editor, where you can:

- type names, drag them into order, or sort them by first or last name;
- paste a list from a spreadsheet (a name column, then a detail column) or
  as text, one `Name | detail` per line, e.g. `Avery Chen | Stage Crew`;
- **import a CSV file**, such as a spreadsheet or sign-up form export: tick
  the columns that make the name (First and Last together, say) and any to
  show beneath it. Nothing else in the file is kept.

Long lists shrink to fit, and a list too long for one slide plays as several
pages, split evenly.

## Themes

A theme is a look: a style for each piece of text, where the title and the
content sit, and a background for the previews. Each slideshow plays in one
theme, chosen in its settings; slideshows that haven't chosen use the first
theme. **New theme** starts from a copy of the one you're looking at.

On the Themes page, each section styles one piece of text, and the preview
shows real slides from your library with what that section styles outlined.
Click text in the preview to open its section; drag the title, and the
**content area** box (where images, lists and text go), to place them.
Changes save as you make them, with **Undo**.

Fonts come from the font menu:

- the generic families every computer has (`system-ui`, `serif`, ...),
  which the default theme uses;
- the fonts installed on your computer;
- any of Google Fonts, downloaded when picked and kept in `data/fonts/`, so
  the show never needs the internet.

The app serves its fonts to the pages it shows, so they work in any browser
(Safari otherwise only lets pages use macOS's own fonts).

A theme's **background** image sits behind the previews, so they look like
your show: a screenshot of your OBS scene without the slides works well.
Tick **Also show it in OBS** only if the slideshow should bring its own
background; leave it off when your OBS scene already has one, or it will
cover it. The eye button above the previews hides the background, to show
only what the app draws.

## In OBS

Add a **Browser** source, 1920×1080, with the address shown at the top of
the slideshow (`http://localhost:4100/play/<number>`). The address never
changes, so renaming a slideshow during a show is safe. Put it above your
background and below anything that should cover it: the slides are
transparent around their content. The app has to be running for the
slideshow to play.

### Connecting to OBS (optional)

On the **OBS** page, enter the address and password from OBS → Tools →
WebSocket Server Settings → Show Connect Info. Then:

- **Themes** → "Use an OBS scene" takes a theme's background from a scene.
  This app's slideshows in that scene are hidden for the moment of the
  screenshot and put straight back.
- A slideshow's settings → **Set up in OBS** makes a scene called
  "Slideshow: <name>": the scene you pick (your background, and anything else
  under the slides) with the slideshow's browser source on top, sized to
  OBS's canvas. Run it again after a rename to rename the scene. It never
  changes a scene it didn't make.

The app only talks to OBS when you press one of these, and OBS needs to run
on the same computer.

## Bringing in a folder of files

`priv/import.exs` adds files from the command line (see the top of the file
for more), for example:

```sh
mix run priv/import.exs "Sponsors" images ~/event/logos/*
```

## Developing

```sh
mix test         # the tests
mix precommit    # compile warnings, formatting and tests, before committing
```

The app is a [Phoenix LiveView](https://www.phoenixframework.org) app with
a SQLite database. `AGENTS.md` has the project's coding guidelines.

## License

[MIT](LICENSE)
