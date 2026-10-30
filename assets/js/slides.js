// The browser side of drawing slides (see ObsSlideshowOverlayWeb.SlideComponents), and
// the hooks for the OBS player and the gallery.
import Sortable from "../vendor/sortable.esm.js"

// Finishes slides once the fonts have loaded: fits each title to its width,
// puts its baseline on its data-baseline, and shrinks name lists until their
// columns fit. Both depend on the font, which the server can't measure.
export function settle(root) {
  return document.fonts.ready.then(() => {
    root.querySelectorAll("[data-max-width]").forEach(fitWidth)
    root.querySelectorAll("[data-baseline]").forEach(placeBaseline)
    root.querySelectorAll("[data-fit]").forEach(fitColumns)
  })
}

// A title wider than it may be gets a smaller font. Its own size is kept
// so the next pass starts from it.
function fitWidth(el) {
  el.dataset.size ||= getComputedStyle(el).fontSize
  el.style.fontSize = el.dataset.size
  const max = Number(el.dataset.maxWidth)
  if (el.offsetWidth > max) el.style.fontSize = `${parseFloat(el.dataset.size) * max / el.offsetWidth}px`
}

function placeBaseline(el) {
  // An empty inline-block sits on the baseline, so its offset is the
  // baseline's distance from the top of the title.
  const probe = document.createElement("span")
  probe.style.cssText = "display: inline-block; width: 0; height: 0;"
  el.appendChild(probe)
  const baseline = probe.offsetTop
  probe.remove()
  el.style.top = `${Number(el.dataset.baseline) - baseline}px`
}

function fitColumns(el) {
  let fit = 1
  el.style.setProperty("--fit", fit)
  while (el.scrollWidth > el.clientWidth && fit > 0.4) {
    fit -= 0.02
    el.style.setProperty("--fit", fit)
  }
}

// The slideshow OBS shows: every slide stacked, one visible at a time,
// cross-fading. Edits arrive as LiveView updates and take effect without
// restarting; the slide on screen stays on screen if it's still there.
export const Player = {
  mounted() {
    this.stage = this.el.querySelector("[data-stage]")
    this.onResize = () => this.scale()
    window.addEventListener("resize", this.onResize)
    this.scale()
    settle(this.el).then(() => this.advance(0))
  },

  // An update rewrites the stage's style, dropping its scale.
  updated() {
    this.scale()
    settle(this.el)
    const items = this.items()
    if (!items.some(el => el.dataset.item === this.current)) this.advance(0)
  },

  destroyed() {
    clearTimeout(this.timer)
    window.removeEventListener("resize", this.onResize)
  },

  items() {
    return [...this.el.querySelectorAll("[data-item]")]
  },

  // Slides are a 1920x1080 grid, scaled to fill the browser source (its size
  // is OBS's canvas) or a browser tab, and centred if the shape differs.
  scale() {
    const s = Math.min(window.innerWidth / 1920, window.innerHeight / 1080)
    const x = (window.innerWidth - 1920 * s) / 2
    const y = (window.innerHeight - 1080 * s) / 2
    this.stage.style.transform = `translate(${x}px, ${y}px) scale(${s})`
  },

  // Shows the slide `step` places after the current one.
  advance(step) {
    clearTimeout(this.timer)
    const items = this.items()
    if (items.length === 0) return (this.current = null)

    const at = items.findIndex(el => el.dataset.item === this.current)
    const next = items[(Math.max(at, 0) + step) % items.length]
    this.current = next.dataset.item

    // JS commands survive LiveView patches; a plain classList change wouldn't.
    items.forEach(el => {
      if (el === next) this.js().addClass(el, "on")
      else this.js().removeClass(el, "on")
    })

    this.timer = setTimeout(() => this.advance(1), Number(next.dataset.seconds) * 1000)
  },
}

