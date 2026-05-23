import { Controller } from "@hotwired/stimulus"

// KvFilterController — local "filter as you type" over a list of
// key/value rows. No round-trip. The whole list is already in the DOM;
// we hide rows whose key OR value doesn't match the query.
//
// Markup:
//
//   <div data-controller="kv-filter">
//     <input data-kv-filter-target="input" data-action="input->kv-filter#filter">
//     <div data-kv-filter-target="list">
//       <div data-kv-filter-target="row" data-key="..." data-value="...">...</div>
//       ...
//     </div>
//     <div data-kv-filter-target="empty" hidden>no keys match.</div>
//   </div>
//
// Each row carries `data-key` + `data-value` (pre-lowercased server-
// side) — the controller does plain `.includes()` checks.
export default class extends Controller {
  static targets = ["input", "list", "row", "empty"]

  filter() {
    const q = (this.inputTarget.value || "").trim().toLowerCase()
    let visible = 0

    for (const row of this.rowTargets) {
      const k = row.dataset.key || ""
      const v = row.dataset.value || ""
      const match = !q || k.includes(q) || v.includes(q)
      row.hidden = !match
      if (match) visible++
    }

    if (this.hasEmptyTarget) this.emptyTarget.hidden = visible > 0
  }
}
