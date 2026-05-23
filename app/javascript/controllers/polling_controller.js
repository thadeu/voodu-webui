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
    this.timer = setInterval(() => this.tick(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  tick() {
    const frame = this.element.querySelector("turbo-frame")
    if (frame && typeof frame.reload === "function") frame.reload()
  }
}
