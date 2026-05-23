import { Controller } from "@hotwired/stimulus"

// LogStreamController — live tail viewer.
//
// Two modes selected by the `streamUrl` data value:
//
//   1. Real stream  → `data-log-stream-stream-url-value="/logs/foo/stream"`
//      The controller opens a `fetch()` against that URL (which the
//      Rails LogsController#stream proxies onto the PAT plane's
//      `?follow=true` endpoint) and processes the chunked text/plain
//      response. Each \n-delimited line becomes one log row.
//
//   2. Mock stream  → no streamUrl value (the multi-source /logs page)
//      Falls back to the synthetic generator ported from the design
//      beta. Stays mock until the PAT plane exposes a multi-pod
//      aggregation endpoint.
//
// Toolbar behaviour (filter / level / follow / wrap / pause / clear)
// is identical in both modes — the row append function is the seam.
export default class extends Controller {
  static values = {
    pod:       String,
    streamUrl: String,
    bufferCap: { type: Number, default: 700 },
  }

  static targets = [
    "stateLabel", "stateDot",
    "rate", "buffer", "visible", "sources",
    "filter", "level", "follow", "wrap", "pause",
    "viewport", "list", "empty", "jumpToLive",
  ]

  // ── Lifecycle ─────────────────────────────────────────────────────

  connect() {
    this.buffer        = []
    this.visibleCount  = 0
    this.paused        = false
    this.follow        = true
    this.wrap          = false
    this.query         = ""
    this.activeLevels  = new Set(["HTTP", "INFO", "WARN", "ERROR"])
    this.userScrolled  = false
    this.streamAbort   = null
    this.mockTimer     = null
    this.rateTimer     = null
    this.lineBuffer    = "" // partial-line carry between chunks

    this.streaming = this.streamUrlValue && this.streamUrlValue.length > 0

    this.pool = this.streaming
      ? [this.podValue]
      : Object.keys(POD_PROFILES)

    this.updateSources()

    if (this.streaming) {
      this.openStream()
    } else {
      this.backfillMock()
      this.startMockStream()
    }

    this.startRateTicker()
  }

  disconnect() {
    if (this.mockTimer) clearTimeout(this.mockTimer)
    if (this.rateTimer) clearInterval(this.rateTimer)
    if (this.streamAbort) this.streamAbort.abort()
  }

  // ── User actions ───────────────────────────────────────────────────

  togglePause() {
    this.paused = !this.paused
    this.refreshStateChrome()
    if (this.streaming) {
      // For a real stream "pause" just stops appending; we keep the
      // socket open so unpausing doesn't drop the in-flight tail.
      // (We still flag paused so appendLog short-circuits below.)
    } else if (this.paused) {
      if (this.mockTimer) { clearTimeout(this.mockTimer); this.mockTimer = null }
    } else {
      this.startMockStream()
    }
  }

  toggleFollow() {
    this.follow = !this.follow
    this.refreshToggleButton(this.followTarget, this.follow)
    if (this.follow) {
      this.userScrolled = false
      this.scrollToBottom()
      this.hideJumpToLive()
    }
  }

  toggleWrap() {
    this.wrap = !this.wrap
    this.refreshToggleButton(this.wrapTarget, this.wrap)
    this.listTarget.classList.toggle("log-wrap", this.wrap)
  }

  toggleLevel(event) {
    const btn = event.currentTarget
    const lvl = btn.dataset.level
    if (this.activeLevels.has(lvl)) this.activeLevels.delete(lvl)
    else this.activeLevels.add(lvl)
    this.refreshLevelButton(btn, this.activeLevels.has(lvl), lvl)
    this.applyFilter()
  }

  applyFilter() {
    this.query = (this.hasFilterTarget ? this.filterTarget.value : "").trim().toLowerCase()
    let count = 0
    for (const row of this.listTarget.children) {
      const ok = this.rowMatches(row)
      row.hidden = !ok
      if (ok) count++
    }
    this.visibleCount = count
    this.visibleTarget.textContent = count
    this.emptyTarget.hidden = count > 0
    if (this.follow) this.scrollToBottom()
  }

