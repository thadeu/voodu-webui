import { Controller } from "@hotwired/stimulus"

// DrawerController — companion to Components::UI::Drawer.
//
// Responsibilities:
//
//   1. Intercept plain left-click on the trigger and open the panel
//      in-place. Cmd/Ctrl/Shift/middle-click fall through to the
//      anchor's native href (open in new tab), preserving operator
//      muscle memory.
//
//   2. Lazy-fetch `srcValue` on first open and inject into the
//      panel body. Subsequent opens reuse the cached content.
//      Stimulus auto-connects controllers in the injected fragment
//      via its DOM mutation observer.
//
//   3. Lock html scroll while open (set documentElement.overflow =
//      "hidden") so the page underneath doesn't shift around as the
//      operator reads the drawer.
//
//   4. ESC + click-outside dismiss.
//
//   5. Resizable left edge. Pointer-down on the handle enters drag
//      mode; pointer-move computes width as (viewportWidth -
//      pointerX) clamped to [min, viewport-80]; pointer-up persists
//      the new width to localStorage under a single shared key so
//      every drawer in the app remembers the operator's preference.
//
// Persistence: width is stored as a CSS value (e.g. "560px") in
// localStorage. On connect, every drawer reads it and applies as
// the initial width (overriding the server-rendered default).
const STORAGE_KEY = "voodu:drawer-width"

export default class extends Controller {
  static targets = ["panel", "body", "handle"]
  static values  = {
    src:       String,
    minWidth:  { type: String,  default: "320px" },
    resizable: { type: Boolean, default: true }
  }

  connect() {
    this.onKey         = this.onKey.bind(this)
    this.onDocPointer  = this.onDocPointer.bind(this)
    this.onResizeMove  = this.onResizeMove.bind(this)
    this.onResizeEnd   = this.onResizeEnd.bind(this)
    this.contentLoaded = false

    // Apply any persisted width — overrides the server default so
    // the operator's chosen size sticks across visits/drawers.
    const saved = localStorage.getItem(STORAGE_KEY)
    if (saved && this.hasPanelTarget) this.panelTarget.style.width = saved
  }

  disconnect() {
    if (this.isOpen) {
      this.removeListeners()
      this.unlockScroll()
    }
  }

  // ── open / close ────────────────────────────────────────────────

  open(event) {
    if (this.isModifiedClick(event)) return  // cmd/ctrl → native new tab
    event.preventDefault()

    this.panelTarget.dataset.open = "true"
    this.panelTarget.inert = false
    this.isOpen = true

    this.lockScroll()
    this.addListeners()
    this.loadIfNeeded()

    requestAnimationFrame(() => {
      const focusable = this.panelTarget.querySelector(
        "a[href], button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex='-1'])"
      )
      ;(focusable || this.panelTarget).focus({ preventScroll: true })
    })
  }

  close(event) {
    event?.preventDefault()
    delete this.panelTarget.dataset.open
    this.panelTarget.inert = true
    this.isOpen = false
    this.removeListeners()
    this.unlockScroll()
  }

  // ── scroll lock ─────────────────────────────────────────────────

  lockScroll() {
    this.savedHtmlOverflow = document.documentElement.style.overflow
    this.savedBodyOverflow = document.body.style.overflow
    document.documentElement.style.overflow = "hidden"
    document.body.style.overflow = "hidden"
  }

  unlockScroll() {
    document.documentElement.style.overflow = this.savedHtmlOverflow ?? ""
    document.body.style.overflow            = this.savedBodyOverflow ?? ""
  }

  // ── lazy content fetch ──────────────────────────────────────────

  async loadIfNeeded() {
    if (this.contentLoaded) return

    try {
      const response = await fetch(this.srcValue, {
        headers: { "Accept": "text/html", "X-Drawer-Embed": "1" }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const html = await response.text()
      this.bodyTarget.innerHTML = html
      this.contentLoaded = true
    } catch (err) {
      this.bodyTarget.innerHTML = `
        <div class="h-full flex flex-col items-center justify-center gap-2 text-voodu-red text-[12px] p-6">
          <div class="font-semibold">Couldn't load content</div>
          <div class="text-voodu-muted">${err.message}</div>
        </div>`
    }
  }

  // ── ESC + click-outside ─────────────────────────────────────────

  onKey(event) {
    if (event.key === "Escape") this.close()
  }

  onDocPointer(event) {
    // Don't dismiss while the operator is dragging the resize
    // handle past the panel edge.
    if (this.resizing) return
    if (this.element.contains(event.target)) return
    this.close()
  }

  isModifiedClick(event) {
    return event.metaKey || event.ctrlKey || event.shiftKey || event.button === 1
  }

  addListeners() {
    document.addEventListener("keydown", this.onKey)
    setTimeout(() => document.addEventListener("pointerdown", this.onDocPointer), 0)
  }

  removeListeners() {
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("pointerdown", this.onDocPointer)
  }

  // ── resize ──────────────────────────────────────────────────────

  startResize(event) {
    if (!this.resizableValue) return
    event.preventDefault()
    this.resizing = true

    // Keep the cursor + suppress text selection across the whole
    // page while the drag is active — without this the cursor
    // flickers back to default whenever the pointer leaves the 5px
    // handle, and dragging selects text in the page beneath.
    this.savedBodyCursor    = document.body.style.cursor
    this.savedBodyUserSelect = document.body.style.userSelect
    document.body.style.cursor     = "col-resize"
    document.body.style.userSelect = "none"

    document.addEventListener("pointermove", this.onResizeMove)
    document.addEventListener("pointerup",   this.onResizeEnd)
    document.addEventListener("pointercancel", this.onResizeEnd)
  }

  onResizeMove(event) {
    if (!this.resizing) return
    const min = this.parseLengthToPx(this.minWidthValue) || 320
    const max = window.innerWidth - 80    // leave breathing room
    const w   = Math.max(min, Math.min(max, window.innerWidth - event.clientX))
    this.panelTarget.style.width = `${w}px`
  }

  onResizeEnd() {
    if (!this.resizing) return
    this.resizing = false
    document.body.style.cursor     = this.savedBodyCursor ?? ""
    document.body.style.userSelect = this.savedBodyUserSelect ?? ""
    document.removeEventListener("pointermove", this.onResizeMove)
    document.removeEventListener("pointerup",   this.onResizeEnd)
    document.removeEventListener("pointercancel", this.onResizeEnd)

    // Persist as the literal pixel value. Every drawer reads this
    // on connect — operator sets it once, every subsequent peek
    // honours it.
    try {
      localStorage.setItem(STORAGE_KEY, this.panelTarget.style.width)
    } catch { /* localStorage disabled — silently ignore */ }
  }

  // parseLengthToPx — converts a CSS length string to pixels.
  // Supports `Npx` and `Nvw`. `min_width` comes in via a Stimulus
  // value (string), so this lives here rather than on the server.
  parseLengthToPx(v) {
    const m = String(v).match(/^([\d.]+)(px|vw)?$/)
    if (!m) return null
    const n = parseFloat(m[1])
    return m[2] === "vw" ? (n * window.innerWidth) / 100 : n
  }
}
