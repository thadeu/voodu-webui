import { Controller } from "@hotwired/stimulus"

// AutoRefreshController — toggles a page's ActionCable subscription
// on/off via a button. When ON (default): the broadcast tick reloads
// the metrics-charts frame in place. When OFF: subscription is
// dropped, the chart freezes at the last sample until the operator
// either re-enables auto-refresh or hits the manual Refresh button.
//
// Mechanism: Turbo Rails renders the channel subscription as a
// <turbo-cable-stream-source> custom element whose connectedCallback
// subscribes and whose disconnectedCallback unsubscribes. Toggling
// the auto-refresh state physically removes / re-inserts that
// element from the DOM, which makes the subscription lifecycle
// piggyback on the standard custom-element lifecycle — no Cable
// internals to poke at.
//
// State persists across page reloads via localStorage, keyed per
// island (so toggling auto-refresh on island A doesn't bleed into
// island B). NOT URL-state on purpose: this is operator preference,
// not a shareable view, and threading a param through every link
// (refresh / pod picker / range pills / interval picker) would be
// a maintenance burden for a thin payoff.
//
// Visual contract:
//   ON  → green pulsing dot + "auto-refresh"
//   OFF → red static dot + "paused"
//
// Usage in Phlex:
//
//   div(
//     data: {
//       controller: "auto-refresh",
//       auto_refresh_storage_key_value: "voodu:auto-refresh:#{island.id}"
//     }
//   ) do
//     span(data: { auto_refresh_target: "source" }) do
//       turbo_stream_from "metrics-#{island.id}"
//     end
//
//     button(data: { action: "click->auto-refresh#toggle" }) do
//       span(data: { auto_refresh_target: "dot" })
//       span(data: { auto_refresh_target: "label" }) { "auto-refresh" }
//     end
//   end
export default class extends Controller {
  static targets = ["dot", "label", "source"]
  static values  = { storageKey: { type: String, default: "voodu:auto-refresh" } }

  connect() {
    // Hold the detached stream-source element while paused so the
    // exact same node (with its signed-stream-name attribute) is
    // re-inserted on resume — recreating it from scratch would
    // require re-signing the channel name on the server.
    this.detachedSource = null

    this.paused = this.readStored()
    this.applyState()
  }

  toggle(event) {
    event.preventDefault()
    this.paused = !this.paused
    this.writeStored(this.paused)
    this.applyState()
  }

  // ── State application ──────────────────────────────────────────

  applyState() {
    this.applyDot()
    this.applyLabel()
    this.applyCable()
  }

  // Dot: green pulsing when active, red static when paused.
  // Mirrors the inline style the Phlex template seeds with — keep
  // the two definitions in sync if the dot ever changes shape.
  applyDot() {
    if (!this.hasDotTarget) return

    const color = this.paused ? "var(--voodu-red)" : "var(--voodu-green)"
    this.dotTarget.style.background = color
    this.dotTarget.style.boxShadow  = `0 0 0 3px color-mix(in srgb, ${color} 18%, transparent)`

    // Pulse animation only when live — a pulsing red dot would
    // read as "alarm/incident" which is wrong; paused is just paused.
    this.dotTarget.classList.toggle("animate-voodu-pulse", !this.paused)
  }

  applyLabel() {
    if (!this.hasLabelTarget) return

    this.labelTarget.textContent = this.paused ? "paused" : "auto-refresh"
  }

  // Cable: detach the custom element to drop the subscription;
  // re-append to resubscribe. Both legs are idempotent — re-running
  // applyCable() with the same state is a no-op.
  applyCable() {
    if (this.paused) this.detachSource()
    else             this.attachSource()
  }

  detachSource() {
    if (this.detachedSource)  return
    if (!this.hasSourceTarget) return

    const el = this.sourceTarget.querySelector("turbo-cable-stream-source")
    if (!el) return

    this.detachedSource = el
    el.remove()
  }

  attachSource() {
    if (!this.detachedSource) return
    if (!this.hasSourceTarget) return

    this.sourceTarget.appendChild(this.detachedSource)
    this.detachedSource = null
  }

  // ── localStorage round-trip ───────────────────────────────────

  readStored() {
    try {
      return localStorage.getItem(this.storageKeyValue) === "off"
    } catch (_) {
      // Storage disabled (Safari private mode etc.) — default ON.
      return false
    }
  }

  writeStored(paused) {
    try {
      localStorage.setItem(this.storageKeyValue, paused ? "off" : "on")
    } catch (_) {
      // Best-effort persistence; the in-memory toggle still works.
    }
  }
}