  clear() {
    this.buffer = []
    this.listTarget.innerHTML = ""
    this.visibleCount = 0
    this.bufferTarget.textContent  = "0"
    this.visibleTarget.textContent = "0"
    this.emptyTarget.hidden = false
  }

  jumpToLive() {
    this.follow = true
    this.userScrolled = false
    this.refreshToggleButton(this.followTarget, true)
    this.scrollToBottom()
    this.hideJumpToLive()
  }

  onScroll() {
    const el = this.viewportTarget
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 24
    if (!atBottom && this.follow) {
      this.userScrolled = true
      this.follow = false
      this.refreshToggleButton(this.followTarget, false)
      this.showJumpToLive()
    } else if (atBottom && !this.follow && this.userScrolled) {
      this.follow = true
      this.userScrolled = false
      this.refreshToggleButton(this.followTarget, true)
      this.hideJumpToLive()
    }
  }

  // ── Real stream ────────────────────────────────────────────────────

  async openStream() {
    this.streamAbort = new AbortController()
    let resp
    try {
      resp = await fetch(this.streamUrlValue, {
        signal: this.streamAbort.signal,
        headers: { "Accept": "text/plain" },
        credentials: "same-origin",
      })
    } catch (e) {
      if (e.name === "AbortError") return
      this.appendSyntheticError(`fetch failed: ${e.message}`)
      return
    }

    if (!resp.ok) {
      this.appendSyntheticError(`HTTP ${resp.status} ${resp.statusText}`)
      return
    }

    const reader  = resp.body.getReader()
    const decoder = new TextDecoder("utf-8")

    try {
      while (true) {
        const { value, done } = await reader.read()
        if (done) break
        const text = decoder.decode(value, { stream: true })
        this.consumeChunk(text)
      }
      // Flush any trailing partial line that wasn't terminated.
      if (this.lineBuffer) {
        this.ingestLine(this.lineBuffer)
        this.lineBuffer = ""
      }
    } catch (e) {
      if (e.name === "AbortError") return
      this.appendSyntheticError(`stream broke: ${e.message}`)
    }
  }

  // consumeChunk — accumulate bytes, split on \n, emit complete lines.
  // Keeps the trailing partial line in `this.lineBuffer` for the next
  // chunk so a line that arrives in two reads renders once, intact.
  consumeChunk(text) {
    this.lineBuffer += text
    let idx
    while ((idx = this.lineBuffer.indexOf("\n")) >= 0) {
      const line = this.lineBuffer.slice(0, idx).replace(/\r$/, "")
      this.lineBuffer = this.lineBuffer.slice(idx + 1)
      if (line.length > 0) this.ingestLine(line)
    }
  }

  ingestLine(line) {
    const parsed = parseLogLine(line, this.podValue)
    if (parsed) this.appendLog(parsed)
  }

  appendSyntheticError(msg) {
    this.appendLog({
      id: nextId(), ts: new Date(),
      pod: this.podValue || "stream",
      ip: "—",
      level: "ERROR", type: "message",
      message: msg,
    })
  }

  // ── Mock stream (multi-source fallback) ───────────────────────────

  backfillMock() {
    const back = []
    const now = Date.now()
    for (let i = 60; i > 0; i--) {
      const log = makeLog(pick(this.pool))
      if (!log) continue
      log.ts = new Date(now - i * 180 - Math.random() * 200)
      back.push(log)
    }
    back.sort((a, b) => a.ts - b.ts)
    for (const log of back) this.appendLog(log, { skipFollow: true })
    this.scrollToBottom()
  }

  startMockStream() {
    const tick = () => {
      if (this.paused) return
      const burst = Math.random() < 0.18
      const batchSize = burst ? 2 + Math.floor(Math.random() * 4) : 1
      for (let i = 0; i < batchSize; i++) {
        const log = makeLog(pick(this.pool))
        if (log) this.appendLog(log)
      }
      const delay = burst ? 40 : 90 + Math.random() * 280
      this.mockTimer = setTimeout(tick, delay)
    }
    this.mockTimer = setTimeout(tick, 120)
  }

