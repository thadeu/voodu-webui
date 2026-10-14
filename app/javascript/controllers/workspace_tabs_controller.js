import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// `ws`, not `tab`: `?tab=` already names a page section, and the breadcrumb
// turns it into a crumb (Layouts::Breadcrumb#with_active_tab).
const TAB_PARAM = "ws"

// WorkspaceTabsController — browser-like tabs INSIDE one page
// (Components::UI::WorkspaceTabs). Each tab is a full page state.
//
// URL first: the active tab IS its URL (`?ws=<id>&…every filter…`), so a
// reload, a bookmark or the back button restore it with no extra code. The
// only thing stored is the LIST of tabs — {id, label, search} per tab, in
// localStorage per page + server. localStorage, not sessionStorage: the list is
// a workspace, and sessionStorage dies with the browser tab (and does not
// follow a link opened in a new one).
//
// Switching a tab is a plain Turbo visit to the search it last had. The page
// keeps that search current: every state change is a navigation, and every
// navigation re-runs connect() (upsert).
export default class extends Controller {
  static targets = ["strip", "template", "add", "content"]

  static values = {
    storageKey: String,
    tabId: String,
    label: String,
    basePath: String,
    // prefsPrefix — the DataTable key prefix of this page's tables; a closed
    // tab's saved columns / widths / filter are removed with it.
    prefsPrefix: String,
    // fresh — the URL named no tab (the sidebar link): reopen the first open
    // tab instead of adding one on every visit.
    fresh: Boolean,
    max: { type: Number, default: 10 },
  }

  connect() {
    const first = this.freshValue && this.read()[0]

    if (first) {
      Turbo.visit(this.href(first), { action: "replace" })

      return
    }

    this.contentTarget.classList.remove("invisible")
    this.ensureTabInUrl()
    this.upsertCurrent()
    this.render()
  }

  newTab(event) {
    event.preventDefault()

    if (this.read().length >= this.maxValue) return

    Turbo.visit(`${this.basePathValue}?${TAB_PARAM}=${newTabId()}`)
  }

  closeTab(event) {
    event.preventDefault()

    const id = event.currentTarget.dataset.tabId
    const tabs = this.read()
    const index = tabs.findIndex((tab) => tab.id === id)

    if (index === -1) return

    tabs.splice(index, 1)
    this.write(tabs)
    this.clearPrefs(id)

    if (id !== this.tabIdValue) {
      this.render()

      return
    }

    const neighbor = tabs[index] || tabs[index - 1]

    Turbo.visit(neighbor ? this.href(neighbor) : `${this.basePathValue}?${TAB_PARAM}=${newTabId()}`)
  }

  // ── state ─────────────────────────────────────────────────────────

  // ensureTabInUrl — a bare /hep3 visit gets the tab id the server picked, so
  // the URL in the bar always names its tab.
  ensureTabInUrl() {
    const url = new URL(window.location.href)

    if (url.searchParams.get(TAB_PARAM) === this.tabIdValue) return

    url.searchParams.set(TAB_PARAM, this.tabIdValue)
    history.replaceState(history.state, "", url)
  }

  // upsertCurrent — re-read before write so a second browser window on the
  // same page only loses a race, never its whole list.
  upsertCurrent() {
    const tabs = this.read()
    const current = { id: this.tabIdValue, label: this.labelValue, search: window.location.search }
    const index = tabs.findIndex((tab) => tab.id === current.id)

    if (index === -1) {
      tabs.push(current)
    } else {
      tabs[index] = current
    }

    this.write(tabs.slice(-this.maxValue))
  }

  read() {
    try {
      const tabs = JSON.parse(localStorage.getItem(this.storageKeyValue) || "[]")

      return Array.isArray(tabs) ? tabs.filter((tab) => tab && typeof tab.id === "string") : []
    } catch (_e) {
      return []
    }
  }

  write(tabs) {
    try {
      localStorage.setItem(this.storageKeyValue, JSON.stringify(tabs))
    } catch (_e) {
      // Storage disabled / full — the strip still shows the current tab.
    }
  }

  clearPrefs(id) {
    const prefix = `voodu:dt:${this.prefsPrefixValue}${id}:`

    for (const store of [localStorage, sessionStorage]) {
      try {
        Object.keys(store).filter((key) => key.startsWith(prefix)).forEach((key) => store.removeItem(key))
      } catch (_e) {
        // Nothing to clean when storage is unavailable.
      }
    }
  }

  // ── render ────────────────────────────────────────────────────────

  render() {
    const tabs = this.read()
    const closable = tabs.length > 1

    this.stripTarget.replaceChildren(...tabs.map((tab) => this.buildTab(tab, closable)))
    this.stripTarget.querySelector("[aria-current='page']")?.scrollIntoView({ block: "nearest", inline: "nearest" })

    if (this.hasAddTarget) this.addTarget.disabled = tabs.length >= this.maxValue
  }

  buildTab(tab, closable) {
    const node = this.templateTarget.content.firstElementChild.cloneNode(true)
    const link = node.querySelector("[data-tab-link]")
    const close = node.querySelector("[data-tab-close]")

    link.href = this.href(tab)
    link.title = tab.label
    node.querySelector("[data-tab-label]").textContent = tab.label

    if (tab.id === this.tabIdValue) node.setAttribute("aria-current", "page")

    close.dataset.tabId = tab.id
    close.hidden = !closable

    return node
  }

  href(tab) {
    return `${this.basePathValue}${tab.search || `?${TAB_PARAM}=${tab.id}`}`
  }
}

function newTabId() {
  const bytes = crypto.getRandomValues(new Uint8Array(8))

  return Array.from(bytes, (b) => "abcdefghijklmnopqrstuvwxyz0123456789"[b % 36]).join("")
}
