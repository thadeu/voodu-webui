import { Controller } from "@hotwired/stimulus"

import { readJSON } from "../lib/storage.js"

// data-table — renders a DataSource page (schema-less) as a table:
// column picker, per-field substring filter, click-to-sort, infinite
// scroll (older pages), manual refresh, and OPT-IN live streaming.
//
// Live is OFF by default so the table never reorders under you while
// reading. Refresh pulls the latest page on demand; Live (when toggled
// on) appends new rows at the top, preserving scroll position when you're
// reading below the fold.
//
// this.rows is the canonical NEWEST-FIRST list (server id-desc order);
// sorting only reorders a render-time copy, so the id cursors stay valid:
//   newest = rows[0].id (poll since_id) · oldest = rows[last].id (before_id)
export default class extends Controller {
  static targets = ["viewport", "status", "colToggle", "query", "live", "liveDot", "rowActionIcon", "count"]

  static values = {
    url: String,
    source: String,
    scope: String,
    name: String,
    view: String,
    key: String,
    // dashboard — the dashboard uuid; with `key` (the panel_key) it lets the
    // rows endpoint re-resolve an http panel's stored request config server-
    // side (the URL + auth headers never ride the query string).
    dashboard: String,
    // server — the server this reader lives on (M2). Forwarded so the rows
    // endpoint queries the right server's warehouse server (a cross-server
    // dashboard's table reads another org server's data). Resolved on the
    // server WITHIN the org, so a forged id can't reach outside it.
    server: String,
    // range/from/until — the page's time window, forwarded on every fetch so
    // the table scopes to the same span as the charts.
    range: String,
    from: String,
    until: String,
    // rowAction — an optional per-row drill-down declared by the source. When
    // set, a leading icon cell dispatches `datatable:rowaction` carrying the
    // row's `key` value for a page host to act on (hep3 → call-flow).
    rowActionKey: String,
    rowActionEvent: String,
    rowActionTitle: String,
  }

  POLL_MS = 5000
  MAX_ROWS = 2000
  ACTION_COL_W = 34

  connect() {
    this.rows = []
    this.seen = new Set()
    this.sort = null
    this.loading = false
    this.reloadsPaused = false
    this.colWidths = this.readJson(this.prefKey("colw")) || {}

    this.restorePrefs()
    this.reflectLive()
    this.bindFilterFocus()

    // The toolbar filter is a live override of the panel's saved (config)
    // filter. serverQuery is what the server rendered (the config filter);
    // restoreQuery brings back what the operator last typed so a metrics-tick
    // frame reload doesn't revert it. Runs BEFORE restoreState so the rows
    // cache signature matches the restored query.
    this.serverQuery = this.hasQueryTarget ? this.queryTarget.value : ""
    this.restoreQuery()

    // Repaint from the last snapshot across a frame reload (broadcast tick)
    // so the table doesn't flash "Loading…" or lose scroll — the card
    // re-renders normally (respecting the grid reorder); we just restore its
    // state. First load (no cache) fetches.
    const cached = this.restoreState()

    if (cached) {
      this.hydrate(cached)
    } else {
      this.load()
    }

    if (this.live) this.startPolling()

    // turbo:before-cache — swap the rendered table for a tiny placeholder BEFORE
    // Turbo snapshots the page, so its snapshot cache doesn't retain up to
    // MAX_ROWS of wide rows in memory (× every table card × every cached page).
    // connect() rehydrates from sessionStorage (restoreState → render) on the way
    // back — for both normal and restoration visits — so nothing is lost.
    this.onBeforeCache = () => { if (this.hasViewportTarget) this.showStatus("Loading…") }
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
  }

  disconnect() {
    this.saveState()
    this.stopPolling()
    this.resumeReloads()
    this.unbindFilterFocus()

    if (this.onBeforeCache) document.removeEventListener("turbo:before-cache", this.onBeforeCache)
  }

  // ── filter-focus reload guard ─────────────────────────────────────
  // While the operator is typing in the filter, suppress the metrics-tick
  // frame reload (it swaps the whole frame and would wipe the input
  // mid-keystroke). Uses the shared polling:pause/resume convention.

