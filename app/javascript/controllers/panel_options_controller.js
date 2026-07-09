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
  static targets = ["dots", "timeline"]
  static values  = { key: String }

  connect() {
    // Reflect the stored prefs onto the switches (server renders them checked =
    // shown by default). A menu carries only the target its card supports:
    // Line → dots, Number → timeline.
    if (this.hasDotsTarget) this.dotsTarget.checked = panelPref(this.keyValue, "dots", true)
    if (this.hasTimelineTarget) this.timelineTarget.checked = panelPref(this.keyValue, "timeline", true)

    // Keyboard: while THIS popover is open, its kbd hint fires the toggle —
    // "D" (dots) on a Line, "T" (timeline) on a Number. Guard on the menu
    // (this.element) being shown so a stray key elsewhere never fires it.
    this.onKey = (e) => this.handleKey(e)
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    if (this.onKey) document.removeEventListener("keydown", this.onKey)
  }

  handleKey(e) {
    if (this.element.hidden) return
    if (e.metaKey || e.ctrlKey || e.altKey) return

    const t = e.target

    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return

    const key = e.key.toLowerCase()

    if (key === "d" && this.hasDotsTarget) {
      e.preventDefault()
      this.dotsTarget.checked = !this.dotsTarget.checked
      this.toggleDots()
    } else if (key === "t" && this.hasTimelineTarget) {
      e.preventDefault()
      this.timelineTarget.checked = !this.timelineTarget.checked
      this.toggleTimeline()
    }
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

  toggleTimeline() {
    const show = this.hasTimelineTarget ? this.timelineTarget.checked : true

    setPanelPref(this.keyValue, "timeline", show ? null : false)

    window.dispatchEvent(new CustomEvent("panel-options:change", {
      detail: { key: this.keyValue, timeline: show }
    }))
  }
}