  startRateTicker() {
    this.rateTimer = setInterval(() => {
      if (this.buffer.length < 2) {
        this.rateTarget.textContent = "0"
        return
      }
      const last = this.buffer.slice(-100)
      const span = last[last.length - 1].ts - last[0].ts
      const rate = span <= 0 ? last.length : Math.round((last.length / span) * 1000 * 10) / 10
      this.rateTarget.textContent = rate
    }, 1000)
  }

  // ── Append + render ───────────────────────────────────────────────

  appendLog(log, opts = {}) {
    // When paused, drop incoming logs on the floor — they don't go
    // into the buffer either, so counters reflect a true freeze.
    if (this.paused && !opts.skipPause) return

    this.buffer.push(log)
    while (this.buffer.length > this.bufferCapValue) {
      this.buffer.shift()
      if (this.listTarget.firstChild) {
        const dropped = this.listTarget.firstChild
        if (!dropped.hidden) this.visibleCount--
        this.listTarget.removeChild(dropped)
      }
    }

    const row = this.renderRow(log)
    const matches = this.rowMatches(row)
    row.hidden = !matches
    this.listTarget.appendChild(row)

    if (matches) this.visibleCount++
    this.bufferTarget.textContent  = this.buffer.length
    this.visibleTarget.textContent = this.visibleCount
    this.emptyTarget.hidden = this.visibleCount > 0

    if (this.follow && !opts.skipFollow) this.scrollToBottom()
  }

  renderRow(log) {
    const tone = LEVEL_TONE[log.level] || LEVEL_TONE.INFO
    const pc   = podColor(log.pod)
    const sp   = shortPod(log.pod)
    const row  = document.createElement("div")
    row.className = "log-row"
    row.dataset.level = log.level
    row.dataset.search = `${log.pod} ${log.ip} ${log.method || ""} ${log.path || ""} ${log.status || ""} ${log.message || ""}`.toLowerCase()
    row.style.borderLeftColor = pc
    row.title = `${fmtFullTime(log.ts)}  ${log.pod}  ${log.ip}`

    const ts = document.createElement("span")
    ts.className = "log-ts"
    ts.textContent = fmtTime(log.ts)
    row.appendChild(ts)

    const lvl = document.createElement("span")
    lvl.className = "log-level"
    lvl.textContent = log.level
    lvl.style.color = tone.color
    lvl.style.background = tone.bg
    lvl.style.border = `1px solid ${tone.border}`
    row.appendChild(lvl)

    const pod = document.createElement("span")
    pod.className = "log-pod"
    pod.textContent = sp
    pod.style.color = pc
    row.appendChild(pod)

    const ip = document.createElement("span")
    ip.className = "log-ip"
    ip.textContent = log.ip
    row.appendChild(ip)

    const body = document.createElement("span")
    body.className = "log-body"

    if (log.type === "request") {
      const method = document.createElement("span")
      method.style.color = methodColor(log.method)
      method.style.fontWeight = "600"
      method.textContent = log.method
      body.appendChild(method)
      body.appendChild(document.createTextNode(" "))
      const path = document.createElement("span")
      path.style.color = "var(--voodu-text)"
      path.textContent = log.path
      body.appendChild(path)
    } else if (log.type === "response") {
      const arrow = document.createElement("span")
      arrow.style.color = "var(--voodu-muted)"
      arrow.textContent = "← "
      body.appendChild(arrow)
      const status = document.createElement("span")
      status.style.color = statusColor(log.status)
      status.style.fontWeight = "600"
      status.textContent = log.status
      body.appendChild(status)
      const dur = document.createElement("span")
      dur.style.color = "var(--voodu-muted)"
      dur.textContent = ` · ${log.durationMs}ms`
      body.appendChild(dur)
    } else {
      const msg = document.createElement("span")
      msg.style.color = tone.color
      msg.textContent = log.message
      body.appendChild(msg)
    }

    row.appendChild(body)
    return row
  }

  rowMatches(row) {
    if (!this.activeLevels.has(row.dataset.level)) return false
    if (this.query && !row.dataset.search.includes(this.query)) return false
    return true
  }