  bindFilterFocus() {
    if (!this.hasQueryTarget) return

    this.onQueryFocus = () => this.pauseReloads()
    this.onQueryBlur = () => this.resumeReloads()
    this.queryTarget.addEventListener("focus", this.onQueryFocus)
    this.queryTarget.addEventListener("blur", this.onQueryBlur)
  }

  unbindFilterFocus() {
    if (!this.hasQueryTarget || !this.onQueryFocus) return

    this.queryTarget.removeEventListener("focus", this.onQueryFocus)
    this.queryTarget.removeEventListener("blur", this.onQueryBlur)
  }

  pauseReloads() {
    if (this.reloadsPaused) return

    this.reloadsPaused = true
    window.dispatchEvent(new CustomEvent("polling:pause"))
  }

  resumeReloads() {
    if (!this.reloadsPaused) return

    this.reloadsPaused = false
    window.dispatchEvent(new CustomEvent("polling:resume"))
  }

  hydrate({ rows, scrollTop }) {
    this.rows = rows
    rows.forEach((r) => this.seen.add(r.id))
    this.render()

    if (this.hasViewportTarget) this.viewportTarget.scrollTop = scrollTop || 0
  }

  // ── data loading ──────────────────────────────────────────────────

  async load() {
    this.showStatus("Loading…")
    this.rows = []
    this.seen.clear()

    const data = await this.fetchPage()

    if (!data) return

    this.ingest(data.rows || [], "append")
    this.render()
  }

  // refresh — manual catch-up: reload the latest page from the top.
  refresh() {
    this.load()
  }

  async loadOlder() {
    if (this.loading || !this.rows.length) return

    this.loading = true

    const oldest = this.rows[this.rows.length - 1].id
    const data = await this.fetchPage({ before_id: oldest })

    this.loading = false

    if (!data || !(data.rows || []).length) return

    this.ingest(data.rows, "append")
    this.render()
  }

  async poll() {
    if (!this.live || !this.rows.length) return

    const newest = this.rows[0].id
    const data = await this.fetchPage({ since_id: newest })

    if (!data) return

    const fresh = (data.rows || []).filter((r) => !this.seen.has(r.id))

    if (!fresh.length) return

    this.prependPreservingScroll(fresh)
  }

  // prependPreservingScroll — add new rows at the top without yanking the
  // viewport: if the operator is reading below the fold, nudge scrollTop by
  // the height the new rows added so their row stays put.
  prependPreservingScroll(fresh) {
    const vp = this.viewportTarget
    const atTop = vp.scrollTop <= 4
    const before = vp.scrollHeight

    this.ingest(fresh, "prepend")
    this.render()

    if (!atTop) vp.scrollTop += vp.scrollHeight - before
  }

  async fetchPage(extra = {}) {
    const params = new URLSearchParams({ scope: this.scopeValue, name: this.nameValue, view: this.viewValue })
    const query = this.currentQuery()

    if (query) params.set("filter_query", query)

    // Scope to the page's time window (charts + table stay in lockstep).
    if (this.rangeValue) params.set("range", this.rangeValue)
    if (this.fromValue) params.set("from", this.fromValue)
    if (this.untilValue) params.set("until", this.untilValue)

    // server — the server this reader lives on (M2). The endpoint resolves it
    // within the org, so a cross-server table reads the right warehouse server.
    if (this.serverValue) params.set("server_id", this.serverValue)

    // An http source resolves its config from the panel; hand the endpoint the
    // reference so it can look it up (harmless no-op for hep3/logs).
    if (this.dashboardValue) {
      params.set("dashboard", this.dashboardValue)
      params.set("panel_key", this.keyValue)
    }

    Object.entries(extra).forEach(([k, v]) => params.set(k, v))

    try {
      const resp = await fetch(`${this.urlValue}?${params}`, { headers: { Accept: "application/json" } })
      const data = await resp.json().catch(() => null)

      if (!resp.ok) {
        // 422 carries a filter parse message (prefix it so the operator fixes
        // the query); a 502 carries an external-API error (timeout / HTTP 5xx /
        // bad JSON) — show that verbatim. Otherwise a generic fallback.
        const msg = data?.error
          ? (resp.status === 422 ? `Filter: ${data.error}` : data.error)
          : `Couldn't load rows (${resp.status})`

        this.showStatus(msg)

        return null
      }

      return data
    } catch (_e) {
      this.showStatus("Couldn't load rows")

      return null
    }
  }

