import { Controller } from "@hotwired/stimulus"

// fswapi-call-flow — the FreeSWITCH → HEP3 bridge on a live channel row.
//
// A channel knows its FreeSWITCH uuid, not its SIP Call-ID (`show channels`
// does not carry it), so the click hands the uuid to the page's
// hep3-call-flow host as a `callflow` row-action; the server asks the plugin
// for that one channel's Call-ID and opens the captured call. Same event and
// same overlay as the DataTable and the Logs bridge.
export default class extends Controller {
  open(event) {
    event.preventDefault()

    const fsUuid = event.currentTarget.dataset.fsUuid || ""

    if (!fsUuid) return

    window.dispatchEvent(
      new CustomEvent("datatable:rowaction", {
        detail: { event: "callflow", fsUuid }
      })
    )
  }
}
