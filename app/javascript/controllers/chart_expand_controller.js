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

    // Cache references BEFORE portaling. Stimulus target getters
    // (`this.overlayTarget`, `this.frameTarget`) re-query the
    // controller's element subtree on every access — once we
    // appendChild the overlay to <body>, the targets are no
    // longer descendants of `this.element`, so the next read
    // throws "Missing target element 'overlay'". Capturing the
    // node refs here lets us keep operating on them after the
    // portal.
    const overlay = this.overlayTarget
    const frame   = this.frameTarget // lives inside overlay
    this.cachedOverlay = overlay
    this.cachedFrame   = frame

    // Portal the overlay to <body>. Critical: this card lives
    // inside the `metrics-charts` turbo-frame which gets fully
    // replaced every 30s by polling_controller. If the overlay
    // stayed inside the frame, the swap would rip the modal out
    // of the DOM mid-investigation. Moving it to body makes it
    // a sibling of the page chrome — survives any frame swap.
    this.homeParent = overlay.parentNode
    document.body.appendChild(overlay)

    // Wire close + backdrop click handlers directly with
    // addEventListener — NOT via Stimulus action delegation. Why:
    // Stimulus walks up the DOM from the clicked element looking
    // for `data-controller="chart-expand"` to resolve the
    // `click->chart-expand#close` action. Once the overlay is a
    // child of <body>, that ancestor doesn't exist anymore, so
    // the Stimulus action never fires. Binding manually here
    // bypasses the action resolution and lets the X + backdrop
    // close even after the portal.
    this.boundClose         = this.close.bind(this)
    this.boundBackdropClick = this.backdropClick.bind(this)
    this.closeBtnEl         = overlay.querySelector('[data-action~="click->chart-expand#close"]')
    this.backdropEl         = overlay.querySelector('[data-action~="click->chart-expand#backdropClick"]')
    this.closeBtnEl?.addEventListener("click", this.boundClose)
    this.backdropEl?.addEventListener("click", this.boundBackdropClick)

    // Suspend the parent page's polling so the 30s reload tick
    // doesn't visually flicker the charts behind the modal AND
    // doesn't race with our portal (a tick in flight when we
    // open would still swap the frame, undoing the home parent
    // we'd want close() to restore the overlay to).
    window.dispatchEvent(new Event("polling:pause"))

    // Show first, then fetch — the operator sees the modal
    // shell + loading state before the chart body lands.
    overlay.hidden = false
    frame.src = this.srcValue

    // Body scroll-lock + ESC binding.
    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"

    this.onKey = this.onKey.bind(this)
    document.addEventListener("keydown", this.onKey)
  }

  close(event) {
    event?.preventDefault()
    const overlay = this.cachedOverlay
    const frame   = this.cachedFrame
    if (!overlay) return

    overlay.hidden = true

    // Clear the frame so reopening doesn't flash stale content
    // (the local range the operator picked last time would
    // otherwise persist into the next open, which is confusing —
    // each open starts at the parent page's range).
    frame?.removeAttribute("src")

    // Resume parent-page polling. Counter-based so stacked modals
    // (theoretical — we only have one today) don't deadlock the
    // resume.
    window.dispatchEvent(new Event("polling:resume"))

    // Tear down the manual close/backdrop bindings we set up in
    // open() — keeping them around would either leak (next open
    // double-binds) or fire stale handlers if the controller
    // disconnects mid-modal.
    this.closeBtnEl?.removeEventListener("click", this.boundClose)
    this.backdropEl?.removeEventListener("click", this.boundBackdropClick)
    this.closeBtnEl         = null
    this.backdropEl         = null
    this.boundClose         = null
    this.boundBackdropClick = null

    // Put overlay back where Phlex rendered it, if its home parent
    // still exists in the DOM. If the parent has been replaced
    // (turbo-frame swap while modal was open), homeParent.isConnected
    // is false and we just leave the overlay on body — it's hidden
    // and inert, GC + next navigation will clean up.
    if (this.homeParent?.isConnected) {
      this.homeParent.appendChild(overlay)
    }

    this.cachedOverlay = null
    this.cachedFrame   = null

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
    // Defensive cleanup. If the controller's button element gets
    // ripped out of the DOM while the modal is open (turbo-frame
    // swap on the parent /metrics page during a poll tick — even
    // with our pause guard there's still e.g. operator clicking
    // the global Refresh button), this disconnect fires while
    // the portaled overlay still lives on <body>. Stripped down
    // close so the modal doesn't get stranded as an open shell.
    if (this.cachedOverlay) {
      this.cachedOverlay.hidden = true
      this.cachedFrame?.removeAttribute("src")
      // Don't bother re-parenting — the home parent is gone too.
      // Leave it on body; GC + next navigation will sweep.
      // Tear down the manual close/backdrop bindings (same listeners
      // we set in open() — without removing them we'd leak refs
      // that keep this controller instance alive after disconnect).
      this.closeBtnEl?.removeEventListener("click", this.boundClose)
      this.backdropEl?.removeEventListener("click", this.boundBackdropClick)
      this.closeBtnEl         = null
      this.backdropEl         = null
      this.boundClose         = null
      this.boundBackdropClick = null
      this.cachedOverlay      = null
      this.cachedFrame        = null
      // Resume polling in case we were the one who paused it.
      window.dispatchEvent(new Event("polling:resume"))
    }

    if (this.onKey) {
      document.removeEventListener("keydown", this.onKey)
      document.body.style.overflow = this.previousBodyOverflow ?? ""
      this.onKey = null
    }
  }
}
