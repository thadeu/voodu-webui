import { Controller } from "@hotwired/stimulus"

// PollingController reloads the nested <turbo-frame> on a fixed
// interval. Used by the logs view to give a "live tail" feel without
// opening a WebSocket — Turbo Frame fetch is cheap and the controller
// already cached the response on the server.
//
// Usage:
//
//   <div data-controller="polling" data-polling-interval-value="5000">
//     <turbo-frame id="logs" src="/logs/foo?frame=logs"></turbo-frame>
//   </div>
//
// The frame is reloaded by calling .reload() — Turbo 7+ fetches the
// same `src` again and swaps the inner HTML. No flash, no scroll
// reset.
export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.paused = 0
    this.timer = setInterval(() => this.tick(), this.intervalValue)

    // Pause/resume hooks so other controllers (e.g. chart-expand
    // when its modal is open) can suspend reloads without us
    // tearing down the timer. Multiple pauses stack — counter
    // reaches 0 again before the polling resumes. Documented as
    // global window events so unrelated controllers don't need a
    // Stimulus target reference into us.
    this.onPause  = () => { this.paused += 1 }
    this.onResume = () => { this.paused = Math.max(0, this.paused - 1) }
    window.addEventListener("polling:pause",  this.onPause)
    window.addEventListener("polling:resume", this.onResume)
  }

  disconnect() {
    clearInterval(this.timer)
    window.removeEventListener("polling:pause",  this.onPause)
    window.removeEventListener("polling:resume", this.onResume)
  }

  tick() {
    if (this.paused > 0) return

    // Reload LEAF turbo-frames only — i.e. frames that don't
    // wrap other turbo-frames.
    //
    // Why: the /metrics page nests N per-card `<turbo-frame>`
    // inside a parent `<turbo-frame id="metrics-charts">`. If we
    // reloaded the parent, the server response would re-emit
    // skeleton placeholders for every card, then each card's
    // lazy frame would fire its own fetch — causing a visible
    // skeleton flash on every poll tick. Reloading the leaves
    // directly refreshes the data in place without disrupting
    // the rendered chart underneath.
    //
    // The /logs page has a single inner frame (no nesting), so
    // it's a leaf too — same code path covers both surfaces
    // without per-page branching.
    const frames = this.element.querySelectorAll("turbo-frame")
    frames.forEach((frame) => {
      if (frame.querySelector("turbo-frame")) return // skip parents
      if (typeof frame.reload === "function") frame.reload()
    })
  }
}
