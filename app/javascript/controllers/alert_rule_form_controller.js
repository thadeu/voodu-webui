// alert-rule-form — keeps the New/Edit alert-rule modal's metric ↔
// target combinations honest while the operator edits:
//
//   disk  → host only (pods have no disk series in the warehouse)
//   req_s → deployments only (ingress samples are per-deployment;
//           the host row and non-deployment workloads grey out)
//
// Also swaps the threshold's unit suffix (% ↔ req/s). Pure
// progressive enhancement — AlertRule's validations are the real
// guard; with JS off the server re-renders the form with the error.

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["metric", "target", "unit"]

  connect() {
    this.metricChanged()
  }

  metricChanged() {
    const metric = this.metricTarget.value

    this.unitTarget.textContent = metric === "req_s" ? "req/s" : "%"
    this.constrainTargets(metric)
  }

  constrainTargets(metric) {
    const options = Array.from(this.targetTarget.options)

    options.forEach((option) => {
      const kind = option.dataset.kind || "deployment"

      if (metric === "disk") {
        option.disabled = kind !== "host"
      } else if (metric === "req_s") {
        option.disabled = kind === "host" || kind !== "deployment"
      } else {
        option.disabled = false
      }
    })

    const selected = this.targetTarget.selectedOptions[0]

    if (selected && selected.disabled) {
      const fallback = options.find((option) => !option.disabled)

      if (fallback) this.targetTarget.value = fallback.value
    }
  }
}
