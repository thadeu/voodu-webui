import { Controller } from "@hotwired/stimulus"

// CommandPaletteController — ⌘K palette behaviour.
//
// Lifecycle (stale-while-revalidate):
//   - connect: opportunistic prefetch — warm `this.commands` from
//     sessionStorage IMMEDIATELY (even if stale), and kick off a
//     background refresh when the cache is missing or past TTL.
//     So by the time the operator first hits ⌘K, commands are
//     ready and the palette never paints a Loading state — except
//     on the very first page load after a fresh tab session, when
//     there's no cache at all yet.
//   - open: paint whatever's cached (stale OK); start a refresh
//     if the cache isn't fresh. The refresh swaps `this.commands`
//     in place and re-runs the active filter so the operator sees
//     fresh data without a flicker.
//   - subsequent opens within 30s: pure sessionStorage read, zero
//     network, zero loading state.
//
// Commands come from CommandPaletteController#commands — one global
// JSON feed covering EVERY island, not the page's current island. The
// operator can ⌘K from /pods on island A and restart a pod on island B
// without switching first.
//
// Caching layers:
//   - sessionStorage[CACHE_KEY] (30s TTL) — within-tab fast path.
//     Stale entries are STILL surfaced to the UI (SWR); the TTL only
//     decides whether to revalidate.
//   - Browser HTTP cache (Cache-Control: private, max-age=30) — across
//     tabs / fresh sessionStorage.
//   - IslandPods 30s Rails.cache — controller-side, shared with
//     /pods + /logs + /metrics pickers.
//
// LRU suggestions live in localStorage[LRU_KEY] (cap 8). Surviving a
// tab close is the point — the operator's "things I do here" doesn't
// reset every session.
//
// Icons: cmd.icon is a logical name (e.g. "CubeOutline") that we map
// to inline SVG client-side via ICON_MAP. Heroicons-v2 outline paths,
// hand-embedded so no runtime icon-pack import. Status takes precedence
// over icon — a pod row with cmd.status="running" gets the green dot,
// not the cube glyph.

const CACHE_KEY      = "voodu:cmd-palette:v1"
const CACHE_TTL_MS   = 30_000
const LRU_KEY        = "voodu:cmd-palette:recent"
const LRU_CAP        = 8
const TENANT_KEY_RE  = /^\/([A-Za-z0-9]{6})(?:\/|$)/

const GROUP_BOOST = {
  Navigate: 5,
  Actions:  4,
  Pods:     6,
  Logs:     3,
  Metrics:  3,
  Servers:  2
}

export default class extends Controller {
  static targets = ["backdrop", "dialog", "input", "clear", "results", "count"]

  static values = {
    endpoint: String,
    csrf:     String
  }

