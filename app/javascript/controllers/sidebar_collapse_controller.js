import { Controller } from "@hotwired/stimulus"

// SidebarCollapseController — toggles the sidebar between expanded
// (full width, labels visible) and collapsed (~56px, icons-only)
// states on vmd+ viewports. State persists across page loads via
// localStorage so the operator's preference sticks.
//
// Two affordances trigger the same toggle action:
//   - The chevron button in the sidebar footer (discoverable)
//   - The thin edge-handle rail on the sidebar's right border
//     (NR / Linear style, with a "Collapse" / "Expand" tooltip)
//
// Tailwind's `group-data-[collapsed]:...` variants on descendants
// handle all the visual changes (hide labels, swap to compact
// server-row avatars, recenter icons) — no manual classlist
// fiddling on each child. The footer chevron icon rotates 180°
// via inline `transform` so a single icon serves both states.
//
// Below vmd (mobile slide-in mode), both affordances are hidden —
// mobile-nav controller handles toggle via the hamburger.
//
// Storage key: voodu:sidebar:collapsed (string "true"/"false").
const STORAGE_KEY = "voodu:sidebar:collapsed"

export default class extends Controller {
  static targets = ["icon"]

  connect() {
    // Restore previous state. Default = expanded.
    this.apply(this.read() === "true")
  }

  toggle(event) {
    event?.preventDefault()

    const next = this.element.dataset.collapsed !== "true"

    this.apply(next)
    this.write(next)
  }

  apply(collapsed) {
    if (collapsed) {
      this.element.dataset.collapsed = "true"
    } else {
      delete this.element.dataset.collapsed
    }

    // Footer chevron flip: Left-pointing icon flips to point right
    // when sidebar is collapsed, so the affordance always reads
    // "click here to do the opposite of current state".
    if (this.hasIconTarget) {
      this.iconTarget.style.transform = collapsed ? "rotate(180deg)" : ""
    }
  }

  read() {
    try {
      return localStorage.getItem(STORAGE_KEY)
    } catch (_) {
      return null
    }
  }

  write(collapsed) {
    try {
      localStorage.setItem(STORAGE_KEY, collapsed ? "true" : "false")
    } catch (_) { /* private mode — in-memory state still applies */ }
  }
}