  // ── Chrome updates ────────────────────────────────────────────────

  refreshStateChrome() {
    if (this.hasStateLabelTarget) {
      this.stateLabelTarget.textContent = this.paused ? "paused" : "streaming live"
    }
    if (this.hasStateDotTarget) {
      this.stateDotTarget.style.background = this.paused ? "var(--voodu-muted)" : "var(--voodu-green)"
      this.stateDotTarget.style.boxShadow  = this.paused ? "none" : "0 0 0 3px color-mix(in srgb, var(--voodu-green) 18%, transparent)"
      this.stateDotTarget.style.animation  = this.paused ? "none" : "voodu-pulse 2.4s ease-in-out infinite"
    }
    if (this.hasPauseTarget) {
      this.pauseTarget.querySelector("[data-pause-label]").textContent = this.paused ? "Resume" : "Pause"
    }
  }

  refreshToggleButton(btn, active) {
    btn.dataset.active = active ? "true" : "false"
  }

  refreshLevelButton(btn, active, level) {
    const tone = LEVEL_TONE[level] || LEVEL_TONE.INFO
    btn.dataset.active = active ? "true" : "false"
    if (active) {
      btn.style.color = tone.color
      btn.style.background = tone.bg
      btn.style.borderColor = tone.border
    } else {
      btn.style.color = ""
      btn.style.background = ""
      btn.style.borderColor = ""
    }
  }

  updateSources() {
    if (this.hasSourcesTarget) this.sourcesTarget.textContent = this.pool.length
  }

  scrollToBottom() {
    if (!this.hasViewportTarget) return
    const el = this.viewportTarget
    el.scrollTop = el.scrollHeight
  }

  showJumpToLive() {
    if (this.hasJumpToLiveTarget) this.jumpToLiveTarget.hidden = false
  }

  hideJumpToLive() {
    if (this.hasJumpToLiveTarget) this.jumpToLiveTarget.hidden = true
  }
}

// ─── Line parser for real stream ──────────────────────────────────────
//
// The PAT plane forwards raw container stdout/stderr — no level/IP
// structure is guaranteed. We heuristically classify each line:
//
//   - ISO timestamp prefix → strip + use it as the row timestamp
//   - "GET /path"          → HTTP request
//   - "← 200 · 5ms"        → HTTP response (already shaped by our CLI)
//   - regex /\b(ERROR|FATAL)\b/i → ERROR
//   - regex /\b(WARN|WARNING)\b/i → WARN
//   - else                 → INFO
//
// IP is parsed from the line if it looks like a leading IPv4 with
// space; otherwise "—". When the upstream evolves to ship structured
// log lines, replace this with the real parser.

const ISO_RE       = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\s+(.*)$/
const HTTP_REQ_RE  = /^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\S+)/
const HTTP_RES_RE  = /(\d{3})\s+(\d+)ms\b/
const IPV4_RE      = /\b(\d{1,3}(?:\.\d{1,3}){3})\b/

function parseLogLine(raw, podName) {
  let line = raw
  let ts = new Date()

  const isoMatch = line.match(ISO_RE)
  if (isoMatch) {
    const parsed = new Date(isoMatch[1])
    if (!isNaN(parsed)) ts = parsed
    line = isoMatch[2]
  }

  const ipMatch = line.match(IPV4_RE)
  const ip = ipMatch ? ipMatch[1] : "—"

  // HTTP request
  const reqMatch = line.match(HTTP_REQ_RE)
  if (reqMatch) {
    return { id: nextId(), ts, pod: podName, ip, level: "HTTP", type: "request",
             method: reqMatch[1], path: reqMatch[2] }
  }

  // HTTP response shape (rare in raw container logs but our CLI uses it)
  const resMatch = line.match(HTTP_RES_RE)
  if (resMatch) {
    return { id: nextId(), ts, pod: podName, ip, level: "HTTP", type: "response",
             status: parseInt(resMatch[1], 10), durationMs: parseInt(resMatch[2], 10) }
  }

  let level = "INFO"
  if (/\b(ERROR|FATAL|panic)\b/i.test(line)) level = "ERROR"
  else if (/\b(WARN|WARNING)\b/i.test(line)) level = "WARN"

  return { id: nextId(), ts, pod: podName, ip, level, type: "message", message: line }
}

