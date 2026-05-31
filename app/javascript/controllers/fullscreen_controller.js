import { Controller } from "@hotwired/stimulus"

// FullscreenController — blows the metrics chart grid up to a near-full
// viewport overlay (97vw × 97vh) so the operator can see every stacked
// panel at once. It repositions the LIVE grid in place (fixed) rather
// than cloning it — the metrics-charts turbo-frame keeps swapping on the
// realtime tick, the chart ResizeObservers refill the wider canvas, and
// no SVG state is duplicated.
//
// Close via the floating ✕, Esc, or a backdrop click. Body scroll is
// locked while open and restored on close.
export default class extends Controller {
  static targets = ["panel", "backdrop", "chrome", "body"]

  connect() {
    this.onKey = this.onKey.bind(this)
    this.isOpen = false
  }

  disconnect() {
    if (this.isOpen) this.teardown()
  }

  open() {
    if (this.isOpen) return

    this.isOpen = true
    this.panelTarget.classList.add(...FULLSCREEN_CLASSES)

    if (this.hasBackdropTarget) this.backdropTarget.hidden = false
    if (this.hasChromeTarget) this.chromeTarget.hidden = false
    if (this.hasBodyTarget) this.bodyTarget.classList.add(...BODY_PADDING)

    this.prevOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"
    document.addEventListener("keydown", this.onKey)

    this.panelTarget.scrollTop = 0
  }

  close() {
    if (!this.isOpen) return

    this.teardown()
  }

  toggle() {
    this.isOpen ? this.close() : this.open()
  }

  teardown() {
    this.isOpen = false
    this.panelTarget.classList.remove(...FULLSCREEN_CLASSES)

    if (this.hasBackdropTarget) this.backdropTarget.hidden = true
    if (this.hasChromeTarget) this.chromeTarget.hidden = true
    if (this.hasBodyTarget) this.bodyTarget.classList.remove(...BODY_PADDING)

    document.body.style.overflow = this.prevOverflow || ""
    document.removeEventListener("keydown", this.onKey)
  }

  onKey(event) {
    if (event.key === "Escape") this.close()
  }
}

// Panel goes edge-to-edge (no padding) so the sticky chrome bar sits
// flush at the top; the body target carries the inner padding instead.
const FULLSCREEN_CLASSES =
  "fixed left-[1.5vw] top-[1.5vh] w-[97vw] h-[97vh] z-[70] overflow-auto scrollbar-hidden bg-voodu-bg border border-voodu-border-2 shadow-2xl"
    .split(" ")

const BODY_PADDING = "p-3 vmd:p-4".split(" ")
