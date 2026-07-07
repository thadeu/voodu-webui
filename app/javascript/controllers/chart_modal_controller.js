import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

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
  static values = { chartPath: String }

  // Prefix the modal's chart params get in the page URL (mx_metric, mx_range,
  // mx_from, …) so they never collide with the grid's own range/scope params.
  // Their presence IS the "modal is open" flag — the page is url-state-first:
  // a refresh (or a shared link) with mx_* params re-opens the modal.
  MODAL_PREFIX = "mx_"

  connect() {
    this.boundKey = this.onKey.bind(this)
    this.boundOpened = this.onOpened.bind(this)
    this.boundClosed = this.onClosed.bind(this)

    this.element.addEventListener("chart-modal:opened", this.boundOpened)
    this.element.addEventListener("chart-modal:closed", this.boundClosed)

    // If the page renders with the modal already open (server streamed
    // open + close in the same response), sync side effects to it.
    if (!this.element.hasAttribute("hidden")) {
      this.onOpened()
    } else if (this.hasModalParams()) {
      // Refreshed (or deep-linked) with mx_* params but the modal renders
      // hidden → rebuild the chart URL from them and re-open in place.
      this.hydrateFromUrl()
    }
  }

  disconnect() {
    this.disconnecting = true
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
    // Runs on EVERY open — including re-opens when a modal picker (metric /
    // pod / range / interval) swaps the body — so the URL tracks the current
    // modal state, not just the first open.
    this.syncUrl()

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

    // Drop the mx_* params so the URL reflects "modal closed" — but not while
    // the controller is being torn down for a Turbo navigation (touching the
    // URL then would fight Turbo's own history handling).
    if (!this.disconnecting) this.clearUrl()
  }

  // ── url-state sync ───────────────────────────────────────────────────────

  hasModalParams() {
    for (const k of new URLSearchParams(window.location.search).keys()) {
      if (k.startsWith(this.MODAL_PREFIX)) return true
    }

    return false
  }

  // syncUrl — mirror the current modal body's params into the page URL under
  // the mx_ prefix. The body carries them on data-refresh-url (the exact
  // /metrics/chart query for the metric/scope/range/interval on screen).
  syncUrl() {
    const body = document.getElementById("chart-modal-body")
    const refresh = body?.dataset?.refreshUrl

    if (!refresh) return

    const chartQuery = new URL(refresh, window.location.origin).searchParams
    const url = new URL(window.location.href)

    this.stripModalParams(url)
    for (const [k, v] of chartQuery) url.searchParams.set(this.MODAL_PREFIX + k, v)

    window.history.replaceState(window.history.state, "", url.toString())
  }

  clearUrl() {
    const url = new URL(window.location.href)

    if (!this.stripModalParams(url)) return

    window.history.replaceState(window.history.state, "", url.toString())
  }

  // stripModalParams — delete every mx_ key from `url`. Returns whether any
  // were present, so clearUrl can skip a no-op replaceState.
  stripModalParams(url) {
    let had = false

    for (const k of [...url.searchParams.keys()]) {
      if (k.startsWith(this.MODAL_PREFIX)) {
        url.searchParams.delete(k)
        had = true
      }
    }

    return had
  }

  // hydrateFromUrl — rebuild the /metrics/chart URL from the mx_ params and
  // fetch it as a turbo-stream, which re-opens the modal exactly like the
  // maximize button did. Keeps the open path single-sourced.
  async hydrateFromUrl() {
    const base = this.chartPathValue || `${window.location.pathname.replace(/\/$/, "")}/chart`
    const chart = new URLSearchParams()

    for (const [k, v] of new URLSearchParams(window.location.search)) {
      if (k.startsWith(this.MODAL_PREFIX)) chart.set(k.slice(this.MODAL_PREFIX.length), v)
    }

    if (![...chart.keys()].length) return

    try {
      const res = await fetch(`${base}?${chart.toString()}`, {
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin"
      })

      if (res.ok) Turbo.renderStreamMessage(await res.text())
    } catch {
      // Leave the modal closed on failure — the grid behind is still usable.
    }
  }
}
