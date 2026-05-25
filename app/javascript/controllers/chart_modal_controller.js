import { Controller } from "@hotwired/stimulus"

// ChartModalController — companion to Components::Metrics::ChartModal,
// the SHARED modal scaffold rendered once on /metrics. Owns the
// interactive lifecycle that turbo_stream actions can't express:
//
//   - ESC keydown closes
//   - Backdrop click closes
//   - body scroll-lock while open
//   - Suspends polling_controller on the parent page while open
//     (so the /metrics 30s tick doesn't refetch + flicker the
//     cards behind the modal mid-investigation)
//
// Open/close VISIBILITY is driven by the server via custom Turbo
// Stream actions (chart_modal_open / chart_modal_close — see
// turbo_actions/chart_modal.js). Those toggle the `hidden`
// attribute and dispatch `chart-modal:opened` / `chart-modal:closed`
// events on the modal element. This controller listens for those
// events to apply / undo the side effects.
//
// We DON'T expose `open()` / `close()` Stimulus actions because the
// open path is server-driven (the maximize button does a GET that
// returns a turbo_stream with chart_modal_open). The X button +
// backdrop close LOCALLY via #close, which dispatches a custom
// event the server doesn't need to know about.
export default class extends Controller {
  static targets = ["backdrop", "dialog"]

  connect() {
    this.boundKey = this.onKey.bind(this)
    this.boundOpened = this.onOpened.bind(this)
    this.boundClosed = this.onClosed.bind(this)

    this.element.addEventListener("chart-modal:opened", this.boundOpened)
    this.element.addEventListener("chart-modal:closed", this.boundClosed)

    // If the page renders with the modal already open (server
    // streamed open + close happened in same response, or page
    // reloaded mid-state), sync our side effects to the current
    // visibility.
    if (!this.element.hasAttribute("hidden")) this.onOpened()
  }

  disconnect() {
    this.element.removeEventListener("chart-modal:opened", this.boundOpened)
    this.element.removeEventListener("chart-modal:closed", this.boundClosed)
    // Defensive: if the controller is torn down mid-open, release
    // the body lock + polling pause so the rest of the page isn't
    // stuck in modal-mode forever.
    if (this.locked) this.onClosed()
  }

  // close — fired by the X button and backdrop click. Just hides
  // the modal client-side; no server round-trip needed for the
  // close path (the modal scaffold + last-loaded body stay in DOM,
  // ready for the next open to swap the body via turbo_stream).
  close(event) {
    event?.preventDefault()
    this.element.setAttribute("hidden", "")
    this.element.dispatchEvent(new CustomEvent("chart-modal:closed", { bubbles: true }))
  }

  // backdropClick — only fires when the actual backdrop element
  // is the event target (preserves "click the chart to keep the
  // modal open"). Dialog clicks bubble to currentTarget but with
  // event.target = the dialog/inner element, so the guard works.
  backdropClick(event) {
    if (event.target === event.currentTarget) this.close(event)
  }

  onKey(event) {
    if (event.key === "Escape") this.close(event)
  }

  onOpened() {
    if (this.locked) return
    this.locked = true

    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"

    document.addEventListener("keydown", this.boundKey)

    // Pause the metrics-page polling tick. Counter-based, the
    // polling controller stacks pause/resume pairs.
    window.dispatchEvent(new Event("polling:pause"))
  }

  onClosed() {
    if (!this.locked) return
    this.locked = false

    document.body.style.overflow = this.previousBodyOverflow ?? ""
    document.removeEventListener("keydown", this.boundKey)

    window.dispatchEvent(new Event("polling:resume"))
  }
}
