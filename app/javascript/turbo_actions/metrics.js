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

// Frame-reload pauses stack, same `polling:pause`/`resume` convention the
// polling controller uses. A reload swaps the WHOLE metrics-charts frame,
// which would tear an in-progress interaction out from under the operator
// (e.g. typing a filter into a Table panel's toolbar). Anyone editing raises
// a pause; the tick then skips the reload until it's released.
let frameReloadPauses = 0

window.addEventListener("polling:pause", () => { frameReloadPauses += 1 })
window.addEventListener("polling:resume", () => { frameReloadPauses = Math.max(0, frameReloadPauses - 1) })

Turbo.StreamActions.metrics_tick = function () {
  reloadChartsFrame()
  refreshOpenModal()
}

function reloadChartsFrame() {
  if (frameReloadPauses > 0) return

  const frame = document.getElementById("metrics-charts")

  if (!frame || typeof frame.reload !== "function") return

  // Preserve the scroll across the swap. Replacing the frame's content briefly
  // collapses its height, which clamps the scroll container to the top when the
  // operator is reading a panel far down. The page scrolls inside <main> (not
  // window), so capture whichever element actually scrolls and restore the
  // instant the new content renders (before paint → no visible jump).
  const scroller = scrollParent(frame)
  const y = scroller ? scroller.scrollTop : window.scrollY

  const restore = () => {
    setScroll(scroller, y)
    requestAnimationFrame(() => setScroll(scroller, y))
  }

  frame.addEventListener("turbo:frame-render", restore, { once: true })
  frame.reload()
}

// scrollParent — the nearest scrollable ancestor of `el` (the metrics content
// lives inside a `<main class="overflow-auto">`, not the window). null → window.
function scrollParent(el) {
  let n = el.parentElement

  while (n && n !== document.body) {
    const overflowY = getComputedStyle(n).overflowY

    if ((overflowY === "auto" || overflowY === "scroll") && n.scrollHeight > n.clientHeight) return n

    n = n.parentElement
  }

  return null
}

function setScroll(scroller, y) {
  if (scroller) scroller.scrollTop = y
  else window.scrollTo(0, y)
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

  // Silent catch: the next tick retries; a broken modal isn't worth surfacing.
  fetch(url, { headers: { Accept: "text/vnd.turbo-stream.html" } })
    .then((r) => r.text())
    .then((html) => Turbo.renderStreamMessage(html))
    .catch(() => {})
}