// The gallery grid: click to select, Cmd-click (Ctrl elsewhere) to add or
// remove, Shift-click for a range, and drag to reorder everything selected.
export const Gallery = {
  mounted() {
    const mac = navigator.platform.toUpperCase().includes("MAC")

    this.sortable = new Sortable(this.el, {
      multiDrag: true,
      multiDragKey: mac ? "Meta" : "Control",
      selectedClass: "is-selected",
      // Clicking the edit panel mustn't clear the selection being edited.
      avoidImplicitDeselect: true,
      animation: 150,
      // Drag with mouse events rather than the browser's own drag and drop,
      // which behaves differently between browsers and fights file drops.
      forceFallback: true,
      // The spot a drag will land in, and the card being carried (app.css).
      ghostClass: "drop-spot",
      fallbackClass: "dragging",
      fallbackTolerance: 3,
      onSelect: () => this.sync(),
      onDeselect: () => this.sync(),
      onEnd: () => this.pushEvent("reorder", {ids: this.ids("[data-item]")}),
    })

    // Double-click (or Enter on a single selection) opens a slide for editing.
    const open = item => {
      this.selectOnly([item])
      this.pushEvent("open_item", {id: item.dataset.item})
    }
    this.el.addEventListener("dblclick", e => {
      const item = e.target.closest("[data-item]")
      if (item) open(item)
    })
    this.handleEvent("focus", ({selector}) => document.querySelector(selector)?.focus())

    this.onKey = e => {
      if (e.target.closest("input, textarea, select, button")) return
      if (e.key === "Escape") this.selectOnly([])
      if (e.key === "Enter") {
        const selected = this.el.querySelectorAll(".is-selected")
        if (selected.length === 1) {
          e.preventDefault()
          open(selected[0])
        }
      }
      if (e.key === "a" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault()
        this.selectOnly([...this.el.querySelectorAll("[data-item]")])
      }
    }
    window.addEventListener("keydown", this.onKey)
    this.handleEvent("select-none", () => this.selectOnly([]))
    settle(this.el)
  },

  updated() {
    settle(this.el)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    this.sortable.destroy()
  },

  ids(selector) {
    return [...this.el.querySelectorAll(selector)].map(el => el.dataset.item)
  },

  selectOnly(els) {
    this.el.querySelectorAll(".is-selected").forEach(el => Sortable.utils.deselect(el))
    els.forEach(el => Sortable.utils.select(el))
    this.sync()
  },

  sync() {
    this.pushEvent("select", {ids: this.ids(".is-selected")})
  },
}

// Shows the drop target while files are dragged
// over the window. They have to be on screen to receive the drop.
export const FileDrag = {
  mounted() {
    let depth = 0
    const files = e => [...(e.dataTransfer?.types || [])].includes("Files")
    this.on = e => files(e) && ++depth && (document.body.dataset.dragging = "")
    this.off = () => --depth <= 0 && this.reset()
    this.reset = () => {
      depth = 0
      delete document.body.dataset.dragging
    }
    window.addEventListener("dragenter", this.on)
    window.addEventListener("dragleave", this.off)
    window.addEventListener("drop", this.reset)
  },

  destroyed() {
    window.removeEventListener("dragenter", this.on)
    window.removeEventListener("dragleave", this.off)
    window.removeEventListener("drop", this.reset)
    this.reset()
  },
}

// Thumbnails and previews: finish the slides, and scale them to the box
// they're shown in (--preview-scale), for previews that change size.
export const Settle = {
  mounted() {
    this.scale = () => this.el.style.setProperty("--preview-scale", this.el.clientWidth / 1920)
    this.resize = new ResizeObserver(this.scale)
    this.resize.observe(this.el)
    this.scale()
    settle(this.el)
  },
  // A LiveView update rewrites the element's style, dropping the scale with
  // it, while its size stays the same; so set it again after every update.
  updated() {
    this.scale()
    settle(this.el)
  },
  destroyed() { this.resize.disconnect() },
}

// Sidebar renaming (see SidebarComponents): the box opens with its text
// selected, and a double-click on a name opens it.
export const SelectAll = {
  mounted() {
    this.el.focus()
    this.el.select()
  },
}

export const RenameOnDoubleClick = {
  mounted() {
    this.el.addEventListener("dblclick", e => {
      e.preventDefault()
      this.pushEvent("rename_start", {id: this.el.dataset.id})
    })
  },
}

// The name list editor's rows: drag a row by its handle to move it.
export const NameRows = {
  mounted() {
    this.sortable = new Sortable(this.el, {
      handle: ".row-handle",
      animation: 150,
      forceFallback: true,
      ghostClass: "drop-spot",
      fallbackClass: "dragging",
      onEnd: e => {
        if (e.oldIndex !== e.newIndex) this.pushEventTo(this.el, "move", {from: e.oldIndex, to: e.newIndex})
      },
    })
  },
  destroyed() { this.sortable.destroy() },
}

