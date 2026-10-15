// alert-rule-form — keeps the New/Edit alert-rule modal's metric ↔ target
// combinations honest while the operator edits, and drives the target as a DS
// custom dropdown (a hidden input + a filterable menu, not a native <select>):
//
//   pickTarget — a menu row → hidden input + trigger label + active ✓.
//   metricChanged:
//     disk  → host only (pods have no disk series in the warehouse)
//     req_s → deployments only (ingress samples are per-deployment; the host
//             row + non-deployment workloads dim out)
//     a plugin metric → the Host row of a server with that plugin
//     a fixed-condition metric (FreeSWITCH unavailable) → no threshold: the
//       condition inputs give way to a sentence
//     also swaps the threshold's unit suffix.
//
// Which metric needs which plugin, the units and the fixed-condition metrics
// come from the server (AlertRule::PLUGIN_FOR / UNITS / FIXED_CONDITION_KINDS)
// as values: a plugin that adds alert metrics needs no change here.
//
// Pure progressive enhancement — AlertRule's validations are the real guard.

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["metric", "target", "targetLabel", "unit", "option", "condition", "downNote", "threshold"]
  static values = { plugins: Object, units: Object, fixed: Array }

  connect() {
    this.metricChanged()
  }

  // pickTarget — a menu row was clicked: adopt its value + label (unless the
  // current metric disabled it).
  pickTarget(event) {
    const row = event.currentTarget

    if (row.dataset.disabled === "true") return

    this.select(row.dataset.value, row.dataset.label)
  }

  select(value, label) {
    this.targetTarget.value = value
    if (this.hasTargetLabelTarget) this.targetLabelTarget.textContent = label
    this.markActive(value)
  }

  markActive(value) {
    this.optionTargets.forEach((opt) => {
      const active = opt.dataset.value === value && opt.dataset.disabled !== "true"

      opt.dataset.active = String(active)
      const check = opt.querySelector("[data-alert-rule-form-target='optionCheck']")

      if (check) check.textContent = active ? "✓" : ""
    })
  }

  metricChanged() {
    const metric = this.metricTarget.value

    this.unitTarget.textContent = metric in this.unitsValue ? this.unitsValue[metric] : "%"
    this.toggleCondition(this.fixedValue.includes(metric))
    this.constrainTargets(metric)
  }

  // toggleCondition — a fixed-condition metric's condition is pinned, so the direction +
  // threshold inputs hide behind a sentence. The threshold keeps a valid value
  // so a hidden field never blocks the submit.
  toggleCondition(down) {
    if (this.hasConditionTarget) this.conditionTarget.hidden = down
    if (this.hasDownNoteTarget) this.downNoteTarget.hidden = !down
    if (down && this.hasThresholdTarget && !this.thresholdTarget.value) this.thresholdTarget.value = "1"
  }

  // constrainTargets — dim the rows an incompatible metric can't target; if the
  // current pick becomes disabled, fall back to the first enabled row.
  constrainTargets(metric) {
    let firstEnabled = null

    this.optionTargets.forEach((opt) => {
      const kind = opt.dataset.kind || "deployment"
      let disabled = false

      if (metric === "disk") disabled = kind !== "host"
      else if (metric === "req_s") disabled = kind !== "deployment"
      else if (this.pluginsValue[metric]) {
        const installed = (opt.dataset.plugins || "").split(" ")

        disabled = kind !== "host" || !installed.includes(this.pluginsValue[metric])
      }

      opt.dataset.disabled = String(disabled)
      if (!disabled && !firstEnabled) firstEnabled = opt
    })

    const current = this.optionTargets.find((o) => o.dataset.value === this.targetTarget.value)

    if ((!current || current.dataset.disabled === "true") && firstEnabled) {
      this.select(firstEnabled.dataset.value, firstEnabled.dataset.label)
    } else {
      this.markActive(this.targetTarget.value)
    }
  }
}