let _id = 1
function nextId() { return _id++ }

// ─── Mock generator (kept for /logs multi-source) ──────────────────

const PAGE_PATHS = [
  "/", "/docs", "/docs/quickstart", "/docs/api-reference",
  "/docs/api-reference/pods", "/docs/api-reference/servers",
  "/docs/concepts/scopes", "/docs/concepts/replicas",
]
const STATIC_PATHS = [
  "/_next/static/chunks/main-app.js",
  "/_next/static/chunks/pages/_app.js",
  "/_next/static/chunks/pages/docs.js",
  "/_next/static/css/app.css",
  "/favicon.ico", "/manifest.json", "/robots.txt",
]
const API_PATHS = [
  "/api/v1/pods", "/api/v1/pods/clowk-vd-docs.35a3",
  "/api/v1/pods/clowk-vd-docs.35a3/stats",
  "/api/v1/servers", "/api/v1/auth/session",
  "/api/v1/events?since=1716503400",
  "/api/v1/metrics/cpu?range=1h",
]
const HEALTH_PATHS = ["/healthz", "/readyz", "/metrics"]

const POD_PROFILES = {
  "clowk-vd-docs.35a3": {
    paths: () => Math.random() < 0.72 ? pick(STATIC_PATHS) : pick(PAGE_PATHS),
    methods: { GET: 0.95, HEAD: 0.05 },
    statusMix: { 200: 0.38, 304: 0.55, 404: 0.07 },
    infoMsgs: ["Compiled /docs/api-reference in 124ms", "Static cache hit ratio 0.94 over last 60s"],
  },
  "clowk-vd-docs.8f4c": {
    paths: () => Math.random() < 0.72 ? pick(STATIC_PATHS) : pick(PAGE_PATHS),
    methods: { GET: 0.95, HEAD: 0.05 },
    statusMix: { 200: 0.38, 304: 0.55, 404: 0.07 },
    infoMsgs: ["Static cache evicted 12 entries"],
  },
  "clowk-vd-api.91ba": {
    paths: () => Math.random() < 0.55 ? pick(API_PATHS) : pick(HEALTH_PATHS),
    methods: { GET: 0.7, POST: 0.15, PUT: 0.05, DELETE: 0.05, OPTIONS: 0.05 },
    statusMix: { 200: 0.55, 201: 0.05, 204: 0.05, 304: 0.05, 400: 0.04, 401: 0.07, 404: 0.07, 500: 0.04, 502: 0.04, 504: 0.04 },
    infoMsgs: ["Refreshing JWKS", "Cache hit ratio 0.87", "Rate limiter window reset"],
    warnMsgs: ["Slow query 1187ms", "Connection pool nearing capacity (18/20)"],
    errorMsgs: ["ECONNREFUSED 172.18.0.2:5432 after 3 retries"],
  },
  "clowk-vd-worker.2e5d": {
    paths: null,
    workerMsgs: ["Picked up job #4823 (priority 0)", "Completed job #4821 in 312ms", "Heartbeat ok — queue depth 87"],
    warnMsgs:   ["Queue depth 412 — exceeds high watermark"],
    errorMsgs:  ["Lost connection to redis at redis.data.voodu:6379"],
  },
}

const CLIENT_IPS = [
  "172.18.0.2", "172.18.0.3", "172.18.0.5", "172.18.0.7", "172.18.0.10",
  "10.0.4.18", "24.122.91.4", "89.30.214.7", "203.0.113.42", "198.51.100.16",
]

const LEVEL_TONE = {
  HTTP:  { color: "#60a5fa", bg: "rgba(96,165,250,0.12)",  border: "rgba(96,165,250,0.40)"  },
  INFO:  { color: "#9a82ff", bg: "rgba(124,92,255,0.12)",  border: "rgba(124,92,255,0.40)"  },
  WARN:  { color: "#fbbf24", bg: "rgba(251,191,36,0.12)",  border: "rgba(251,191,36,0.40)"  },
  ERROR: { color: "#f87171", bg: "rgba(248,113,113,0.14)", border: "rgba(248,113,113,0.45)" },
}