  // ingest — merge a page into this.rows keeping it newest-first + deduped,
  // bounded to MAX_ROWS.
  ingest(rows, where) {
    const fresh = rows.filter((r) => {
      if (this.seen.has(r.id)) return false

      this.seen.add(r.id)

      return true
    })

    if (!fresh.length) return

    this.rows = where === "prepend" ? fresh.concat(this.rows) : this.rows.concat(fresh)

    if (this.rows.length > this.MAX_ROWS) {
      this.rows.slice(this.MAX_ROWS).forEach((r) => this.seen.delete(r.id))
      this.rows = this.rows.slice(0, this.MAX_ROWS)
    }
  }

  // ── toolbar actions ───────────────────────────────────────────────

  applyColumns() {
    this.persistColumns()
    this.render()
  }

  toggleAllColumns() {
    const allOn = this.colToggleTargets.every((c) => c.checked)

    this.colToggleTargets.forEach((c) => { c.checked = !allOn })
    this.applyColumns()
  }

  applyFilter() {
    this.persistQuery()

    if (this.filterTimer) clearTimeout(this.filterTimer)

    this.filterTimer = setTimeout(() => this.load(), 250)
  }

  // persistQuery / restoreQuery — keep the runtime toolbar filter alive across
  // a metrics-tick frame reload. Stored per panel with the config value it
  // overrides (cfg): if a form edit later changes the config filter, the
  // server renders a different value and the stale runtime edit is dropped.
  persistQuery() {
    try {
      sessionStorage.setItem(this.prefKey("q"), JSON.stringify({ cfg: this.serverQuery, q: this.currentQuery(), ts: Date.now() }))
    } catch (_e) {
      // sessionStorage full / disabled — the filter just won't persist.
    }
  }

  restoreQuery() {
    if (!this.hasQueryTarget) return

    const saved = this.readSession(this.prefKey("q"))

    if (!saved || Date.now() - (saved.ts || 0) > 300000) return
    if (saved.cfg !== this.serverQuery || typeof saved.q !== "string") return

    this.queryTarget.value = saved.q
  }

  toggleLive() {
    this.live = !this.live
    this.persistLive()
    this.reflectLive()

    if (this.live) {
      this.startPolling()
      this.poll()
    } else {
      this.stopPolling()
    }
  }

  startPolling() {
    if (!this.poller) this.poller = setInterval(() => this.poll(), this.POLL_MS)
  }

  stopPolling() {
    if (this.poller) clearInterval(this.poller)

    this.poller = null
  }

  onScroll() {
    const vp = this.viewportTarget

    this.lastScrollTop = vp.scrollTop

    const nearBottom = vp.scrollTop + vp.clientHeight >= vp.scrollHeight - 80

    if (nearBottom) this.loadOlder()
  }

  sortBy(col) {
    if (this.sort && this.sort.col === col) {
      this.sort.dir = this.sort.dir === "asc" ? "desc" : "asc"
    } else {
      this.sort = { col, dir: "asc" }
    }

    this.render()
  }

  // startColResize — drag the header's right edge to set the column's width.
  // Updates the <col> live (smooth), persists on release. Widths are keyed by
  // column name per panel, so they survive reloads + the newest-first repaint.
  startColResize(event, col, index) {
    event.preventDefault()
    event.stopPropagation()

    const table = this.viewportTarget.querySelector("table")

    if (!table) return

    table.style.tableLayout = "fixed"

    const colEl = table.querySelectorAll("colgroup col")[index]
    const startX = event.clientX
    const startW = this.colWidths[col] || (colEl ? colEl.offsetWidth : 120)

    const onMove = (e) => {
      const w = Math.max(50, startW + (e.clientX - startX))

      this.colWidths[col] = w
      if (colEl) colEl.style.width = `${w}px`
      table.style.width = `${this.tableWidth()}px`
    }

    const onUp = () => {
      document.removeEventListener("pointermove", onMove)
      document.removeEventListener("pointerup", onUp)
      this.persistColWidths()
    }

    document.addEventListener("pointermove", onMove)
    document.addEventListener("pointerup", onUp)
  }

