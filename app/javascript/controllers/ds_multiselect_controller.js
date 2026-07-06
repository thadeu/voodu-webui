import { Controller } from "@hotwired/stimulus"

// ds-multiselect — a DS multi-select dropdown backed by REAL checkboxes, so the
// form submits them exactly like a checkbox group (no hidden mirroring). Pairs
// with the `dropdown` controller on the same element (open/close). Picking rows
// keeps the menu open; the trigger label reflects the selection ("All …" when
// none, the single name, or "N selected"), and a Select all / Clear toggle
// flips the whole set. Empty selection is meaningful (the caller decides what
// "none" means — e.g. "notify all destinations").
export default class extends Controller {
  static targets = ["label", "option", "selectAllLabel"]
  // emptyLabel — shown when NOTHING is picked (the "none" meaning is the
  // caller's, e.g. "Don't send"). allLabel — shown when EVERY row is picked
  // (e.g. "All destinations").
  static values = { emptyLabel: String, allLabel: String }

  connect() {
    this.sync()
  }

  sync() {
    const checked = this.optionTargets.filter((o) => o.checked)

    if (this.hasLabelTarget) this.labelTarget.textContent = this.labelFor(checked)

    if (this.hasSelectAllLabelTarget) {
      const all = this.optionTargets.length > 0 && checked.length === this.optionTargets.length

      this.selectAllLabelTarget.textContent = all ? "Clear" : "Select all"
    }
  }

  labelFor(checked) {
    if (checked.length === 0) return this.emptyLabelValue || "None"

    const all = this.optionTargets.length > 0 && checked.length === this.optionTargets.length

    if (all) return this.allLabelValue || `${checked.length} selected`
    if (checked.length === 1) return checked[0].dataset.label

    return `${checked.length} selected`
  }

  // toggleAll — check every row, or clear them all when they're already all on.
  toggleAll() {
    const allChecked = this.optionTargets.length > 0 && this.optionTargets.every((o) => o.checked)

    this.optionTargets.forEach((o) => { o.checked = !allChecked })
    this.sync()
  }
}
