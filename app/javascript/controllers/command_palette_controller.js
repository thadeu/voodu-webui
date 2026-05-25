import { Controller } from "@hotwired/stimulus"

// CommandPaletteController — ⌘K palette behaviour.
//
// Server dumps the full command list as JSON; this controller
// owns:
//   - Cmd-K / Ctrl-K global open (any page, any focus)
//   - ESC / backdrop / clear-X close
//   - ↑↓ navigation, PgUp/PgDn/Home/End jumps, Enter run
//   - Fuzzy filter + score (ported from inspiration's palette.jsx)
//   - Group rendering with section labels + counts
//   - Highlight matched query terms inline
//   - Run: GET commands → location.href; POST/DELETE → dynamic
//     form with CSRF token (avoids rendering N hidden forms)
//   - Body scroll lock + initial focus
//
// All filtering is client-side so keystrokes have zero latency.
// At ~100-200 commands the score loop is microseconds.
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

  static values  = {
    commands:    Array,
    suggestions: Array,
    csrf:        String
  }

  connect() {
    this.onGlobalKey = this.onGlobalKey.bind(this)
    this.onLocalKey  = this.onLocalKey.bind(this)
    this.selected    = 0
    this.flat        = []

    document.addEventListener("keydown", this.onGlobalKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onGlobalKey)
    if (this.isOpen) this.unlockScroll()
  }

  // ── lifecycle ───────────────────────────────────────────────────

  open(event) {
    event?.preventDefault()
    if (this.isOpen) return
    this.isOpen = true

    this.backdropTarget.hidden = false
    this.dialogTarget.hidden   = false
    this.inputTarget.value     = ""
    this.selected              = 0
    this.lockScroll()

    document.addEventListener("keydown", this.onLocalKey)

    requestAnimationFrame(() => {
      this.inputTarget.focus({ preventScroll: true })
      this.renderDefault()
    })
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

  // ── keyboard ────────────────────────────────────────────────────

  onGlobalKey(event) {
    // Cmd-K (Mac) / Ctrl-K (Windows/Linux). Skip when the operator
    // is already inside an input that owns Cmd-K (none today), or
    // when a different modal is in the way (Modal/Confirmable/Drawer
    // all preventDefault their own keys before this fires).
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
    const q = this.inputTarget.value.trim()
    this.clearTarget.hidden = !q

    if (!q) {
      this.renderDefault()
      return
    }

    const scored = []
    for (const cmd of this.commandsValue) {
      const s = scoreCommand(cmd, q)
      if (s !== null && s > 0) scored.push({ cmd, score: s })
    }
    scored.sort((a, b) => b.score - a.score)
    const top = scored.slice(0, 80).map(r => r.cmd)

    this.renderSections(groupCommands(top), q)
  }

  renderDefault() {
    const suggestions = this.commandsValue.filter(c => this.suggestionsValue.includes(c.id))
    const navigate    = this.commandsValue.filter(c => c.group === "Navigate")

    const sections = []
    if (suggestions.length) sections.push({ label: "Suggestions", items: suggestions })
    if (navigate.length)    sections.push({ label: "Navigate",    items: navigate })

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

    this.close()

    const method = (cmd.method || "GET").toUpperCase()
    if (method === "GET") {
      window.location.href = cmd.href
      return
    }

    // POST / DELETE → build a hidden form with CSRF token + submit.
    // Avoids rendering N hidden forms per page (one per palette
    // command); cost is one form per execution, negligible.
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

// ── pure helpers ──────────────────────────────────────────────────

// scoreCommand — fuzzy ranker. Returns null when ANY query term
// fails to appear in the command's corpus (title + subtitle + match
// blob); otherwise sums positional + group weights.
//
// Weights match inspiration's palette.jsx so behaviour parity is
// preserved between the React prototype and this port.
function scoreCommand(cmd, query) {
  if (!query) return 0
  const q = query.toLowerCase().trim()
  if (!q) return 0

  const title = cmd.title.toLowerCase()
  const corpus = (cmd.title + " " + (cmd.subtitle || "") + " " + (cmd.match || "")).toLowerCase()
  const terms = q.split(/\s+/).filter(Boolean)

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
         style="grid-template-columns: 18px 1fr auto;">
      <span class="inline-flex items-center justify-center w-[18px] text-voodu-muted">
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

function leadingIndicator(cmd) {
  if (cmd.status) {
    const c = statusColor(cmd.status)
    return `<span aria-hidden="true" class="inline-block w-[7px] h-[7px] rounded-full" style="background:${c}"></span>`
  }
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
// Case-insensitive across all query terms. Reused from inspiration.
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
