import { Controller } from "@hotwired/stimulus"

// hep3-call-flow — page host for the SIP call-flow overlay.
//
// Listens (at the window) for a DataTable row's `datatable:rowaction` with
// event "callflow", fetches the ladder fragment for that corr_id, and drops
// it into the host — the same fetch→inject the Logs "surrounding" modal uses.
// The injected fragment is a UI::Modal whose modal_controller emits
// `modal:close`; on that we clear the host (the modal only fires the event).
//
// URL state: the open call is mirrored into cf_* query params (replaceState),
// so a full reload (F5) re-opens the same call. `connect` re-opens from the
// URL; `close` strips the params.
export default class extends Controller {
  static targets = ["host"]
  static values = { url: String }

  PARAMS = ["cf_scope", "cf_name", "cf_corr", "cf_focus"]

  connect() {
    this.onAction = this.onAction.bind(this)
    this.onClose = this.onClose.bind(this)
    window.addEventListener("datatable:rowaction", this.onAction)
    this.element.addEventListener("modal:close", this.onClose)

    this.openFromUrl()
  }

  disconnect() {
    window.removeEventListener("datatable:rowaction", this.onAction)
    this.element.removeEventListener("modal:close", this.onClose)
  }

  async onAction(event) {
    const detail = event.detail || {}

    if (detail.event !== "callflow") return

    this.syncUrl(detail)
    await this.fetchInto(detail)
  }

  // openFromUrl — reopen the call encoded in the URL after a full reload.
  openFromUrl() {
    const p = new URLSearchParams(window.location.search)
    const corr = p.get("cf_corr")

    if (!corr) return

    this.fetchInto({
      scope: p.get("cf_scope") || "",
      name: p.get("cf_name") || "",
      value: corr,
      rowId: p.get("cf_focus") || "",
    })
  }

  async fetchInto(detail) {
    const params = new URLSearchParams({
      scope: detail.scope || "",
      name: detail.name || "",
      corr_id: detail.value || "",
    })

    if (detail.rowId) params.set("focus", detail.rowId)

    try {
      const resp = await fetch(`${this.urlValue}?${params}`, { headers: { Accept: "text/html" } })

      if (!resp.ok) return

      this.hostTarget.innerHTML = await resp.text()
    } catch (_e) {
      // network / teardown — leave the host untouched; the operator retries.
    }
  }

  onClose() {
    this.hostTarget.innerHTML = ""
    this.clearUrl()
  }

  // ── URL state (replaceState — no history spam; F5 reopens) ─────────

  syncUrl(detail) {
    const url = new URL(window.location.href)

    url.searchParams.set("cf_scope", detail.scope || "")
    url.searchParams.set("cf_name", detail.name || "")
    url.searchParams.set("cf_corr", detail.value || "")

    if (detail.rowId) {
      url.searchParams.set("cf_focus", detail.rowId)
    } else {
      url.searchParams.delete("cf_focus")
    }

    window.history.replaceState(window.history.state, "", url)
  }

  clearUrl() {
    const url = new URL(window.location.href)

    this.PARAMS.forEach((k) => url.searchParams.delete(k))
    window.history.replaceState(window.history.state, "", url)
  }
}