// The Themes page's preview. Text shows which style it's drawn in: hovering
// a section heading (or the text itself) outlines it, and clicking text
// opens its section. The title can be dragged into place, or nudged
// with the arrow keys (Shift for 10px) while its section is open.
export const ThemePreview = {
  mounted() {
    this.highlight = section => (this.el.dataset.highlight = section || this.el.dataset.open)
    window.addEventListener("theme:highlight", this.onHighlight = e => this.highlight(e.detail))

    const scale = () => this.el.querySelector("#theme-preview").clientWidth / 1920
    let drag = null

    // Text and the content area open their section when clicked. The title
    // and the content area can be dragged, and the area resized by its edges
    // and corners (when its section is open).
    this.el.addEventListener("pointerdown", e => {
      if (e.target.closest("[data-title-handle]")) {
        e.preventDefault()
        const limit = this.el.querySelector("#title-limit")
        drag = {limit, x: e.clientX, width: Number(limit.dataset.width)}
        return this.el.setPointerCapture(e.pointerId)
      }
      const text = e.target.closest("[data-style]")
      if (!text) return
      e.preventDefault()
      this.el.focus({preventScroll: true})
      const handle = this.el.dataset.open === "content_area" && e.target.dataset.handle
      drag = {text, handle, x: e.clientX, y: e.clientY, left: text.offsetLeft, top: text.offsetTop, moved: false}
      if (text.dataset.box) drag.box = JSON.parse(text.dataset.box)
      this.el.setPointerCapture(e.pointerId)
    })

    this.el.addEventListener("pointermove", e => {
      if (drag?.limit) {
        drag.to = Math.round(Math.max(100, drag.width + (e.clientX - drag.x) / scale()))
        drag.limit.style.width = `${drag.to}px`
        return
      }
      if (!drag || !["title_style", "content_area"].includes(drag.text.dataset.style)) return
      const dx = (e.clientX - drag.x) / scale(), dy = (e.clientY - drag.y) / scale()
      if (!drag.moved && Math.hypot(dx, dy) < 4) return
      drag.moved = true
      if (drag.box) {
        drag.to = resized(drag.box, drag.handle, dx, dy)
        const [x, y, w, h] = drag.to
        Object.assign(drag.text.style, {left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px`})
      } else {
        drag.text.style.left = `${drag.left + dx}px`
        drag.text.style.top = `${drag.top + dy}px`
      }
    })

    // Puts the title, its width and the content area where the server says
    // they ended up (ThemeLive replies so): a drag the slide's edge stopped
    // changes nothing there, so no update would put them back.
    this.placed = reply => {
      if (!reply) return
      const title = this.el.querySelector("#theme-preview [data-style=title_style]")
      if (title) title.style.left = `${reply.title_x}px`
      const limit = this.el.querySelector("#title-limit")
      if (limit) Object.assign(limit.style, {left: `${reply.title_x}px`, width: `${reply.title_width}px`})
      const area = this.el.querySelector("[data-style=content_area]")
      if (area) {
        const [x, y, w, h] = reply.content
        Object.assign(area.style, {left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${h}px`})
      }
      settle(this.el)
    }

    this.el.addEventListener("pointerup", e => {
      if (!drag) return
      if (drag.limit) {
        if (drag.to) this.pushEvent("set_title_width", {w: drag.to}, this.placed)
        return (drag = null)
      }
      const {text, moved} = drag
      if (moved && drag.box) {
        const [x, y, w, h] = drag.to
        this.pushEvent("set_content_area", {x, y, w, h}, this.placed)
      } else if (moved) {
        const dx = Math.round((e.clientX - drag.x) / scale()), dy = Math.round((e.clientY - drag.y) / scale())
        this.pushEvent("move_title", {dx, dy}, this.placed)
      } else {
        this.pushEvent("open_section", {section: text.dataset.style})
      }
      drag = null
    })

    // Only after clicking into the preview, so the keys still scroll the page.
    this.onKey = e => {
      const open = this.el.dataset.open
      if (open !== "title_style" && open !== "content_area") return
      if (e.target.closest("input, select, textarea, button")) return
      const step = e.shiftKey ? 10 : 1
      const d = {ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step]}[e.key]
      if (!d) return
      e.preventDefault()
      if (open === "title_style") return this.pushEvent("move_title", {dx: d[0], dy: d[1]}, this.placed)
      const area = this.el.querySelector("[data-style=content_area]")
      const [x, y, w, h] = JSON.parse(area.dataset.box)
      this.pushEvent("set_content_area", {x: x + d[0], y: y + d[1], w, h}, this.placed)
    }
    this.el.addEventListener("keydown", this.onKey)
  },
  updated() { this.highlight() },
  destroyed() {
    window.removeEventListener("theme:highlight", this.onHighlight)
  },
}

