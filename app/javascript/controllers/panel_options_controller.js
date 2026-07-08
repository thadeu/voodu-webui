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

    // Keyboard: while THIS popover is open, "B" toggles Show dots (the kbd hint
    // in the row). Guard on the menu (this.element) being shown so a stray "B"
    // elsewhere never fires it.
    this.onKey = (e) => this.handleKey(e)
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    if (this.onKey) document.removeEventListener("keydown", this.onKey)
  }

  handleKey(e) {
    if (this.element.hidden) return
    if (e.metaKey || e.ctrlKey || e.altKey) return
    if (e.key.toLowerCase() !== "b") return

    const t = e.target

    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return
    if (!this.hasDotsTarget) return

    e.preventDefault()
    this.dotsTarget.checked = !this.dotsTarget.checked
    this.toggleDots()
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
