import { Controller } from "@hotwired/stimulus"

// ActivityRowsController keeps expanded rows expanded across a frame reload.
//
// THE PROBLEM. The activity table lives in a turbo-frame that reloads when the
// poller lands new actions. Turbo REPLACES the frame's contents, so every
// <details> comes back at its markup default — closed. An operator reading the
// resources of an apply loses the row mid-sentence, roughly every thirty
// seconds, and has to find and reopen it.
//
// THE FIX. Remember which rows are open and reapply on connect. This
// controller sits INSIDE the frame, so Turbo's replacement disconnects the old
// instance and connects a new one against the fresh DOM — connect() is exactly
// the "after render" hook, no extra event plumbing.
//
// State is per-server and lives in sessionStorage, not localStorage: which row
// you had open is a fact about the tab you are reading in, and it should not
// follow you to tomorrow's session or to another window looking at another
// box. Every access is wrapped — a browser with site data blocked throws on
// the accessor itself, and a table that renders is worth more than the memory.
export default class extends Controller {
  static targets = ["row"]
  static values = { key: String }

  connect() {
    this.open = this.read()
    this.restore()

    // `toggle` does NOT bubble, so a delegated listener has to capture. One
    // listener on the container beats one per row: rows are replaced wholesale
    // on every reload, and per-row listeners would have to be rebound each
    // time (and leak if a rebind were ever missed).
    this.onToggle = (event) => this.record(event.target)
    this.element.addEventListener("toggle", this.onToggle, true)
  }

  disconnect() {
    this.element.removeEventListener("toggle", this.onToggle, true)
  }

  restore() {
    this.rowTargets.forEach((row) => {
      const id = row.dataset.rowId
      if (id && this.open.has(id)) row.open = true
    })
  }

  record(row) {
    if (!(row instanceof HTMLDetailsElement)) return

    const id = row.dataset.rowId
    if (!id) return

    if (row.open) {
      this.open.add(id)
    } else {
      this.open.delete(id)
    }

    this.write()
  }

  read() {
    try {
      const raw = sessionStorage.getItem(this.storageKey)

      return new Set(raw ? JSON.parse(raw) : [])
    } catch {
      return new Set()
    }
  }

  write() {
    try {
      sessionStorage.setItem(this.storageKey, JSON.stringify([...this.open]))
    } catch {
      // Private window, blocked site data, quota. The rows still work; they
      // just forget across a reload, which is where they started.
    }
  }

  get storageKey() {
    return `voodu:activity:open:${this.keyValue}`
  }
}
