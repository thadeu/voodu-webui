import { Controller } from "@hotwired/stimulus"

// metrics-section — collapse / expand a dashboard group on the Metrics page.
//
// "Collapse" hides the chart body via CSS (the body stays in the DOM), so the
// 30s polling tick keeps refreshing it underneath — re-expanding shows live
// data, not a stale snapshot. The header (label + panel count + actions) stays
// put. The eye icon flips to eye-slash while collapsed.
//
// State persists per section id in sessionStorage and re-applies on connect —
// connect() fires on first mount AND after every turbo-frame swap (the tick
// reloads the whole metrics-charts frame), so a collapsed group stays collapsed
// across refreshes.
//
//   <div data-controller="metrics-section" data-metrics-section-id-value="<uuid>">
//     <div> … header … <button data-action="click->metrics-section#toggle">eye</button></div>
//     <div data-metrics-section-target="body"> … grid … </div>
//   </div>
const STORE_KEY = "voodu:metrics:collapsed"

export default class extends Controller {
  static targets = ["body"]
  static values  = { id: String }

  connect() {
    this.apply(this.collapsed())
  }

  toggle() {
    const next = !this.collapsed()

    this.persist(next)
    this.apply(next)
  }

  apply(collapsed) {
    if (this.hasBodyTarget) this.bodyTarget.hidden = collapsed
    this.element.dataset.collapsed = collapsed ? "true" : "false"

    const open = this.element.querySelector("[data-role='eye-open']")
    const shut = this.element.querySelector("[data-role='eye-closed']")

    if (open) open.classList.toggle("hidden", collapsed)
    if (shut) shut.classList.toggle("hidden", !collapsed)
  }

  collapsed() {
    return this.read().includes(this.idValue)
  }

  persist(collapsed) {
    const set = new Set(this.read())

    if (collapsed) {
      set.add(this.idValue)
    } else {
      set.delete(this.idValue)
    }

    try {
      sessionStorage.setItem(STORE_KEY, JSON.stringify([...set]))
    } catch (_e) {
      // sessionStorage disabled — collapse still works for this view, just
      // won't survive the next frame swap.
    }
  }

  read() {
    try {
      return JSON.parse(sessionStorage.getItem(STORE_KEY) || "[]")
    } catch (_e) {
      return []
    }
  }
}
