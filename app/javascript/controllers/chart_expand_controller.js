import { Controller } from "@hotwired/stimulus"

// ChartExpandController — wires the "maximize chart" button on
// Components::Metrics::ChartCard to an overlay modal containing
// the chart at a much larger render size + a local-scoped range
// picker.
//
// Lifecycle:
//
//   1. The Phlex ChartCard renders THREE things side by side:
//      - the inline chart (always visible)
//      - a maximize button with data-action="chart-expand#open"
//      - an overlay div with [hidden] holding the modal scaffold
//        + an empty <turbo-frame id="chart-modal-frame">
//
//   2. open(): removes `hidden` from the overlay, sets the
//      turbo-frame's `src` (which triggers Turbo to fetch the
//      single-chart endpoint), locks body scroll, listens for
//      ESC.
//
//   3. Inside the overlay, range-pill anchors target the same
//      turbo-frame — Turbo extracts the new frame on each click
//      and swaps in place. Modal stays open; URL doesn't change.
//
//   4. close(): adds `hidden` back, clears the frame's src
//      (so the next open refetches at the current global state
//      rather than showing yesterday's local-modal range), and
//      unlocks body scroll.
//
// Why not reuse Components::UI::Modal directly: that component is
// designed as a full-page render (route-driven open + close-by-
// navigation). The chart-expand flow needs an OVERLAY that pops
// up on the current page without route change. Same shadow/blur
// styling, different open semantics.
export default class extends Controller {
  static targets = ["overlay", "frame"]
  static values = { src: String }

  open(event) {
    event?.preventDefault()
    if (!this.hasOverlayTarget) return

    // Show first, then fetch — the operator sees the modal
    // shell + loading state before the chart body lands.
    this.overlayTarget.hidden = false
    this.frameTarget.src = this.srcValue

    // Body scroll-lock + ESC binding.
    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"

    this.onKey = this.onKey.bind(this)
    document.addEventListener("keydown", this.onKey)
  }

  close(event) {
    event?.preventDefault()
    if (!this.hasOverlayTarget) return

    this.overlayTarget.hidden = true

    // Clear the frame so reopening doesn't flash stale content
    // (the local range the operator picked last time would
    // otherwise persist into the next open, which is confusing —
    // each open starts at the parent page's range).
    if (this.hasFrameTarget) this.frameTarget.removeAttribute("src")

    document.body.style.overflow = this.previousBodyOverflow ?? ""

    if (this.onKey) {
      document.removeEventListener("keydown", this.onKey)
      this.onKey = null
    }
  }

  // backdropClick — only fires when the actual backdrop element
  // is the event target (a click on the dialog itself bubbles up
  // but with target=dialog, so this guard preserves "click the
  // chart to keep it open").
  backdropClick(event) {
    if (event.target === event.currentTarget) this.close(event)
  }

  onKey(event) {
    if (event.key === "Escape") this.close(event)
  }

  disconnect() {
    // Defensive — if the controller's element gets ripped out of
    // the DOM while the modal is open (e.g. turbo-frame swap on
    // the parent /metrics page during a poll tick), unlock scroll
    // + remove the ESC listener.
    if (this.onKey) {
      document.removeEventListener("keydown", this.onKey)
      document.body.style.overflow = this.previousBodyOverflow ?? ""
    }
  }
}