  connect() {
    this.onGlobalKey = this.onGlobalKey.bind(this)
    this.onLocalKey  = this.onLocalKey.bind(this)
    this.selected    = 0
    this.flat        = []
    this.commands    = []
    this.loaded      = false
    this.fetching    = null

    document.addEventListener("keydown", this.onGlobalKey)

    // Warm from cache + opportunistic background prefetch. The point
    // is to make the first ⌘K of this page-load INSTANT, with no
    // Loading state, even when the sessionStorage entry is stale.
    // We paint whatever's there now, then refresh in the background
    // if it's past TTL (or absent entirely).
    this.warmFromCache()

    if (!isFresh(readCache())) this.refresh()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onGlobalKey)
    if (this.isOpen) this.unlockScroll()
  }

  // ── lifecycle ───────────────────────────────────────────────────

  async open(event) {
    event?.preventDefault()
    if (this.isOpen) return
    this.isOpen = true

    this.backdropTarget.hidden = false
    this.dialogTarget.hidden   = false
    this.inputTarget.value     = ""
    this.selected              = 0
    this.lockScroll()

    document.addEventListener("keydown", this.onLocalKey)

    requestAnimationFrame(() => this.inputTarget.focus({ preventScroll: true }))

    // Stale-while-revalidate. If `connect()` already warmed
    // `this.commands` from cache, paint immediately — no Loading.
    // Kick a background refresh only when the cache is past TTL or
    // missing; the refresh re-runs the active filter on resolve so
    // fresh data swaps in invisibly.
    if (!isFresh(readCache())) this.refresh()

    if (!this.loaded) {
      // First-ever ⌘K on a tab with no warmed cache. Show a Loading
      // hint and wait on the in-flight prefetch (started by
      // connect() or by the refresh above).
      this.renderLoading()
      await this.fetching
      if (!this.isOpen) return
    }
    this.renderDefault()
  }

  close(event) {
    event?.preventDefault()
    if (!this.isOpen) return
    this.isOpen = false

    this.backdropTarget.hidden = true
    this.dialogTarget.hidden   = true
    this.unlockScroll()

    document.removeEventListener("keydown", this.onLocalKey)
  }

  clear(event) {
    event?.preventDefault()
    this.inputTarget.value = ""
    this.filter()
    this.inputTarget.focus()
  }

  // ── fetching ────────────────────────────────────────────────────

  // warmFromCache — hydrate `this.commands` from sessionStorage WITHOUT
  // checking freshness. The whole point of SWR: stale data is better
  // than no data. The freshness check is the caller's job, used to
  // decide whether to ALSO kick a refresh.
  warmFromCache() {
    const env = readCache()
    if (!env) return

    this.commands = env.commands
    this.loaded   = true
  }

  // refresh — fire a background fetch, swap `this.commands` on
  // success, and re-paint the open palette so fresh data appears
  // without a Loading flicker. Concurrent refreshes dedupe via
  // `this.fetching`. On error: keep whatever stale data we already
  // had — no UI regression for the operator.
  async refresh() {
    if (this.fetching) return this.fetching

    this.fetching = (async () => {
      try {
        const url = appendCurrent(this.endpointValue)

        const res = await fetch(url, {
          headers: { "Accept": "application/json" },
          credentials: "same-origin"
        })
        
        if (!res.ok) throw new Error("HTTP " + res.status)
        
          const json = await res.json()
        const next = Array.isArray(json.commands) ? json.commands : []

        this.commands = next
        this.loaded   = true
        
        writeCache(next)

        // SWR repaint. `filter()` reads `this.commands` + the current
        // input value, so calling it covers both the default view
        // (empty query → renderDefault) and an active search
        // (operator already typed something while we were fetching).
        if (this.isOpen) this.filter()
      } catch (e) {
        console.error("command palette: refresh failed", e)
        // Stale `this.commands` stays — operator keeps working. If
        // we had no commands at all, `loaded` remains false and the
        // Loading state holds until the next refresh attempt.
      } finally {
        this.fetching = null
      }
    })()

    return this.fetching
  }

  // ── keyboard ────────────────────────────────────────────────────

  onGlobalKey(event) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault()
      this.isOpen ? this.close() : this.open()
    }
  }

  onLocalKey(event) {
    if (!this.isOpen) return

    switch (event.key) {
      case "Escape":
        event.preventDefault(); this.close(); break
      case "ArrowDown":
        event.preventDefault(); this.move(1); break
      case "ArrowUp":
        event.preventDefault(); this.move(-1); break
      case "PageDown":
      case "End":
        event.preventDefault(); this.jumpTo(this.flat.length - 1); break
      case "PageUp":
      case "Home":
        event.preventDefault(); this.jumpTo(0); break
      case "Enter":
        event.preventDefault(); this.runSelected(); break
    }
  }

  move(delta) {
    const max = this.flat.length - 1
    if (max < 0) return
    this.selected = Math.max(0, Math.min(max, this.selected + delta))
    this.refreshSelection()
    this.scrollSelectedIntoView()
  }

  jumpTo(i) {
    this.selected = i
    this.refreshSelection()
    this.scrollSelectedIntoView()
  }

  // ── filter + render ─────────────────────────────────────────────

  filter() {
    if (!this.loaded) return

    const q = this.inputTarget.value.trim()
    this.clearTarget.hidden = !q

    if (!q) {
      this.renderDefault()
      return
    }

    const scored = []
    for (const cmd of this.commands) {
      const s = scoreCommand(cmd, q)
      if (s !== null && s > 0) scored.push({ cmd, score: s })
    }
    scored.sort((a, b) => b.score - a.score)
    const top = scored.slice(0, 80).map(r => r.cmd)

    this.renderSections(groupCommands(top), q)
  }

  renderLoading() {
    this.resultsTarget.innerHTML = `
      <div class="px-4 py-10 text-center text-voodu-muted">
        <div class="text-[13px]">Loading commands…</div>
      </div>`
    if (this.hasCountTarget) this.countTarget.textContent = "—"
  }

  // renderDefault — what the operator sees on first ⌘K with no
  // typed query. Two sections:
  //
  //   1. Suggestions — recent LRU resolved against the current
  //      command list. Drops dead ids (pod renamed, island deleted)
  //      silently rather than rendering a broken row.
  //   2. Navigate — the 6 nav items for the CURRENT island, picked
  //      from the URL prefix. If we're on a tenant-less page (eg
  //      /islands), there's no current island so we skip Navigate
  //      and just show Suggestions.
  renderDefault() {
    if (!this.loaded) {
      this.renderLoading()
      return
    }

    const currentKey = detectCurrentTenantKey()
    const recentIds  = readLRU()
    const byId       = new Map(this.commands.map(c => [c.id, c]))

    const suggestions = recentIds
      .map(id => byId.get(id))
      .filter(Boolean)
      .slice(0, LRU_CAP)

    const navigate = currentKey
      ? this.commands.filter(c => c.group === "Navigate" && c.island_key === currentKey)
      : []

    const sections = []
    if (suggestions.length) sections.push({ label: "Recent",   items: suggestions })
    if (navigate.length)    sections.push({ label: "Navigate", items: navigate })

    if (sections.length === 0) {
      // Tenant-less surface with no LRU history — render a friendly
      // hint instead of the generic "no matches" empty state.
      this.resultsTarget.innerHTML = `
        <div class="px-4 py-10 text-center text-voodu-muted">
          <div class="text-[13px]">Type to search ${this.commands.length} commands</div>
          <div class="text-[11.5px] mt-2">pods · logs · metrics · restart · server switch</div>
        </div>`
      if (this.hasCountTarget) this.countTarget.textContent = String(this.commands.length)
      this.flat = []
      return
    }

    this.renderSections(sections, "")
  }

  renderSections(sections, query) {
    this.flat = sections.flatMap(s => s.items)
    this.selected = 0

    if (this.flat.length === 0) {
      this.resultsTarget.innerHTML = `
        <div class="px-4 py-10 text-center text-voodu-muted">
          <div class="text-[13px]">No matches for "<span class="font-voodu-mono text-voodu-text-2">${escapeHtml(query)}</span>"</div>
          <div class="text-[11.5px] mt-2">Try a pod name, "logs", "restart", or a navigate command.</div>
        </div>`
      if (this.hasCountTarget) this.countTarget.textContent = "0"
      return
    }

    const parts = []
    let runningIndex = 0
    for (const sec of sections) {
      parts.push(`
        <div class="mb-1">
          <div class="px-3.5 pt-2 pb-1 text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted flex items-center gap-2">
            <span>${escapeHtml(sec.label)}</span>
            <span class="flex-1 h-px bg-voodu-border"></span>
            <span class="font-normal text-voodu-muted-2">${sec.items.length}</span>
          </div>
      `)
      for (const cmd of sec.items) {
        parts.push(renderRow(cmd, runningIndex, runningIndex === this.selected, query))
        runningIndex++
      }
      parts.push(`</div>`)
    }
    this.resultsTarget.innerHTML = parts.join("")
    if (this.hasCountTarget) this.countTarget.textContent = String(this.flat.length)

    this.bindRowDelegation()
  }

  bindRowDelegation() {
    if (this._rowBound) return
    this._rowBound = true
    this.resultsTarget.addEventListener("click", (e) => {
      const row = e.target.closest("[data-cmd-index]")
      if (!row) return
      this.selected = parseInt(row.dataset.cmdIndex, 10)
      this.runSelected()
    })
    this.resultsTarget.addEventListener("mousemove", (e) => {
      const row = e.target.closest("[data-cmd-index]")
      if (!row) return
      const i = parseInt(row.dataset.cmdIndex, 10)
      if (i !== this.selected) {
        this.selected = i
        this.refreshSelection()
      }
    })
  }

  refreshSelection() {
    this.resultsTarget.querySelectorAll("[data-cmd-index]").forEach(row => {
      const i = parseInt(row.dataset.cmdIndex, 10)
      const selected = i === this.selected
      const destructive = row.dataset.cmdDestructive === "true"
      row.setAttribute("aria-selected", selected ? "true" : "false")
      row.dataset.cmdSelected = selected ? "true" : "false"
      const base = "grid items-center gap-3 px-3.5 py-2 min-h-10 cursor-pointer border-l-2 transition-colors"
      const idle = " border-transparent"
      const sel  = destructive
        ? " border-voodu-red bg-voodu-red-dim/40"
        : " border-voodu-accent-line bg-voodu-accent-dim"
      row.className = base + (selected ? sel : idle)
    })
  }

  scrollSelectedIntoView() {
    const row = this.resultsTarget.querySelector(`[data-cmd-index="${this.selected}"]`)
    if (!row) return
    const c = this.resultsTarget
    const r = row.getBoundingClientRect()
    const cr = c.getBoundingClientRect()
    if (r.top < cr.top) c.scrollTop -= (cr.top - r.top + 4)
    else if (r.bottom > cr.bottom) c.scrollTop += (r.bottom - cr.bottom + 4)
  }

  // ── run ─────────────────────────────────────────────────────────

  runSelected() {
    const cmd = this.flat[this.selected]
    if (!cmd) return
    if (cmd.confirm && !window.confirm(cmd.confirm)) return

    // Stamp the LRU BEFORE navigating — once we set location.href
    // the JS context dies. localStorage write is synchronous, so
    // this is safe.
    pushLRU(cmd.id)

    this.close()

    const method = (cmd.method || "GET").toUpperCase()
    if (method === "GET") {
      window.location.href = cmd.href
      return
    }

    const form = document.createElement("form")
    form.method = "post"
    form.action = cmd.href
    form.style.display = "none"

    if (method !== "POST") {
      const m = document.createElement("input")
      m.type = "hidden"; m.name = "_method"; m.value = method.toLowerCase()
      form.appendChild(m)
    }

    const t = document.createElement("input")
    t.type = "hidden"; t.name = "authenticity_token"; t.value = this.csrfValue
    form.appendChild(t)

    document.body.appendChild(form)
    form.submit()
  }

  // ── scroll lock ─────────────────────────────────────────────────

  lockScroll() {
    this.prevHtmlOverflow = document.documentElement.style.overflow
    this.prevBodyOverflow = document.body.style.overflow
    document.documentElement.style.overflow = "hidden"
    document.body.style.overflow = "hidden"
  }

  unlockScroll() {
    document.documentElement.style.overflow = this.prevHtmlOverflow ?? ""
    document.body.style.overflow            = this.prevBodyOverflow ?? ""
  }
}

