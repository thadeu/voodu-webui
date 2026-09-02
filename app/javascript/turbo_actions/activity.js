// Custom Turbo Stream action broadcast by ActivityDigestService whenever the
// poller lands a batch of actions for a server.
//
// Reloads the activity table so an action that was still running closes itself
// on screen — the one state on that page that moves without the operator
// doing anything.

import { Turbo } from "@hotwired/turbo-rails"

Turbo.StreamActions.activity_tick = function () {
  const frame = document.getElementById("activity-table")

  if (frame && typeof frame.reload === "function") {
    frame.reload()
  }
}
