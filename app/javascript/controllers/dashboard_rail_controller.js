import { Controller } from "@hotwired/stimulus"

// DashboardRailController — keeps the dashboards rail highlight in sync
// with whatever the editor turbo-frame currently shows. Clicking a rail
// item swaps ONLY the editor frame, so the rail can't lean on a server
// re-render to move its active marker — it listens for the frame's
// turbo:frame-load and flips data-active on the item whose data-uuid
// matches the loaded dashboard (the Form renders data-dashboard-uuid on
// its root). A "new dashboard" load matches nothing, so every item goes
// inactive — the correct empty-selection state.
export default class extends Controller {
  static targets = ["item"]
  static values = { frame: String }

  connect() {
    this.onLoad = this.onLoad.bind(this)
    this.frame = document.getElementById(this.frameValue)

    if (this.frame) this.frame.addEventListener("turbo:frame-load", this.onLoad)
  }

  disconnect() {
    if (this.frame) this.frame.removeEventListener("turbo:frame-load", this.onLoad)
  }

  onLoad() {
    const inner = this.frame.querySelector("[data-dashboard-uuid]")
    const uuid = inner ? inner.dataset.dashboardUuid : null

    this.itemTargets.forEach((el) => {
      el.dataset.active = String(el.dataset.uuid === uuid)
    })
  }
}