// ── cache helpers (sessionStorage, 30s TTL) ───────────────────────

// readCache — returns the FULL envelope { ts, commands } regardless
// of TTL, or null when malformed/absent. SWR-friendly: the caller
// decides what to do with stale data via isFresh().
function readCache() {
  try {
    const raw = sessionStorage.getItem(CACHE_KEY)
    if (!raw) return null
    const env = JSON.parse(raw)
    if (!env || typeof env.ts !== "number" || !Array.isArray(env.commands)) return null

    return env
  } catch {
    return null
  }
}

// isFresh — boolean check against the TTL. Used to decide whether
// to kick a background refresh, NOT whether to render the cache.
function isFresh(env) {
  return env != null && Date.now() - env.ts < CACHE_TTL_MS
}

function writeCache(commands) {
  try {
    sessionStorage.setItem(CACHE_KEY, JSON.stringify({ ts: Date.now(), commands }))
  } catch {
    // QuotaExceeded — palette still works, just not cached.
  }
}

// ── LRU helpers (localStorage, cap 8) ─────────────────────────────

function readLRU() {
  try {
    const raw = localStorage.getItem(LRU_KEY)
    if (!raw) return []
    const arr = JSON.parse(raw)

    return Array.isArray(arr) ? arr.filter(x => typeof x === "string") : []
  } catch {
    return []
  }
}

