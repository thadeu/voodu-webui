import { Controller } from "@hotwired/stimulus"

// popover — a click-toggled panel that escapes modal overflow-clipping.
//
// A plain absolutely-positioned menu gets cut off by an ancestor with
// `overflow: auto` (the modal body scroller). This controller re-parents
// the menu to the enclosing modal dialog (or <body> outside a modal) on
// open and positions it absolutely under the trigger, so nothing clips
// it. Right-aligned to the trigger, height-capped to the viewport,
// closes on outside-click and Escape.
//
// The menu node is captured ONCE on connect: once it's portaled out of
// this controller's element, Stimulus's `menuTarget` getter can't find
// it anymore (targets are scoped to the controller subtree), so every
// later operation uses the cached `this.menu` reference instead.
//
// The menu content MUST be self-contained — once portaled it leaves the
// trigger's DOM subtree, so any `data-action` bound to a controller it
// was nested under would stop resolving. (Static help content is fine.)
//
//   <div data-controller="popover">
//     <button data-popover-target="trigger" data-action="popover#toggle">?</button>
//     <div data-popover-target="menu" hidden>…</div>
//   </div>
export default class extends Controller {
  static targets = ["trigger", "menu"]

  connect() {
    this.menu = this.hasMenuTarget ? this.menuTarget : null

    this.onOutside = (e) => {
      if (!this.menu) return
      if (this.menu.contains(e.target) || this.triggerTarget.contains(e.target)) return

      this.close()
    }

    // Capture-phase + stopPropagation so Escape closes the popover
    // WITHOUT also reaching the modal's (bubble-phase) Escape handler —
    // otherwise one Escape would tear down the whole form.
    this.onKey = (e) => {
      if (e.key !== "Escape") return

      e.stopPropagation()
      this.close()
    }

    this.onReflow = () => { if (this.shown) this.place() }
  }

  disconnect() {
    this.detachListeners()
    this.restore()
  }

  toggle(event) {
    event.preventDefault()
    if (!this.menu) return

    this.shown ? this.close() : this.open()
  }

  open() {
    this.host = this.element.closest('[role="dialog"]') || document.body
    this.host.appendChild(this.menu)
    Object.assign(this.menu.style, { position: "absolute", zIndex: "90" })
    this.menu.hidden = false
    this.place()
    this.shown = true

    requestAnimationFrame(() => document.addEventListener("click", this.onOutside, true))
    document.addEventListener("keydown", this.onKey, true)
    window.addEventListener("resize", this.onReflow)
    window.addEventListener("scroll", this.onReflow, true)
  }

  place() {
    const t = this.triggerTarget.getBoundingClientRect()
    const h = this.host.getBoundingClientRect()
    const w = this.menu.offsetWidth

    this.menu.style.top = `${t.bottom - h.top + 4}px`
    this.menu.style.left = `${Math.max(8, t.right - h.left - w)}px`
    this.menu.style.maxHeight = `${Math.max(160, window.innerHeight - t.bottom - 16)}px`
  }

  close() {
    if (!this.shown) return

    this.shown = false
    this.detachListeners()
    this.restore()
  }

  // Hide and hand the menu back to the controller element so it survives
  // re-open (and isn't orphaned in the dialog if the form re-renders).
  restore() {
    if (!this.menu) return

    this.menu.hidden = true

    if (this.menu.parentElement !== this.element) this.element.appendChild(this.menu)
  }

  detachListeners() {
    document.removeEventListener("click", this.onOutside, true)
    document.removeEventListener("keydown", this.onKey, true)
    window.removeEventListener("resize", this.onReflow)
    window.removeEventListener("scroll", this.onReflow, true)
  }
}