  persistColWidths() {
    try {
      localStorage.setItem(this.prefKey("colw"), JSON.stringify(this.colWidths))
    } catch (_e) {
      // storage full / disabled — widths just won't persist across reloads.
    }
  }

  // autoFitColumn — double-click the resize handle to size a column to its
  // content (spreadsheet "auto-fit"): the widest of the header label + every
  // loaded cell, plus padding. Applied + persisted the same way a drag is.
  autoFitColumn(col, index) {
    const table = this.viewportTarget.querySelector("table")

    if (!table) return

    table.style.tableLayout = "fixed"

    const colEl = table.querySelectorAll("colgroup col")[index]
    const w = this.measureColumnWidth(table, index)

    this.colWidths[col] = w
    if (colEl) colEl.style.width = `${w}px`
    table.style.width = `${this.tableWidth()}px`
    this.persistColWidths()
  }

  // measureColumnWidth — the natural px width for the column at `index`: the
  // widest rendered text across the header label + every body cell, measured
  // with each element's OWN font (the header is uppercase/tracked, the body a
  // plain cell), plus padding. Double-click fits the FULL content — the table
  // grows past the viewport and scrolls in X (that's fine, the operator asked to
  // see the whole cell). The only ceiling is a pathological guard so a single
  // enormous value (a base64 blob, a raw payload) can't create a megapixel
  // column that janks the browser. Only the loaded rows are measured → instant.
  measureColumnWidth(table, index) {
    const th = table.querySelectorAll("thead th")[index]
    const label = th && th.querySelector("span")
    const cells = table.querySelectorAll(`tbody tr td:nth-child(${index + 1})`)
    const pad = 22

    let max = 0

    if (label && label.textContent) max = this.textWidth(label.textContent, label)
    cells.forEach((td) => {
      if (td.textContent) max = Math.max(max, this.textWidth(td.textContent, td))
    })

    return Math.min(this.MAX_FIT_WIDTH, Math.max(60, Math.ceil(max + pad)))
  }

  // MAX_FIT_WIDTH — the auto-fit ceiling. High enough to hold any realistic
  // single-field value (a SIP payload, a long log line, a URL) so the fit shows
  // it whole; a bound only so a runaway cell can't blow the layout out.
  get MAX_FIT_WIDTH() { return 8000 }

  // textWidth — width of `text` in `el`'s computed font via a shared canvas 2D
  // context. Exact per-element font, no DOM reflow.
  textWidth(text, el) {
    this.measureCtx ||= document.createElement("canvas").getContext("2d")
    const cs = getComputedStyle(el)

    this.measureCtx.font = `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`

    return this.measureCtx.measureText(text).width
  }

  // ── render ────────────────────────────────────────────────────────

  // updateCount — reflect how many rows are currently loaded/rendered in the
  // footer. Paging (loadOlder) grows it, live-prepend adds to it, a filter
  // re-fetch replaces it — so this runs from render(), the single paint path.
  // At the MAX_ROWS cap older rows are dropped, so show "N+" (there may be more).
  updateCount() {
    if (!this.hasCountTarget) return

    const n = this.rows.length
    const capped = n >= this.MAX_ROWS

    this.countTarget.textContent = `${n}${capped ? "+" : ""} ${n === 1 ? "row" : "rows"}`
  }