function pushLRU(id) {
  try {
    const cur = readLRU().filter(x => x !== id)
    cur.unshift(id)
    localStorage.setItem(LRU_KEY, JSON.stringify(cur.slice(0, LRU_CAP)))
  } catch {
    // QuotaExceeded — silent fall back, palette still works.
  }
}

// ── URL helpers ───────────────────────────────────────────────────

function detectCurrentTenantKey() {
  const m = location.pathname.match(TENANT_KEY_RE)

  return m ? m[1] : null
}

function appendCurrent(endpoint) {
  const cur = detectCurrentTenantKey()
  if (!cur) return endpoint
  const sep = endpoint.includes("?") ? "&" : "?"

  return `${endpoint}${sep}current=${encodeURIComponent(cur)}`
}

// ── scoring ───────────────────────────────────────────────────────

// scoreCommand — fuzzy ranker. Returns null when ANY query term
// fails to appear in the command's corpus (title + subtitle + match
// blob); otherwise sums positional + group weights.
function scoreCommand(cmd, query) {
  if (!query) return 0
  const q = query.toLowerCase().trim()
  if (!q) return 0

  const title  = cmd.title.toLowerCase()
  const corpus = (cmd.title + " " + (cmd.subtitle || "") + " " + (cmd.match || "")).toLowerCase()
  const terms  = q.split(/\s+/).filter(Boolean)

  let score = 0
  for (const term of terms) {
    if (corpus.indexOf(term) < 0) return null

    const ti = title.indexOf(term)
    if (ti === 0) {
      score += 1000
    } else if (ti > 0) {
      const before = title[ti - 1]
      if (before === " " || before === "." || before === "/" || before === "-") score += 500
      else score += 200
      score -= ti * 0.5
    } else {
      score += 50
    }
  }
  score += GROUP_BOOST[cmd.group] || 0

  return score
}

