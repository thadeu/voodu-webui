import { Controller } from "@hotwired/stimulus"
import { panelPref, setPanelPref } from "../lib/panel_prefs"

// PanelOptionsController — the per-panel options popover menu (the triple-dot
// next to a chart's maximize button). Rendered only for chart types that have
// options (today: Line, one "Show dots" toggle).
//
// It owns the PREFERENCE, not the rendering: on toggle it persists the pref
// (sessionStorage, via panel_prefs) and dispatches a `panel-options:change`
// event on window carrying { key, dots }. The matching metrics-chart controller
// (keyed by the same panel key) listens for that and shows/hides its dots live.
// Decoupling via a window event — not a Stimulus outlet — is deliberate: the
// popover portals its menu out to <body> on open (to escape overflow clipping),
// so a direct DOM/controller link to the chart wouldn't survive.
export default class extends Controller {
  static targets = ["dots"]
  static values  = { key: String }

  connect() {
    // Reflect the stored pref onto the checkbox (server renders it checked =
    // dots shown by default).
    if (this.hasDotsTarget) this.dotsTarget.checked = panelPref(this.keyValue, "dots", true)
  }

  toggleDots() {
    const show = this.hasDotsTarget ? this.dotsTarget.checked : true

    // Persist only the override (dots hidden); clearing on "shown" keeps the
    // default implicit + the store small.
    setPanelPref(this.keyValue, "dots", show ? null : false)

    window.dispatchEvent(new CustomEvent("panel-options:change", {
      detail: { key: this.keyValue, dots: show }
    }))
  }
}