// The content area [x, y, w, h] after dragging `handle` ("nw", "e", ...; none
// moves it) by dx, dy slide pixels, kept on the slide and at least 100px.
function resized([x, y, w, h], handle, dx, dy) {
  const min = 100
  if (!handle) {
    x = Math.min(Math.max(x + dx, 0), 1920 - w)
    y = Math.min(Math.max(y + dy, 0), 1080 - h)
    return [x, y, w, h].map(Math.round)
  }
  let [left, top, right, bottom] = [x, y, x + w, y + h]
  if (handle.includes("w")) left = Math.min(Math.max(left + dx, 0), right - min)
  if (handle.includes("e")) right = Math.max(Math.min(right + dx, 1920), left + min)
  if (handle.includes("n")) top = Math.min(Math.max(top + dy, 0), bottom - min)
  if (handle.includes("s")) bottom = Math.max(Math.min(bottom + dy, 1080), top + min)
  return [left, top, right - left, bottom - top].map(Math.round)
}

// Section headings on the Themes page: hovering one outlines its text.
export const ThemeSections = {
  mounted() {
    const say = section => window.dispatchEvent(new CustomEvent("theme:highlight", {detail: section}))
    this.el.addEventListener("mouseover", e => {
      const heading = e.target.closest("[data-section]")
      if (heading) say(heading.dataset.section)
    })
    this.el.addEventListener("mouseleave", () => say(null))
  },
}

// The font families on the computer running the app (ObsSlideshowOverlay.Fonts), which
// pages can use in any browser: /fonts.css serves the installed ones. And
// Google's, which download when picked (ObsSlideshowOverlay.GoogleFonts).
const localFonts = {
  families: null,
  google: null,
  googleError: null,
  async load() {
    this.request ||= Promise.all([
      fetch("/fonts.json").then(r => r.json()),
      fetch("/google-fonts.json")
        .then(r => r.json())
        .then(body => (Array.isArray(body) ? body : Promise.reject(new Error(body.error))))
        .catch(e => ((this.googleError = e.message), [])),
    ])
    ;[this.families, this.google] = await this.request
    return this.families
  },
  forget() {
    this.request = null
    this.googleError = null
  },
}

// A Google Font's name in itself, for the font menu: Google sends just the
// letters of the name. It's declared under its own name ("Google preview:
// ..."), so it never stands in for the whole font once that's downloaded.
const googlePreviews = new Set()
function previewGoogleFont(family) {
  if (googlePreviews.has(family)) return
  googlePreviews.add(family)
  const name = encodeURIComponent(family).replace(/%20/g, "+")
  fetch(`https://fonts.googleapis.com/css2?family=${name}&text=${encodeURIComponent(family)}`)
    .then(r => (r.ok ? r.text() : ""))
    .then(css => {
      const style = document.createElement("style")
      style.textContent = css.replace(/font-family:\s*'[^']*'/g, `font-family: "Google preview: ${family}"`)
      document.head.appendChild(style)
    })
    .catch(() => {})
}

// After a font downloads (FontsHook): reloads /fonts.css, then finishes the
// slides again in their fonts and tells font boxes to check theirs.
export function reloadFonts() {
  localFonts.forget()
  const old = document.querySelector('link[href^="/fonts.css"]')
  if (!old) return
  const link = old.cloneNode()
  link.href = `/fonts.css?v=${Date.now()}`
  link.addEventListener("load", () => {
    old.remove()
    document.fonts.ready.then(() => {
      settle(document.body)
      window.dispatchEvent(new Event("slides:fonts-loaded"))
    })
  })
  old.after(link)
}