function groupCommands(commands) {
  const m = new Map()
  for (const c of commands) {
    if (!m.has(c.group)) m.set(c.group, [])
    m.get(c.group).push(c)
  }

  return Array.from(m.entries()).map(([label, items]) => ({ label, items }))
}

// ── icon map ──────────────────────────────────────────────────────
//
// Inline SVG paths so the palette renders without any runtime icon
// pack loading. Heroicons-v2 outline (stroke 1.5, viewBox 24×24).
// Stroke uses currentColor so parent text-* classes win.
//
// When CommandSet adds a new icon name, drop the matching path here.
// Unknown icon names fall back to the muted dot in leadingIndicator().

const SVG_WRAP_START = `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-3.5 h-3.5"><path stroke-linecap="round" stroke-linejoin="round" d="`
const SVG_WRAP_END   = `"/></svg>`

function ico(d) {
  return SVG_WRAP_START + d + SVG_WRAP_END
}

const ICON_MAP = {
  Squares2x2Outline: ico("M3.75 6A2.25 2.25 0 016 3.75h2.25A2.25 2.25 0 0110.5 6v2.25a2.25 2.25 0 01-2.25 2.25H6a2.25 2.25 0 01-2.25-2.25V6zM3.75 15.75A2.25 2.25 0 016 13.5h2.25a2.25 2.25 0 012.25 2.25V18a2.25 2.25 0 01-2.25 2.25H6A2.25 2.25 0 013.75 18v-2.25zM13.5 6a2.25 2.25 0 012.25-2.25H18A2.25 2.25 0 0120.25 6v2.25A2.25 2.25 0 0118 10.5h-2.25a2.25 2.25 0 01-2.25-2.25V6zM13.5 15.75a2.25 2.25 0 012.25-2.25H18a2.25 2.25 0 012.25 2.25V18A2.25 2.25 0 0118 20.25h-2.25A2.25 2.25 0 0113.5 18v-2.25z"),

  CubeOutline: ico("M21 7.5l-9-5.25L3 7.5m18 0l-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9"),

  DocumentTextOutline: ico("M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z"),

  ChartBarOutline: ico("M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z"),

  BellOutline: ico("M14.857 17.082a23.848 23.848 0 005.454-1.31A8.967 8.967 0 0118 9.75v-.7V9A6 6 0 006 9v.75a8.967 8.967 0 01-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 01-5.714 0m5.714 0a3 3 0 11-5.714 0"),

  // Cog has two paths (outer gear + inner circle). Custom-wrap.
  Cog6ToothOutline: `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" class="w-3.5 h-3.5"><path stroke-linecap="round" stroke-linejoin="round" d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.324.196.72.257 1.076.124l1.217-.456a1.125 1.125 0 011.37.49l1.296 2.247a1.125 1.125 0 01-.26 1.431l-1.003.827c-.293.24-.438.613-.431.992a6.759 6.759 0 010 .255c-.007.378.138.75.43.99l1.005.828c.424.35.534.954.26 1.43l-1.298 2.247a1.125 1.125 0 01-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.57 6.57 0 01-.22.128c-.331.183-.581.495-.644.869l-.213 1.28c-.09.543-.56.941-1.11.941h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 01-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 01-1.369-.49l-1.297-2.247a1.125 1.125 0 01.26-1.431l1.004-.827c.292-.24.437-.613.43-.992a6.932 6.932 0 010-.255c.007-.378-.138-.75-.43-.99l-1.004-.828a1.125 1.125 0 01-.26-1.43l1.297-2.247a1.125 1.125 0 011.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.213-1.28z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/></svg>`,

  ArrowPathOutline: ico("M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0l3.181 3.183a8.25 8.25 0 0013.803-3.7M4.031 9.865a8.25 8.25 0 0113.803-3.7l3.181 3.182m0-4.991v4.99"),

  PlusOutline: ico("M12 4.5v15m7.5-7.5h-15"),

  ServerStackOutline: ico("M5.25 14.25h13.5m-13.5 0a3 3 0 01-3-3m3 3a3 3 0 100 6h13.5a3 3 0 100-6m-16.5-3a3 3 0 013-3h13.5a3 3 0 013 3m-19.5 0a4.5 4.5 0 01.9-2.7L5.737 5.1a3.375 3.375 0 012.7-1.35h7.126c1.062 0 2.062.5 2.7 1.35l2.587 3.45a4.5 4.5 0 01.9 2.7m0 0a3 3 0 01-3 3m0 3h.008v.008h-.008v-.008zm0-6h.008v.008h-.008v-.008zm-3 6h.008v.008h-.008v-.008zm0-6h.008v.008h-.008v-.008z")
}

