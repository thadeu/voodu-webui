import { Controller } from "@hotwired/stimulus"

// UpdatedAtController — keeps a "Ns ago / Nm ago" label live on the
// page without server polling.
//
// Markup:
//
//   <a data-controller="updated-at"
//      data-updated-at-iso-value="2026-05-23T22:14:09Z"
//      data-action="click->updated-at#refresh"
//      href="?refresh=1">
//     <span data-updated-at-target="label">now</span>
//   </a>
//
// Per-second tick:
//   The label re-renders every 1000ms from a single root timer (one
//   per controller instance — the topbar only has one of these, so
//   there's no setInterval explosion to worry about).
//
// Click behaviour:
//   `click->updated-at#refresh` navigates to `?refresh=1` so the
//   page rebuilds with a cache bypass. The Rails OverviewData hook
//   on `?refresh=1` deletes the per-island snapshot cache; the next
//   render fetches fresh /system + /pods. Replaces the old "Refresh
//   all" button — the updated chip IS the refresh affordance now.
//
// Cleanup:
//   disconnect() clears the timer; Turbo navigation removes the DOM,
//   which fires disconnect, so no zombie timers between pages.
export default class extends Controller {
  static values  = { iso: String }
  static targets = ["label"]

  connect() {
    this.render()
    this.timer = setInterval(() => this.render(), 1000)
  }

  disconnect() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }

  // refresh — click handler. We don't preventDefault because the
  // anchor's own href ("?refresh=1") is the navigation we want; the
  // Stimulus action is here so a future extension (toast feedback,
  // optimistic UI, etc.) has a hook without needing markup changes.
  refresh(_event) {
    // Intentionally empty — the anchor href performs the navigation.
    // Method exists so `data-action="click->updated-at#refresh"` is
    // valid markup; lets us add UX polish later without changing
    // the topbar layout.
  }

  render() {
    if (!this.hasLabelTarget || !this.isoValue) return

    const ts   = Date.parse(this.isoValue)

    if (Number.isNaN(ts)) return

    const secs = Math.max(0, Math.floor((Date.now() - ts) / 1000))

    this.labelTarget.textContent = formatAge(secs)
  }
}

// formatAge — same rounding the topbar uses pre-ticker:
//   < 60s   → "Ns"
//   < 60m   → "Nm"
//   < 24h   → "Nh"
//   else    → "Nd"
// "now" when the timestamp is in the future or zero — happens
// briefly on cache writes where the ISO was just set.
function formatAge(secs) {
  if (secs <= 0)     return "now"
  if (secs < 60)     return `${secs}s`
  if (secs < 3600)   return `${Math.floor(secs / 60)}m`
  if (secs < 86400)  return `${Math.floor(secs / 3600)}h`

  return `${Math.floor(secs / 86400)}d`
}
