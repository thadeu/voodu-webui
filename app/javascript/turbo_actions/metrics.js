// Custom Turbo Stream actions broadcast from MetricsSyncIslandJob
// over ActionCable.
//
// metrics_tick fires whenever the job inserts new samples for an
// island. Two effects every tick:
//
//   1. Reload the single `metrics-charts` parent turbo-frame.
//      Server (MetricsController#index, Turbo-Frame branch)
//      returns Views::Metrics::Frame with fresh chart data.
//      Single atomic swap — no flicker, no per-card timing.
//
//   2. If the chart-expand modal is open, refetch its current
//      view too (it lives outside the metrics-charts frame and
//      wouldn't otherwise get the fresh data).

import { Turbo } from "@hotwired/turbo-rails"

Turbo.StreamActions.metrics_tick = function () {
  reloadChartsFrame()
  refreshOpenModal()
}

function reloadChartsFrame() {
  const frame = document.getElementById("metrics-charts")
  if (frame && typeof frame.reload === "function") {
    frame.reload()
  }
}

function refreshOpenModal() {
  const modal = document.getElementById("chart-modal")
  if (!modal || modal.hidden) return

  // The chart-modal-body div stores its current full-path URL as
  // a data attr (set server-side in Views::Metrics::ChartModalBody)
  // so this refresh knows exactly which slice to re-fetch — same
  // metric / scope / range the operator was viewing.
  const body = document.getElementById("chart-modal-body")
  const url = body?.dataset?.refreshUrl
  if (!url) return

  fetch(url, { headers: { Accept: "text/vnd.turbo-stream.html" } })
    .then((r) => r.text())
    .then((html) => Turbo.renderStreamMessage(html))
    .catch(() => {}) // Silent: next tick will retry; broken modal isn't worth surfacing
}
