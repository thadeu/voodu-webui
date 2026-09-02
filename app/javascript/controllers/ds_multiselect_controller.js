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

    // The selection as last COMMITTED, so closing a menu nobody touched does
    // not fire a pointless submit.
    this.committed = this.selection()

    // Paired with the `dropdown` controller on the same element, so its close
    // event arrives here without either controller knowing about the other's
    // internals.
    this.onClose = () => this.commit()
    this.element.addEventListener("dropdown:close", this.onClose)
  }

  disconnect() {
    this.element.removeEventListener("dropdown:close", this.onClose)
  }

  // commit — announce the selection ONCE, when the menu closes.
  //
  // Not on every change, which is the obvious alternative and the wrong one: a
  // listener that reloads the page on each tick replaces this menu mid-use, so
  // the operator picks one option and the dropdown vanishes. A multi-select
  // where you cannot select multiple is not one.
  commit() {
    const current = this.selection()
    if (current === this.committed) return

    this.committed = current
    this.dispatch("commit")
  }

  selection() {
    return this.optionTargets.filter((o) => o.checked).map((o) => o.value).join(",")
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
  //
  // Assigning `.checked` fires NOTHING: the change event belongs to user
  // interaction, not to the property. Anything listening for it — a form that
  // applies filters, a dirty-state guard — simply never hears about the most
  // sweeping edit the menu offers. So the event is dispatched by hand.
  toggleAll() {
    const allChecked = this.optionTargets.length > 0 && this.optionTargets.every((o) => o.checked)

    this.optionTargets.forEach((o) => {
      o.checked = !allChecked
      o.dispatchEvent(new Event("change", { bubbles: true }))
    })

    this.sync()
  }
}