  render() {
    this.updateCount()

    const columns = this.visibleColumns()

    if (!this.rows.length) {
      this.showStatus("No data yet")

      return
    }

    if (!columns.length) {
      this.showStatus("No columns selected")

      return
    }

    const table = document.createElement("table")
    const haveWidths = columns.every((c) => this.colWidths[c])

    table.className = "text-[12px] font-voodu-mono border-collapse"

    // Fixed layout once widths are known so a column keeps the width the
    // operator dragged it to (the table grows/scrolls-x, siblings stay put).
    // The FIRST render for a column set stays auto so captureColWidths can
    // measure natural widths as the starting point.
    if (haveWidths) {
      table.style.tableLayout = "fixed"
      // A definite table width is what makes fixed layout actually honour the
      // per-column widths (otherwise columns snap back to content width). The
      // table then scrolls-x inside the viewport when wider than it.
      table.style.width = `${this.tableWidth(columns)}px`
    }

    const colgroup = document.createElement("colgroup")

    if (this.hasRowAction()) {
      const ac = document.createElement("col")

      ac.style.width = `${this.ACTION_COL_W}px`
      colgroup.appendChild(ac)
    }

    columns.forEach((col) => {
      const c = document.createElement("col")

      if (this.colWidths[col]) c.style.width = `${this.colWidths[col]}px`

      colgroup.appendChild(c)
    })

    table.appendChild(colgroup)
    table.appendChild(this.buildHead(columns))
    table.appendChild(this.buildBody(this.sortedRows(), columns))

    this.viewportTarget.replaceChildren(table)

    if (!haveWidths) this.captureColWidths(table, columns)
  }

  // captureColWidths — after the first (auto-layout) render, freeze each
  // column's natural width (clamped) and switch to fixed layout so the
  // columns are resizable from a sensible baseline.
  captureColWidths(table, columns) {
    // The action column (when present) is the leading th/col, so the data
    // columns start one slot in — offset every measurement by it.
    const off = this.hasRowAction() ? 1 : 0
    const ths = table.querySelectorAll("thead th")
    const cols = table.querySelectorAll("colgroup col")

    columns.forEach((col, i) => {
      if (!this.colWidths[col] && ths[i + off]) {
        this.colWidths[col] = Math.min(420, Math.max(60, Math.round(ths[i + off].offsetWidth)))
      }
    })

    table.style.tableLayout = "fixed"
    columns.forEach((col, i) => { if (cols[i + off]) cols[i + off].style.width = `${this.colWidths[col]}px` })
    table.style.width = `${this.tableWidth(columns)}px`
  }

  // tableWidth — the sum of the visible columns' widths (px), plus the fixed
  // action column when present. Feeds the table's explicit width so fixed
  // layout honours each <col>.
  tableWidth(columns) {
    const base = (columns || this.visibleColumns()).reduce((sum, c) => sum + (this.colWidths[c] || 120), 0)

    return base + (this.hasRowAction() ? this.ACTION_COL_W : 0)
  }

  sortedRows() {
    if (!this.sort) return this.rows

    const { col, dir } = this.sort
    const sign = dir === "asc" ? 1 : -1

    return [...this.rows].sort((a, b) => {
      const av = a[col]
      const bv = b[col]
      const na = Number(av)
      const nb = Number(bv)
      const numeric = av !== "" && bv !== "" && !Number.isNaN(na) && !Number.isNaN(nb)

      if (numeric) return (na - nb) * sign

      return String(av ?? "").localeCompare(String(bv ?? "")) * sign
    })
  }

  buildHead(columns) {
    const thead = document.createElement("thead")
    const tr = document.createElement("tr")
    const off = this.hasRowAction() ? 1 : 0

    if (off) {
      const th = document.createElement("th")

      th.className = "sticky top-0 z-10 bg-voodu-surface-2 border-b border-voodu-border"
      tr.appendChild(th)
    }

    columns.forEach((col, i) => {
      const th = document.createElement("th")

      th.className =
        "sticky top-0 z-10 bg-voodu-surface-2 text-left text-voodu-muted-2 font-medium cursor-pointer select-none relative overflow-hidden " +
        "px-2 py-1.5 border-b border-voodu-border uppercase text-[10px] tracking-[0.05em] hover:text-voodu-text"

      const label = document.createElement("span")

      label.className = "block truncate pr-1.5"
      label.textContent = col + this.sortIndicator(col)
      th.appendChild(label)
      th.addEventListener("click", () => this.sortBy(col))

      // Drag the right edge to resize the column.
      const handle = document.createElement("div")

      handle.className = "absolute top-0 right-0 h-full w-[7px] cursor-col-resize hover:bg-voodu-accent-line/60"
      handle.title = "Drag to resize · double-click to fit"
      handle.addEventListener("pointerdown", (e) => this.startColResize(e, col, i + off))
      handle.addEventListener("dblclick", (e) => { e.preventDefault(); e.stopPropagation(); this.autoFitColumn(col, i + off) })
      handle.addEventListener("click", (e) => e.stopPropagation())
      th.appendChild(handle)

      tr.appendChild(th)
    })

    thead.appendChild(tr)

    return thead
  }

