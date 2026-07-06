import { Controller } from "@hotwired/stimulus"

// ds-select — a DS-styled single-select dropdown backed by a hidden input,
// replacing a native <select>. Pairs with the `dropdown` controller on the
// same element (open/close + optional type-to-filter). Picking a row sets the
// hidden input's value + the trigger label + the active ✓, and dispatches a
// native `change` on the input so anything wired to `change->…` still fires.
export default class extends Controller {
  static targets = ["input", "label", "option"]

  pick(event) {
    const row = event.currentTarget

    this.inputTarget.value = row.dataset.value
    if (this.hasLabelTarget) this.labelTarget.textContent = row.dataset.label

    this.optionTargets.forEach((o) => { o.dataset.active = String(o === row) })

    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }
}
