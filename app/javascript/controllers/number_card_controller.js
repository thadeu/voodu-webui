import { Controller } from "@hotwired/stimulus"
import { panelPref } from "../lib/panel_prefs"

// NumberCardController — the per-panel "Show timeline" toggle for a Number tile
// (the sparkline under the headline). Mirrors how metrics-chart handles "Show
// dots": it owns the live SHOW/HIDE, not the saved default. The options popover
// (panel-options) persists the pref + dispatches `panel-options:change` with
// { key, timeline }; this controller — keyed by the same panel key — hides or
// reveals its sparkline live. The saved `show_chart` sets the default; this is a
// browser-local override, so a reload/stream-refresh keeps the operator's choice.
export default class extends Controller {
  static targets = ["timeline"]
  static values  = { key: String }

  connect() {
    if (this.hasTimelineTarget) this.applyTimeline(panelPref(this.keyValue, "timeline", true))

    this.onPanelOptions = (e) => {
      if (e.detail?.key === this.keyValue && "timeline" in (e.detail || {})) this.applyTimeline(e.detail.timeline)
    }

    window.addEventListener("panel-options:change", this.onPanelOptions)
  }

  disconnect() {
    if (this.onPanelOptions) window.removeEventListener("panel-options:change", this.onPanelOptions)
  }

  applyTimeline(show) {
    if (!this.hasTimelineTarget) return

    this.timelineTarget.hidden = !show
  }
}