  sortIndicator(col) {
    if (!this.sort || this.sort.col !== col) return ""

    return this.sort.dir === "asc" ? " ↑" : " ↓"
  }

  buildBody(rows, columns) {
    const tbody = document.createElement("tbody")

    rows.forEach((row) => {
      const tr = document.createElement("tr")

      tr.className = "border-b border-voodu-border/40 hover:bg-voodu-hover"

      if (this.hasRowAction()) tr.appendChild(this.actionCell(row))

      columns.forEach((col) => {
        const td = document.createElement("td")
        const value = row[col]

        td.textContent = value === null || value === undefined ? "" : String(value)
        td.title = td.textContent
        // Width comes from the colgroup (fixed layout); truncate within it.
        td.className = "px-2 py-1 text-voodu-text truncate"
        tr.appendChild(td)
      })

      tbody.appendChild(tr)
    })

    return tbody
  }

  // ── row action (per-row drill-down) ───────────────────────────────

  hasRowAction() {
    return Boolean(this.rowActionKeyValue && this.rowActionEventValue)
  }

  // actionCell — the leading icon cell. The button clones the icon from the
  // server-rendered <template> and carries the row's key value (e.g.
  // corr_id); clicking dispatches `datatable:rowaction`. A row missing the
  // key gets an empty cell (keeps the column aligned).
  actionCell(row) {
    const td = document.createElement("td")

    td.className = "px-1 py-0.5 text-center align-middle"

    const value = row[this.rowActionKeyValue]

    if (!value) return td

    const btn = document.createElement("button")

    btn.type = "button"
    btn.className =
      "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 rounded-voodu-sm"
    btn.title = this.rowActionTitleValue || ""
    btn.setAttribute("aria-label", this.rowActionTitleValue || "Open")
    btn.dataset.value = value
    // The row's own id (message id for message views) lets the drill-down
    // pre-select THIS row's message, not just the call's first.
    if (row.id != null) btn.dataset.rowId = row.id

    if (this.hasRowActionIconTarget) btn.innerHTML = this.rowActionIconTarget.innerHTML

    btn.addEventListener("click", (e) => this.onRowAction(e))
    td.appendChild(btn)

    return td
  }

  onRowAction(event) {
    event.preventDefault()
    event.stopPropagation()

    const value = event.currentTarget.dataset.value

    if (!value) return

    // window-level so a page host anywhere in the DOM (outside the polling
    // frame) catches it — mirrors the Logs "surrounding" fetch→inject.
    window.dispatchEvent(new CustomEvent("datatable:rowaction", {
      detail: {
        event: this.rowActionEventValue,
        key: this.rowActionKeyValue,
        value,
        rowId: event.currentTarget.dataset.rowId,
        source: this.sourceValue,
        scope: this.scopeValue,
        name: this.nameValue,
        view: this.viewValue,
        server: this.serverValue,
      },
    }))
  }

  showStatus(message) {
    const div = document.createElement("div")

    div.className = "px-3 py-6 text-center text-[12px] text-voodu-muted"
    div.textContent = message

    this.viewportTarget.replaceChildren(div)
  }

  // ── helpers ───────────────────────────────────────────────────────

  visibleColumns() {
    return this.colToggleTargets.filter((c) => c.checked).map((c) => c.value)
  }

  currentQuery() {
    return this.hasQueryTarget ? this.queryTarget.value.trim() : ""
  }

  reflectLive() {
    if (this.hasLiveDotTarget) {
      this.liveDotTarget.style.background = this.live ? "var(--voodu-green)" : "var(--voodu-muted-2)"
    }

    if (this.hasLiveTarget) {
      this.liveTarget.style.borderColor = this.live ? "var(--voodu-accent-line)" : ""
      this.liveTarget.style.background = this.live ? "var(--voodu-accent-dim)" : ""
    }
  }

