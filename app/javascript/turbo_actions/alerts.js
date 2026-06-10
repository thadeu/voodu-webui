// Custom Turbo Stream action broadcast by AlertsLive whenever a rule
// fires or resolves (evaluator transition, pause of a firing rule,
// delete of a firing rule).
//
// The badge spans update via plain Turbo `update` broadcasts on the
// island-state channel — no JS needed. This action covers the /alerts
// page itself: reload the `alerts-live` frame so firing cards, the
// rules table, and history reflect the transition without a refresh.

import { Turbo } from "@hotwired/turbo-rails"

Turbo.StreamActions.alerts_tick = function () {
  const frame = document.getElementById("alerts-live")
  if (frame && typeof frame.reload === "function") {
    frame.reload()
  }
}