// A font box: a menu of the theme's fonts and the installed ones, each
// shown in itself, narrowed as you type; the box previews the highlighted
// one. Arrows and Enter pick. Typing is kept from the form, which saves only
// when a font is picked or the box is left. A font this computer doesn't
// have gets a warning beneath the box.
export const FontInput = {
  mounted() {
    this.warning = document.getElementById(`${this.el.id}-warning`)
    this.menu = document.createElement("ul")
    this.menu.id = `${this.el.id}-menu`
    this.menu.className = "font-menu"
    this.menu.setAttribute("role", "listbox")
    this.menu.hidden = true
    this.el.setAttribute("aria-controls", this.menu.id)
    document.body.appendChild(this.menu)
    this.committed = this.el.value

    this.el.addEventListener("focus", () => {
      this.filtering = false
      this.el.select()
      this.open()
    })
    this.el.addEventListener("input", e => {
      if (this.committing) return
      e.stopPropagation()
      this.filtering = true
      this.open()
    })
    this.el.addEventListener("blur", () => {
      this.close()
      this.commit()
      this.check()
    })
    this.el.addEventListener("keydown", e => this.key(e))
    // mousedown, not click: it keeps the focus in the box.
    this.menu.addEventListener("mousedown", e => {
      e.preventDefault()
      const option = e.target.closest("[data-font]")
      if (option) this.choose(option.dataset.font, "google" in option.dataset)
    })
    this.menu.addEventListener("mousemove", e => {
      const option = e.target.closest("[data-font]")
      if (option) this.highlight(this.options().indexOf(option))
    })

    // A Google Font that couldn't download: back to the style's font.
    this.handleEvent("font_failed", ({input, font}) => {
      if (input !== this.el.id) return
      this.el.value = this.committed = font
      this.check()
    })

    this.reposition = () => this.menu.hidden || this.place()
    window.addEventListener("resize", this.reposition)
    document.addEventListener("scroll", this.reposition, true)

    // Google Fonts' rows get their preview as they scroll into view.
    this.previews = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue
        previewGoogleFont(entry.target.dataset.font)
        this.previews.unobserve(entry.target)
      }
    }, {root: this.menu})

    this.onFonts = () => {
      localFonts.load().then(() => this.menu.hidden || this.open())
      this.check()
    }
    window.addEventListener("slides:fonts-loaded", this.onFonts)

    localFonts.load().then(() => this.menu.hidden || this.open())
    this.check()
  },

  // A save redraws the box without its font, which is put back.
  updated() {
    if (document.activeElement !== this.el) this.committed = this.el.value
    if (this.menu.hidden) this.check()
    else this.highlight(this.active)
  },

  destroyed() {
    this.previews.disconnect()
    window.removeEventListener("slides:fonts-loaded", this.onFonts)
    this.menu.remove()
    window.removeEventListener("resize", this.reposition)
    document.removeEventListener("scroll", this.reposition, true)
  },

  // The box shows its font in that font, and warns if there's no such
  // font. (One the app serves may still be on its way.)
  async check() {
    const family = this.el.value.trim()
    this.el.style.fontFamily = family ? `${cssFamily(family)}, system-ui` : ""
    if (!this.warning) return
    if (family) await document.fonts.load(`72px "${family}"`).catch(() => {})
    this.warning.hidden = !family || installed(family)
  },

  open() {
    const typed = this.filtering ? this.el.value.trim().toLowerCase() : ""
    const matches = f => f.toLowerCase().includes(typed)
    const theme = JSON.parse(this.el.dataset.fonts || "[]").filter(matches)
    const builtIn = GENERIC_FAMILIES.filter(f => matches(f) && !theme.includes(f))
    const others = (localFonts.families || []).filter(f => matches(f) && !theme.includes(f))
    const google = (localFonts.google || []).filter(f => matches(f) && !theme.includes(f))

    this.menu.replaceChildren()
    this.group("In this theme", theme)
    this.group("On every computer", builtIn)
    this.group("Installed", others)
    this.group("Google Fonts · downloaded when picked", google, true)
    if (localFonts.googleError) this.note(`Google Fonts: ${localFonts.googleError}`)
    if (localFonts.families && theme.length + builtIn.length + others.length + google.length === 0)
      this.note("No font matches")

    // The current font, or while typing, the first match.
    const options = this.options()
    const exact = options.findIndex(o => o.dataset.font.toLowerCase() === typed)
    const current = options.findIndex(o => o.dataset.font === this.el.value.trim())
    this.highlight(this.filtering ? (exact >= 0 ? exact : typed ? 0 : -1) : current)
    this.menu.hidden = false
    this.el.setAttribute("aria-expanded", "true")
    this.place()
  },

  close() {
    this.menu.hidden = true
    this.el.setAttribute("aria-expanded", "false")
  },

  group(label, fonts, fromGoogle = false) {
    if (fonts.length === 0) return
    const heading = document.createElement("li")
    heading.className = "font-menu-heading"
    heading.textContent = label
    this.menu.appendChild(heading)
    for (const font of fonts) {
      const item = document.createElement("li")
      item.setAttribute("role", "option")
      item.dataset.font = font
      const sample = document.createElement("span")
      sample.textContent = font
      sample.style.fontFamily = `${cssFamily(font)}, system-ui`
      if (fromGoogle) {
        item.dataset.google = ""
        sample.style.fontFamily = `"Google preview: ${font}", system-ui`
        this.previews.observe(item)
      }
      // Symbol fonts don't show their own names, so it's written plainly too.
      const plain = document.createElement("small")
      plain.textContent = font
      item.append(sample, plain)
      this.menu.appendChild(item)
    }
  },

  note(text) {
    const item = document.createElement("li")
    item.className = "font-menu-note"
    item.textContent = text
    this.menu.appendChild(item)
    return item
  },

  options() {
    return [...this.menu.querySelectorAll("[data-font]")]
  },

  highlight(index) {
    const options = this.options()
    options.forEach((o, i) => o.setAttribute("aria-selected", String(i === index)))
    this.active = options[index] ? index : -1
    options[index]?.scrollIntoView({block: "nearest"})
    const font = options[index]?.dataset.font
    const preview = options[index] && "google" in options[index].dataset ? `, "Google preview: ${font}"` : ""
    this.el.style.fontFamily = font ? `${cssFamily(font)}${preview}, system-ui` : ""
  },

  key(e) {
    const count = this.options().length
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      if (this.menu.hidden) return this.open()
      const step = e.key === "ArrowDown" ? 1 : -1
      this.highlight(count ? (this.active + step + count) % count : -1)
    } else if (e.key === "Enter" && !this.menu.hidden && this.active >= 0) {
      e.preventDefault()
      const option = this.options()[this.active]
      this.choose(option.dataset.font, "google" in option.dataset)
    } else if (e.key === "Enter") {
      e.preventDefault()
      this.close()
      this.commit()
      this.check()
    } else if (e.key === "Escape" && !this.menu.hidden) {
      e.preventDefault()
      this.close()
    }
  },

  // A Google Font isn't saved here: ThemeLive downloads it first and then
  // changes the style, so slides never show it before it's here. (Marking
  // it committed keeps leaving the box from saving it early.)
  choose(font, fromGoogle = false) {
    this.el.value = font
    this.close()
    if (fromGoogle) {
      this.committed = font
      const style = this.el.name.match(/\[(\w+)\]\[font\]$/)?.[1]
      this.pushEvent("add_google_font", {family: font, style, input: this.el.id})
    } else {
      this.commit()
    }
    this.check()
  },

  // Hands the box's font to the form, which saves it, unless it's unchanged.
  commit() {
    const font = this.el.value.trim()
    if (font === this.committed) return
    this.committed = font
    this.committing = true
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
    this.committing = false
  },

  place() {
    const box = this.el.getBoundingClientRect()
    const below = window.innerHeight - box.bottom - 16
    Object.assign(this.menu.style, {
      left: `${box.left}px`,
      top: `${box.bottom + 4}px`,
      width: `${box.width}px`,
      maxHeight: `${Math.max(160, Math.min(360, below))}px`,
    })
  },
}