// ── row rendering ─────────────────────────────────────────────────

function renderRow(cmd, index, selected, query) {
  const destructive = cmd.destructive ? "true" : "false"
  const base = "grid items-center gap-3 px-3.5 py-2 min-h-10 cursor-pointer border-l-2 transition-colors"
  const idle = " border-transparent"
  const sel  = cmd.destructive
    ? " border-voodu-red bg-voodu-red-dim/40"
    : " border-voodu-accent-line bg-voodu-accent-dim"

  const titleColor = cmd.destructive
    ? (selected ? "text-voodu-red" : "text-voodu-text")
    : (selected ? "text-voodu-accent-2" : "text-voodu-text")
  const titleWeight = selected ? "font-semibold" : "font-medium"

  const hint = cmd.shortcut?.length
    ? cmd.shortcut.map(k => `<kbd class="font-voodu-mono text-[10.5px] px-1.5 h-[18px] inline-flex items-center justify-center border border-voodu-border bg-voodu-bg-2 text-voodu-muted">${escapeHtml(k)}</kbd>`).join("")
    : (selected ? `<span class="font-voodu-mono text-[10.5px] text-voodu-muted">${cmd.destructive ? "run ↵" : "go ↵"}</span>` : "")

  return `
    <div data-cmd-index="${index}" data-cmd-destructive="${destructive}" data-cmd-selected="${selected}"
         role="option" aria-selected="${selected}"
         class="${base}${selected ? sel : idle}"
         style="grid-template-columns: 20px 1fr auto;">
      <span class="inline-flex items-center justify-center w-[20px] text-voodu-muted">
        ${leadingIndicator(cmd)}
      </span>
      <div class="min-w-0">
        <div class="text-[13px] ${titleWeight} ${titleColor} truncate">${highlight(cmd.title, query)}</div>
        ${cmd.subtitle ? `<div class="text-[11px] text-voodu-muted font-voodu-mono mt-px truncate">${highlight(cmd.subtitle, query)}</div>` : ""}
      </div>
      <div class="flex items-center gap-1 shrink-0">${hint}</div>
    </div>
  `
}