  // ── persistence (per-panel prefs) ─────────────────────────────────

  // restorePrefs — reapply saved column visibility, keyed by field NAME. Because
  // field names are user-editable (rename in the panel mapping), we store the
  // full SCHEMA alongside the visible set: `{ v: [visible], s: [all-at-save] }`.
  // On restore, a column that WAS in the saved schema keeps its saved shown/hidden
  // state; a column that WASN'T (renamed or newly added) defaults to VISIBLE — so
  // renaming a field never silently unchecks it. Legacy array prefs are ignored
  // (→ server defaults, all shown), and get rewritten in the new shape on the
  // next toggle.
  restorePrefs() {
    this.live = localStorage.getItem(this.prefKey("live")) === "1"

    const saved = this.readJson(this.prefKey("cols"))

    if (!saved || !Array.isArray(saved.v) || !Array.isArray(saved.s)) return

    this.colToggleTargets.forEach((c) => {
      c.checked = saved.s.includes(c.value) ? saved.v.includes(c.value) : true
    })
  }

  persistColumns() {
    const schema = this.colToggleTargets.map((c) => c.value)

    localStorage.setItem(this.prefKey("cols"), JSON.stringify({ v: this.visibleColumns(), s: schema }))
  }

  persistLive() {
    localStorage.setItem(this.prefKey("live"), this.live ? "1" : "0")
  }

  // saveState — snapshot rows + scroll (bounded) so a reconnect after a
  // frame reload repaints instantly instead of re-fetching. sessionStorage
  // (not local) so it's per-tab and doesn't outlive the session.
  saveState() {
    if (!this.rows.length) return

    // Prefer the scroll position captured DURING scrolling — at disconnect
    // the viewport is already detached, so reading scrollTop there yields 0.
    const scrollTop = this.lastScrollTop ?? (this.hasViewportTarget ? this.viewportTarget.scrollTop : 0)

    const state = {
      rows: this.rows.slice(0, 200),
      scrollTop,
      sig: this.signature(),
      ts: Date.now(),
    }

    try {
      sessionStorage.setItem(this.prefKey("state"), JSON.stringify(state))
    } catch (_e) {
      // sessionStorage full / disabled → fall back to a fresh load.
    }
  }

  // restoreState — the cached snapshot if recent (< 5 min) AND still for the
  // same view/filter (else an edit would show stale rows), else null.
  restoreState() {
    const raw = this.readSession(this.prefKey("state"))

    if (!raw || !Array.isArray(raw.rows) || !raw.rows.length) return null

    if (Date.now() - (raw.ts || 0) > 300000) return null

    if (raw.sig !== this.signature()) return null

    return raw
  }

  // signature — the source/view/filter/SCHEMA the cache is valid for. A config
  // edit (new filter, view, or renamed/re-mapped columns) changes it, forcing a
  // fresh load. The column schema matters because rows are keyed by field name:
  // renaming a field (e.g. `id` → `ID1`) would otherwise restore cached rows
  // under the OLD keys, so every cell reads `row[newName]` === undefined and the
  // table fills with blank rows. Sorted so a mere column REORDER (same keys)
  // keeps the cache valid.
  signature() {
    const schema = this.colToggleTargets.map((c) => c.value).sort().join(",")

    return [this.viewValue, this.currentQuery(), this.rangeValue, this.fromValue, this.untilValue, schema].join("|")
  }

  readSession(key) {
    return readJSON(sessionStorage, key)
  }

  // prefKey — per-panel localStorage namespace for column visibility / widths /
  // live. Scoped by DASHBOARD too (not just the panel_key): panel_key is
  // index-based ("k0"), so without the dashboard uuid every dashboard's first
  // panel shared one key — a stale column set from another dashboard's k0 would
  // hide a new panel's columns (an empty table until you re-check them). Scope
  // pages have no dashboard, so they fall back to the panel_key alone.
  prefKey(suffix) {
    const ns = this.dashboardValue ? `${this.dashboardValue}:` : ""

    return `voodu:dt:${ns}${this.keyValue}:${suffix}`
  }

  readJson(key) {
    return readJSON(localStorage, key)
  }
}
