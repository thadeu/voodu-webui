// Custom Turbo Stream actions for the chart-expand modal.
//
// Why custom actions and not just `<div hidden>` + style toggles:
// the server-side controller for /metrics/chart should be able to
// say "open this modal" in the SAME turbo_stream response that
// fills it with content. Without custom actions, opening the modal
// would require a separate JS round-trip (the response renders
// content; some glue code then unhides). With them:
//
//   render turbo_stream: [
//     turbo_stream.update("chart-modal-title", label),
//     turbo_stream.replace("chart-modal-body", view),
//     turbo_stream.action(:chart_modal_open)
//   ]
//
// The modal lives at id="chart-modal" — a single shared element
// rendered once at the bottom of the metrics page. NO per-card
// duplication, NO portal hack: the modal is a sibling of the
// page chrome from the start, so the underlying turbo-frame
// polling tick can't touch it.
//
// Companion `chart-modal` Stimulus controller (chart_modal_controller.js)
// owns the interactive concerns (ESC, backdrop click, scroll-lock,
// polling pause). These Turbo Actions are PURELY visibility — the
// minimum the server needs to drive the modal lifecycle.

import { Turbo } from "@hotwired/turbo-rails"

// Both actions read the target from the <turbo-stream> tag itself
// (`this.targetElements`) — set server-side via:
//
//   turbo_stream.action(:chart_modal_open, "chart-modal")
//
// Conventional Turbo Stream semantics: action elements receive
// `this.targetElements` from `target=` / `targets=` attrs. We
// take the first match so the server stays in control of which
// element the action operates on.
Turbo.StreamActions.chart_modal_open = function () {
  const modal = this.targetElements[0]
  if (!modal) return

  modal.removeAttribute("hidden")
  // Dispatch a DOM event the Stimulus controller can listen to
  // for side effects (scroll-lock, ESC binding, polling pause).
  // Keeps "open the modal visually" decoupled from "lock the
  // page" — multiple sources can drive open without each one
  // re-implementing the side effects.
  modal.dispatchEvent(new CustomEvent("chart-modal:opened", { bubbles: true }))
}

Turbo.StreamActions.chart_modal_close = function () {
  const modal = this.targetElements[0]
  if (!modal) return

  modal.setAttribute("hidden", "")
  modal.dispatchEvent(new CustomEvent("chart-modal:closed", { bubbles: true }))
}