// leadingIndicator — status dot wins over icon, dot fallback wins
// over nothing. Picking the right glyph here is what makes the
// palette skim-readable (icon = action, dot = state).
function leadingIndicator(cmd) {
  if (cmd.status) {
    const c = statusColor(cmd.status)

    return `<span aria-hidden="true" class="inline-block w-[7px] h-[7px] rounded-full" style="background:${c}"></span>`
  }

  const svg = cmd.icon && ICON_MAP[cmd.icon]
  if (svg) return svg

  return `<span aria-hidden="true" class="inline-block w-[5px] h-[5px] rounded-full bg-voodu-muted-2"></span>`
}

function statusColor(s) {
  switch (s) {
    case "running":
    case "online":     return "var(--voodu-green)"
    case "restarting": return "var(--voodu-amber)"
    case "stopped":
    case "offline":    return "var(--voodu-red)"
    default:           return "var(--voodu-muted)"
  }
}

// highlight — wrap matched substrings in <mark> with accent style.
// Case-insensitive across all query terms.
function highlight(text, query) {
  if (!query) return escapeHtml(text)
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (!terms.length) return escapeHtml(text)

  const lower = text.toLowerCase()
  const ranges = []

  for (const term of terms) {
    let i = 0

    while (i < lower.length) {
      const idx = lower.indexOf(term, i)
      if (idx < 0) break
      ranges.push([idx, idx + term.length])
      i = idx + term.length
    }
  }

  if (!ranges.length) return escapeHtml(text)

  ranges.sort((a, b) => a[0] - b[0])
  const merged = [ranges[0]]

  for (let i = 1; i < ranges.length; i++) {
    const last = merged[merged.length - 1]
    if (ranges[i][0] <= last[1]) last[1] = Math.max(last[1], ranges[i][1])
    else merged.push(ranges[i])
  }

  const out = []
  let pos = 0

  for (const [s, e] of merged) {
    if (s > pos) out.push(escapeHtml(text.slice(pos, s)))
    out.push(`<mark class="bg-voodu-accent-dim text-voodu-accent-2 font-semibold px-px">${escapeHtml(text.slice(s, e))}</mark>`)
    pos = e
  }

  if (pos < text.length) out.push(escapeHtml(text.slice(pos)))

  return out.join("")
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
}
