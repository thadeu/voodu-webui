// destination-form — shows the right fields per destination kind in
// the New/Edit destination modal:
//
//   slack    → Webhook URL
//   webhook  → Webhook URL + optional auth header (name/value)
//   telegram → Bot token + Chat ID
//
// Hidden field groups are also DISABLED so their inputs don't submit.
// This matters because the webhook auth-value and the telegram bot
// token both post as alert_destination[secret] — only the active
// kind's input may be in the request, or they'd clobber each other.
//
// Pure progressive enhancement; AlertDestination's validations are
// the real guard.

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["kind", "urlWrap", "authWrap", "bodyWrap", "telegramWrap", "endpointHint"]

  connect() {
    this.kindChanged()
  }

  kindChanged() {
    const kind = this.kindTarget.value

    this.setWrap(this.hasUrlWrapTarget && this.urlWrapTarget, kind === "slack" || kind === "webhook")
    this.setWrap(this.hasAuthWrapTarget && this.authWrapTarget, kind === "webhook")
    this.setWrap(this.hasBodyWrapTarget && this.bodyWrapTarget, kind === "webhook")
    this.setWrap(this.hasTelegramWrapTarget && this.telegramWrapTarget, kind === "telegram")

    if (this.hasEndpointHintTarget) {
      this.endpointHintTarget.textContent =
        kind === "slack"
          ? "The Slack incoming-webhook URL (https://hooks.slack.com/…)."
          : "The endpoint we POST the JSON payload to (http or https)."
    }
  }

  // setWrap — toggle a group's visibility AND the disabled state of
  // its inputs, so hidden fields never serialize.
  setWrap(wrap, visible) {
    if (!wrap) return

    wrap.hidden = !visible
    wrap.querySelectorAll("input, select, textarea").forEach((el) => {
      el.disabled = !visible
    })
  }
}
