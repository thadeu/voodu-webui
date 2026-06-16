import { Controller } from "@hotwired/stimulus"

// metric-multiselect — multi-select dashboards inline in the switcher
// dropdown. Toggling a row flips it in place (NO navigation per click)
// and appends/removes it from an ordered selection. "View selected"
// navigates once to ?pid=<uuid,uuid> in SELECTION ORDER so the stacked
// /metrics view renders them top-to-bottom as the operator picked them.
//
// Initial selection comes from the server (selectedValue = current
// ?pid order) so reopening the dropdown reflects what's on screen.
export default class extends Controller {
  static targets = ["row", "apply", "summary"]
  static values = { base: String, selected: String }

  connect() {
    this.selected = this.selectedValue
      ? this.selectedValue.split(",").filter(Boolean)
      : []

    this.refresh()
  }

  toggle(event) {
    const uuid = event.currentTarget.dataset.uuid
    const at = this.selected.indexOf(uuid)

    if (at >= 0) {
      this.selected.splice(at, 1)
    } else {
      this.selected.push(uuid)
    }

    this.refresh()
  }

  apply(event) {
    event.preventDefault()

    const url = this.selected.length
      ? `${this.baseValue}?pid=${this.selected.join(",")}`
      : this.baseValue

    if (window.Turbo) {
      window.Turbo.visit(url)
    } else {
      window.location.href = url
    }
  }

  refresh() {
    const set = new Set(this.selected)

    this.rowTargets.forEach((row) => {
      const on = set.has(row.dataset.uuid)
      const box = row.querySelector("[data-role='checkbox']")
      const check = row.querySelector("[data-role='check']")

      row.dataset.checked = on ? "true" : "false"

      if (box) {
        box.classList.toggle("border-voodu-accent-line", on)
        box.classList.toggle("bg-voodu-accent-dim", on)
        box.classList.toggle("border-voodu-border", !on)
      }

      if (check) check.classList.toggle("hidden", !on)
    })

    if (this.hasSummaryTarget) {
      const n = this.selected.length

      this.summaryTarget.textContent =
        n === 0 ? "View selected" : n === 1 ? "View 1 dashboard" : `View ${n} dashboards`
    }
  }
}
