import { Controller } from "@hotwired/stimulus"
import { panelPref } from "../lib/panel_prefs"

// NumberCardController — the per-panel "Show timeline" toggle for a Number tile.
// Mirrors how metrics-chart handles "Show dots": it owns the live SHOW/HIDE, not
// the saved default. The options popover (panel-options) persists the pref +
// dispatches `panel-options:change` with { key, timeline }; this controller —
// keyed by the same panel key — hides or reveals its sparkline live.
//
// On a MULTI-pod tile it ALSO resizes the stats: with no timeline the numbers
// own the whole card, so they scale up (container-query sized, same rule as a
// saved no-timeline panel) — big ONLY while the timeline is hidden. The saved
// default sets the initial state; this is a browser-local override, so a reload
// / stream-refresh keeps the operator's choice.
export default class extends Controller {
  static targets = ["timeline", "stat", "caption"]
  static values  = { key: String, statSize: String, captionSize: String }

  connect() {
    this.applyTimeline(panelPref(this.keyValue, "timeline", true))

    this.onPanelOptions = (e) => {
      if (e.detail?.key === this.keyValue && "timeline" in (e.detail || {})) this.applyTimeline(e.detail.timeline)
    }

    window.addEventListener("panel-options:change", this.onPanelOptions)
  }

  disconnect() {
    if (this.onPanelOptions) window.removeEventListener("panel-options:change", this.onPanelOptions)
  }

  applyTimeline(show) {
    if (this.hasTimelineTarget) this.timelineTarget.hidden = !show

    // No timeline → the stats fill the card (scaled up); timeline back → clear
    // the override so the server's modest size returns. statSize/captionSize are
    // only set on a multi tile, so a single tile just shows/hides its sparkline.
    const stat = show ? "" : this.statSizeValue
    const caption = show ? "" : this.captionSizeValue

    this.statTargets.forEach((el) => { el.style.fontSize = stat })
    this.captionTargets.forEach((el) => { el.style.fontSize = caption })
  }
}