const POD_ACCENT_PALETTE = ["#60a5fa", "#34d399", "#fbbf24", "#22d3ee", "#a78bfa", "#f472b6", "#fb923c"]

function pick(arr)       { return arr[Math.floor(Math.random() * arr.length)] }
function pickWeighted(w) {
  const keys = Object.keys(w)
  let total = 0
  for (const k of keys) total += w[k]
  let r = Math.random() * total
  for (const k of keys) { r -= w[k]; if (r < 0) return k }
  return keys[0]
}

function makeLog(podName) {
  const profile = POD_PROFILES[podName]
  if (!profile) return null
  const id = nextId()
  const ts = new Date()
  const ip = pick(CLIENT_IPS)

  if (!profile.paths) {
    const roll = Math.random()
    let level, msg
    if (roll < 0.85)      { level = "INFO";  msg = pick(profile.workerMsgs || ["Heartbeat"]) }
    else if (roll < 0.96) { level = "WARN";  msg = pick(profile.warnMsgs || ["(no warn)"])  }
    else                  { level = "ERROR"; msg = pick(profile.errorMsgs || ["(no err)"])  }
    return { id, ts, pod: podName, ip: "127.0.0.1", level, type: "message", message: msg }
  }

  const roll = Math.random()
  if (roll < 0.91) {
    if (Math.random() < 0.5) {
      return { id, ts, pod: podName, ip, level: "HTTP", type: "request",
               method: pickWeighted(profile.methods), path: profile.paths() }
    }
    const status = parseInt(pickWeighted(profile.statusMix), 10)
    const durationMs = status >= 500
      ? 50 + Math.round(Math.random() * 250)
      : Math.max(0, Math.round(Math.random() * 60))
    return { id, ts, pod: podName, ip, level: "HTTP", type: "response", status, durationMs }
  }
  if (roll < 0.96)  return { id, ts, pod: podName, ip, level: "INFO",  type: "message", message: pick(profile.infoMsgs  || ["ok"]) }
  if (roll < 0.988) return { id, ts, pod: podName, ip, level: "WARN",  type: "message", message: pick(profile.warnMsgs  || ["warn"]) }
  return { id, ts, pod: podName, ip, level: "ERROR", type: "message", message: pick(profile.errorMsgs || ["err"]) }
}

function methodColor(m) {
  return ({
    GET: "#34d399", POST: "#60a5fa", PUT: "#fbbf24", PATCH: "#fbbf24",
    DELETE: "#f87171", HEAD: "#7a7a88", OPTIONS: "#7a7a88",
  })[m] || "var(--voodu-text-2)"
}

function statusColor(s) {
  if (s >= 500) return "#f87171"
  if (s >= 400) return "#fbbf24"
  if (s >= 300) return "#60a5fa"
  return "#34d399"
}

function podColor(name) {
  let h = 0
  for (let i = 0; i < name.length; i++) h = ((h * 31) + name.charCodeAt(i)) >>> 0
  return POD_ACCENT_PALETTE[h % POD_ACCENT_PALETTE.length]
}

function fmtTime(d) {
  const hh = String(d.getHours()).padStart(2, "0")
  const mm = String(d.getMinutes()).padStart(2, "0")
  const ss = String(d.getSeconds()).padStart(2, "0")
  const ms = String(d.getMilliseconds()).padStart(3, "0")
  return `${hh}:${mm}:${ss}.${ms}`
}

function fmtFullTime(d) {
  const y  = d.getFullYear()
  const mo = String(d.getMonth() + 1).padStart(2, "0")
  const da = String(d.getDate()).padStart(2, "0")
  return `${y}-${mo}-${da} ${fmtTime(d)}`
}

function shortPod(name) {
  if (!name) return "—"
  const dot = name.indexOf(".")
  if (dot < 0) return name
  const left = name.slice(0, dot)
  const dash = left.lastIndexOf("-")
  return (dash < 0 ? left : left.slice(dash + 1)) + name.slice(dot)
}