// CSS's own font families, which every computer has (ObsSlideshowOverlay.Library.TextStyle
// knows the same list): named unquoted, and never "not installed".
const GENERIC_FAMILIES = ["system-ui", "sans-serif", "serif", "monospace", "cursive", "ui-rounded"]
const GENERIC = new Set([
  ...GENERIC_FAMILIES, "fantasy", "ui-serif", "ui-sans-serif", "ui-monospace", "math", "emoji", "fangsong",
])
const cssFamily = family => (GENERIC.has(family) ? family : `"${family}"`)

// A font counts as installed if text set in it measures differently from
// the same text in each fallback.
function installed(family) {
  if (GENERIC.has(family)) return true
  const ctx = (installed.canvas ||= document.createElement("canvas")).getContext("2d")
  const width = font => ((ctx.font = font), ctx.measureText("mmmmmmmmmmlliWW@#").width)
  return ["monospace", "serif", "sans-serif"].some(
    fallback => width(`72px "${family}", ${fallback}`) !== width(`72px ${fallback}`)
  )
}

// A colour: a swatch and a hex box kept in step; the box is the form field.
export const ColorField = {
  mounted() {
    this.swatch = this.el.querySelector("input[type=color]")
    this.text = this.el.querySelector("input[type=text]")
    this.swatch.addEventListener("input", () => {
      this.text.value = this.swatch.value
      this.text.dispatchEvent(new Event("input", {bubbles: true}))
    })
    this.text.addEventListener("input", () => {
      if (/^#[0-9a-fA-F]{6}$/.test(this.text.value)) this.swatch.value = this.text.value
    })
  },
}
