// Custom Turbo Stream action broadcast from StateSyncIslandJob.
//
// state_tick fires after every sync attempt (success OR failure)
// to push the new snapshot into the operator's open browser tabs.
// Sibling of `metrics_tick` — same "reload the frame" mechanic,
// different data slice:
//
//   metrics_tick  → time-series chart frame (every 14s)
//   state_tick    → runtime / system snapshot frames (every 10s)
//
// Effect: every `<turbo-frame>` on the page that opts in via
// `data-state-frame` gets a `.reload()`. The frame's own `src=`
// attribute carries the operator's CURRENT URL (set on initial
// render via current_request_url), so the refetch preserves
// filters, scope pickers, range pills, etc. — no need to encode
// any of that state in the broadcast itself.
//
// Pages that need to be live-refreshed:
//   - Dashboard overview body (stat cards + pods table + stale banner)
//   - /pods page (table + page header running counts)
//
// Pages that DON'T opt in keep their static, last-load state until
// the operator navigates — fine for /logs (live tail handles its own
// stream), Settings (operator-driven actions), /metrics (already on
// metrics_tick).

import { Turbo } from "@hotwired/turbo-rails"

Turbo.StreamActions.state_tick = function () {
  document.querySelectorAll("turbo-frame[data-state-frame]").forEach((frame) => {
    // Server renders the frame without src= (avoids the auto-fetch
    // on connect that was blanking the body briefly). Set src here
    // so reload() knows where to refetch — and we use the page's
    // current URL so filters / query params are preserved.
    if (!frame.src) frame.src = window.location.href

    if (typeof frame.reload === "function") frame.reload()
  })
}
