import { Controller } from "@hotwired/stimulus"

// Toggle button class sets — MUST stay in sync with the same
// strings rendered in app/components/logs/page.rb (TOGGLE_INACTIVE_
// CLASSES_FOR_TAILWIND_SOURCE is the anchor that keeps the inactive
// classes in the Tailwind bundle). Active = purple-dim chip,
// Inactive = neutral surface chip.
const TOGGLE_ACTIVE_CLASSES = [
  "border-voodu-accent-line",
  "bg-voodu-accent-dim",
  "text-voodu-accent-2"
]

const TOGGLE_INACTIVE_CLASSES = [
  "border-voodu-border",
  "bg-voodu-surface",
  "text-voodu-text-2",
  "hover:bg-voodu-surface-2",
  "hover:text-voodu-text"
]

// Copy icon — two overlapping rectangles, the standard "copy" glyph.
// Inlined SVG (not a Phlex Icon component) because renderRow runs in
// JS-land per log line and we don't want to pay a Rails round-trip for
// 80 bytes of static markup. CSS sizes/strokes via .log-copy svg rules
// in theme.css; this string only carries the path data.
const COPY_ICON_SVG = `
<svg viewBox="0 0 16 16" fill="none" stroke="currentColor"
     stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"
     aria-hidden="true">
  <rect x="5" y="5" width="9" height="9" rx="1.2"></rect>
  <path d="M11 5V3a1 1 0 0 0-1-1H3a1 1 0 0 0-1 1v7a1 1 0 0 0 1 1h2"></path>
</svg>
`.trim()

// Wrap-line icon — three horizontal lines, the middle one ending in a
// return curve + left-pointing arrow tip. Reads as "this line wraps to
// the next." Toggles wrap on a SINGLE row when the global Wrap chrome
// is off (default), so the operator can briefly expand one payload
// without leaving the rest of the dense viewport behind.
const WRAP_ICON_SVG = `
<svg viewBox="0 0 16 16" fill="none" stroke="currentColor"
     stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"
     aria-hidden="true">
  <line x1="2" y1="4" x2="14" y2="4"></line>
  <path d="M2 8h10a2 2 0 0 1 0 4H7"></path>
  <polyline points="9,10 7,12 9,14"></polyline>
  <line x1="2" y1="12" x2="4" y2="12"></line>
</svg>
`.trim()

// Resumable-reconnect tuning for the live streaming mode. A
// `docker logs -f` connection can end at any time (idle proxy timeout,
// pod restart, network blip); these govern how we reopen it WITHOUT
// losing lines.
//
//   - On reconnect we ask the server for `since = lastSeenTs − MARGIN`,
//     so docker's `--since` replays the gap. The margin (+ dedup) covers
//     docker --since's 1-second granularity and cross-pod clock skew.
//   - Reopened lines overlap the last second; we dedup by RAW line.
//     Safe ONLY because timestamps=true puts a unique docker-nanosecond
//     prefix on every line, so identical bytes ⇒ the same emission.
const DEDUP_CAP          = 12_000 // raw-line keys retained for overlap dedup
const RECONNECT_BASE_MS  = 400    // backoff base; doubles per consecutive fail
const RECONNECT_MAX_MS   = 5_000
const RECONNECT_RESET_MS = 4_000  // a connection that lasted longer resets backoff
const SINCE_MARGIN_MS    = 3_000  // resume a few seconds before last-seen line

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
    // Pods snapshot at page render: [{ name, resource_name, scope }].
    // Used to expand the resource_name selection (from localStorage)
    // into a container-name allow-set the row filter checks against.
    // Snapshot can go stale between renders — new replicas of an
    // already-selected resource_name auto-stream because we match
    // by resource_name not container.
    pods:      { type: Array, default: [] },
    // localStorage key for the pod-selector filter (matches the
    // drawer's storage_key_value so both sides reach into the same
    // bucket). Empty string = no persistence, default to "all".
    podsFilterKey: { type: String, default: "" },
    // bufferCap — max log rows held in memory + rendered in the DOM.
    // Trade-off: too low and a noisy stream evicts lines the operator
    // is actively reading (the symptom we saw: 234 lines/sec × cap
    // 700 = ~3s before a line vanishes). Too high and 10k+ DOM
    // nodes in the grid grind low-end machines on follow=on
    // scroll-to-bottom.
    //
    // 10_000 gives ~45s of context at peak burst rates (~200/sec)
    // and many minutes at normal cadence. ~5MB of DOM in the worst
    // case (each row = 5 spans ≈ 500B); modern browsers handle this
    // comfortably with the display:grid layout. Operators with
    // extreme-volume pods can override per-page via
    // `data-log-stream-buffer-cap-value` on the controller root.
    bufferCap: { type: Number, default: 10000 },
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
    // Wrap defaults to FALSE — operator preference: long lines stay
    // on one line and the row scrolls horizontally if needed, so the
    // ts/level/pod columns stay aligned in dense viewports and the
    // operator can drag-select a payload without hunting across
    // wrapped fragments. Toggle Wrap on for stack-trace inspection.
    // Markup in page.rb#wrap_btn renders the INACTIVE chrome at boot
    // to match; the listTarget.classList line below keeps the CSS
    // behaviour aligned with the boolean.
    this.wrap          = false
    this.query         = ""
    this.activeLevels  = new Set(["HTTP", "INFO", "WARN", "ERROR"])
    this.userScrolled  = false
    this.streamAbort   = null
    this.mockTimer     = null
    this.rateTimer     = null
    this.lineBuffer    = "" // partial-line carry between chunks

    // Reconnect-overlap dedup: bounded FIFO of raw line strings already
    // ingested, so the second of logs that docker --since replays on a
    // reconnect doesn't render twice. warehouseSinceIso (set in
    // ingestLine) is the resume watermark for BOTH modes.
    this.seenKeys   = new Set()
    this.seenOrder  = []

    this.streaming = this.streamUrlValue && this.streamUrlValue.length > 0

    this.pool = this.streaming
      ? [this.podValue]
      : Object.keys(POD_PROFILES)

    this.updateSources()

    // ── Pod-selector filter setup ────────────────────────────────
    //
    // Build a lookup of container_name → resource_name from the
    // pods snapshot the page handed us; the drawer's selection is
    // a list of resource_names (operator-facing identity), but
    // each log line's [pod] prefix carries the container name
    // (resource_name + ".<replica_id>"). The map bridges the two
    // at filter time.
    //
    // initialResourceFilter — null means "show all" (no key in
    // localStorage); array means "show only these resource_names".
    // The window-level `logs-pods:changed` listener updates this
    // as the operator toggles checkboxes in the drawer.
    this.containerToResource = new Map()

    for (const p of this.podsValue) {
      if (p && p.name && p.resource_name) {
        this.containerToResource.set(p.name, p.resource_name)
      }
    }

    this.resourceFilter = this.loadResourceFilter()

    this.onPodsFilterChanged = this.onPodsFilterChanged.bind(this)
    window.addEventListener("logs-pods:changed", this.onPodsFilterChanged)

    // Apply the initial wrap state to the list element. The button
    // chrome in page.rb#wrap_btn already renders the active chip;
    // this line is what actually flips the CSS so long lines wrap
    // on first paint instead of after the first toggle click.
    if (this.hasListTarget) {
      this.listTarget.classList.toggle("log-wrap", this.wrap)
    }

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

    if (this.onPodsFilterChanged) {
      window.removeEventListener("logs-pods:changed", this.onPodsFilterChanged)
    }

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

    // The wrap toggle moved from the toolbar (Tailwind class swap)
    // to a chip in the PAYLOAD header (CSS `[data-active="true"]`
    // selector lights it up). We only need to flip the data-active
    // flag; no class swap, no refreshToggleButton call.
    if (this.hasWrapTarget) {
      this.wrapTarget.dataset.active = this.wrap ? "true" : "false"
    }

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
      // The sticky column-header row lives inside .log-list (so it
      // shares the column-template grid) but is never a filter target.
      // Skip it without flipping `hidden` — keep the header always
      // visible.
      if (row.classList.contains("log-header")) continue

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
    // Drop only data rows — the sticky column-header (.log-header)
    // is structural and must survive a clear so the operator's next
    // tailed line still shows up under the right column labels.
    const dataRows = this.listTarget.querySelectorAll(".log-row:not(.log-header)")

    for (const r of dataRows) r.remove()
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

  // jumpToTop — operator clicked the hover-revealed "Jump to top"
  // chip. Side-effect of scrolling away from the bottom: follow
  // mode flips off (same as any manual scroll-up), so new live lines
  // queue at the bottom without yanking the viewport back. The
  // existing onScroll handler picks this up and surfaces the
  // "Jump to live" affordance, completing the round trip.
  jumpToTop() {
    if (!this.hasViewportTarget) return

    this.viewportTarget.scrollTop = 0
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
  //
  // Two transport modes, picked by URL shape:
  //
  //   - "warehouse_stream" in URL → POLLING mode: short fetch every
  //     POLL_INTERVAL_MS, advancing a `since` watermark on each round.
  //     Server reads from the local NDJSON warehouse — zero extra
  //     `docker logs -f` connections on the controller.
  //
  //   - anything else → STREAMING mode: single long-lived fetch with
  //     a chunked reader (the legacy `/logs/stream` SSE proxy).
  //
  // The polling path is the default for /logs since the warehouse
  // landed; streaming stays as a fallback for any future endpoint
  // that needs strict realtime.

  POLL_INTERVAL_MS = 2_000  // poll cadence for warehouse mode

  async openStream() {
    this.streamAbort = new AbortController()

    if (this.isWarehouseMode()) {
      await this.runPollingLoop()
    } else {
      await this.runStreamingFetch()
    }
  }

  isWarehouseMode() {
    return this.streamUrlValue.includes("warehouse_stream")
  }

  // runPollingLoop — short fetch → process → sleep → repeat. Each
  // fetch sends a `since=<iso>` watermark; the server returns only
  // lines newer than that, and we update the watermark from the
  // newest line we just appended.
  //
  // Initial poll has no `since` — server's default lookback (5min)
  // gives a useful backfill without dumping retention into the
  // viewport.
  async runPollingLoop() {
    // Track watermark across polls. Updated by `recordLineTs` which
    // every appendLog call routes through.
    this.warehouseSinceIso = null

    while (!this.streamAbort.signal.aborted) {
      try {
        await this.runOnePoll()
      } catch (e) {
        if (e.name === "AbortError") return
        this.appendSyntheticError(`poll failed: ${e.message}`)
      }

      // Sleep with abort awareness — if disconnect fires during the
      // sleep we want to break immediately, not wait the full
      // interval.
      await this.sleepAbortable(this.POLL_INTERVAL_MS)
    }
  }

  async runOnePoll() {
    const url = this.buildPollUrl()
    const resp = await fetch(url, {
      signal:      this.streamAbort.signal,
      headers:     { "Accept": "text/plain" },
      credentials: "same-origin",
    })

    if (!resp.ok) {
      this.appendSyntheticError(`HTTP ${resp.status} ${resp.statusText}`)

      return
    }

    const text = await resp.text()

    this.consumeChunk(text)

    // Flush trailing partial line (response is fully delivered; no
    // more chunks coming, so any half-line in the buffer is complete).
    if (this.lineBuffer) {
      this.ingestLine(this.lineBuffer)
      this.lineBuffer = ""
    }
  }

  buildPollUrl() {
    const base = this.streamUrlValue

    if (!this.warehouseSinceIso) return base

    const sep = base.includes("?") ? "&" : "?"

    return `${base}${sep}since=${encodeURIComponent(this.warehouseSinceIso)}`
  }

  // sleepAbortable — Promise that resolves after `ms` OR rejects
  // with AbortError when streamAbort fires. Lets `runPollingLoop`
  // tear down promptly on disconnect/navigation instead of holding
  // the JS task alive until the next poll wakeup.
  sleepAbortable(ms) {
    return new Promise((resolve) => {
      const t = setTimeout(resolve, ms)

      this.streamAbort.signal.addEventListener("abort", () => {
        clearTimeout(t)
        resolve()
      }, { once: true })
    })
  }

  // runStreamingFetch — long-lived chunked reader WITH resumable
  // reconnect. The single biggest source of "lost lines" was: the live
  // `docker logs -f` connection ends (timeout/blip/pod restart) and the
  // old code just returned → the feed went silent forever. Now we loop:
  // when a connection ends (not via user abort) we back off and reopen,
  // asking `since=<watermark>` so docker --since replays the gap; the
  // overlap is deduped by raw line. Net: nothing lost, nothing doubled.
  async runStreamingFetch() {
    let attempt = 0

    while (!this.streamAbort.signal.aborted) {
      const startedAt = Date.now()
      const outcome   = await this.openOneStream()

      if (outcome === "abort") return

      // A connection that lived a while (was actually delivering logs)
      // resets the backoff — only rapid repeated failures escalate it.
      if (Date.now() - startedAt > RECONNECT_RESET_MS) attempt = 0

      attempt++

      const delay = Math.min(RECONNECT_BASE_MS * 2 ** (attempt - 1), RECONNECT_MAX_MS)

      await this.sleepAbortable(delay)
    }
  }

  // openOneStream runs a single fetch+reader to completion. Returns
  // "abort" (user/navigation teardown — stop looping) or "end" (stream
  // closed or errored — the caller reconnects).
  async openOneStream() {
    let resp

    try {
      resp = await fetch(this.buildStreamUrl(), {
        signal: this.streamAbort.signal,
        headers: { "Accept": "text/plain" },
        credentials: "same-origin",
      })
    } catch (e) {
      if (e.name === "AbortError") return "abort"

      return "end"
    }

    if (!resp.ok) {
      this.appendSyntheticError(`HTTP ${resp.status} ${resp.statusText} — reconnecting…`)

      return "end"
    }

    const reader  = resp.body.getReader()
    const decoder = new TextDecoder("utf-8")

    try {
      while (true) {
        const { value, done } = await reader.read()

        if (done) break
        this.consumeChunk(decoder.decode(value, { stream: true }))
      }

      if (this.lineBuffer) {
        this.ingestLine(this.lineBuffer)
        this.lineBuffer = ""
      }
    } catch (e) {
      if (e.name === "AbortError") return "abort"
    }

    return "end"
  }

  // buildStreamUrl — first connect uses the bare URL (tail=0 → fresh
  // viewport). Every RECONNECT swaps to `since=<watermark − MARGIN>` so
  // docker --since replays from just before the last line we saw.
  //
  // CRUCIAL: drop `tail` on reconnect. `docker logs --since=X --tail=0`
  // caps the replay to zero lines — so since must govern alone. With
  // tail removed the server defaults to "all lines since X", then keeps
  // following. The margin + raw-line dedup close the 1s/skew overlap.
  buildStreamUrl() {
    if (!this.warehouseSinceIso) return this.streamUrlValue

    const u = new URL(this.streamUrlValue, window.location.origin)

    u.searchParams.delete("tail")
    u.searchParams.set(
      "since",
      new Date(Date.parse(this.warehouseSinceIso) - SINCE_MARGIN_MS).toISOString(),
    )

    return u.pathname + u.search
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
    // Reconnect-overlap dedup. docker --since is 1-second granular, so a
    // resume replays the last second. timestamps=true gives every raw
    // line a unique docker-nanosecond prefix, so identical bytes ⇒ the
    // same emission ⇒ safe to drop. Bounded FIFO so a long high-rate
    // session doesn't grow the set unbounded.
    if (this.seenKeys.has(line)) return

    this.seenKeys.add(line)
    this.seenOrder.push(line)

    if (this.seenOrder.length > DEDUP_CAP) {
      this.seenKeys.delete(this.seenOrder.shift())
    }

    const parsed = parseLogLine(line, this.podValue)

    if (!parsed) return

    // Update the warehouse polling watermark from the parsed
    // timestamp. Next poll's `since=` carries this so the server
    // returns ONLY lines newer than what we've seen, no overlap
    // (= no client-side dedupe needed).
    //
    // Only meaningful in warehouse mode; in streaming mode the
    // watermark is set-but-never-read, harmless.
    if (parsed.ts && !isNaN(parsed.ts)) {
      const iso = parsed.ts.toISOString()

      if (!this.warehouseSinceIso || iso > this.warehouseSinceIso) {
        this.warehouseSinceIso = iso
      }
    }

    this.appendLog(parsed)
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
      // Pick the oldest DATA row to evict — skip the sticky column
      // header, which is always the first child but isn't part of
      // the rolling buffer.
      let dropped = this.listTarget.firstElementChild

      while (dropped && dropped.classList.contains("log-header")) {
        dropped = dropped.nextElementSibling
      }

      if (dropped) {
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
    // data-pod carries the full container name (e.g. voodu-fsw-
    // controller.67ad) so the pod-selector filter can resolve it
    // back to resource_name via the controller's containerToResource
    // map without re-parsing the line text.
    row.dataset.pod = log.pod || ""
    // Double-click anywhere on the row → toggle per-row wrap. Same
    // outcome as clicking the floating .log-wrap-single chip, but
    // for power users who don't want to aim for a 20px target. The
    // handler skips dblclicks that land on the control chips (so a
    // fast double-click on copy doesn't accidentally wrap the row).
    // Event bubbles up through the cells (row is display:contents).
    row.dataset.action = "dblclick->log-stream#toggleRowWrap"
    // Row has `display: contents` (theme.css) so it has no box —
    // border-left and tooltip can't live on the row itself. Border
    // stripe is delegated to whichever cell ends up leftmost (CSS
    // cascade in theme.css `.log-row > .log-ts, .cols-hide-ts ...
    // > .log-level, ...`). The pod-accent color travels via the
    // `--row-accent` custom property set on the row AND on every
    // cell below. Custom-property inheritance through `display:
    // contents` is spec-compliant but had a known WebKit bug in
    // Safari < 16.4 — pushing the value onto each cell directly is
    // belt-and-suspenders so the colored stripe survives even when
    // TIME / LVL / POD are hidden via the column-visibility popover
    // and the body cell ends up the leftmost-rendered one.
    row.style.setProperty("--row-accent", pc)

    const ts = document.createElement("span")

    ts.className = "log-ts"
    ts.textContent = fmtTime(log.ts)
    ts.style.setProperty("--row-accent", pc)
    row.appendChild(ts)

    const lvl = document.createElement("span")

    lvl.className = "log-level"
    lvl.textContent = log.level
    lvl.style.color = tone.color
    lvl.style.background = tone.bg
    lvl.style.border = `1px solid ${tone.border}`
    lvl.style.setProperty("--row-accent", pc)
    row.appendChild(lvl)

    const pod = document.createElement("span")

    pod.className = "log-pod"
    pod.textContent = sp
    pod.style.color = pc
    pod.style.setProperty("--row-accent", pc)
    row.appendChild(pod)

    // IP column intentionally NOT rendered — operator deferred the
    // column until a real use case shows up. `log.ip` is still parsed,
    // stays in `row.dataset.search` (so the filter input can still
    // match IPs even though they're not visible), and the body's
    // tooltip carries it for one-off inspection on hover.

    const body = document.createElement("span")

    body.className = "log-body"
    body.style.setProperty("--row-accent", pc)

    if (log.type === "request") {
      const method = document.createElement("span")

      method.style.color = methodColor(log.method)
      method.style.fontWeight = "600"
      method.textContent = log.method
      body.appendChild(method)
      body.appendChild(document.createTextNode(" "))
      const path = document.createElement("span")

      path.style.color = "var(--voodu-log-payload)"
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
      // Message text. Dark keeps the level tint (`--log-tone`); light
      // forces a neutral near-black (`--voodu-log-payload`, see
      // theme.css) so a wall of logs reads cleanly on white — the level
      // is already conveyed by the LVL chip.
      const msg = document.createElement("span")

      msg.className = "log-msg"
      msg.style.setProperty("--log-tone", tone.color)
      msg.textContent = log.message
      body.appendChild(msg)
    }

    // Per-row wrap toggle — sits to the LEFT of copy. Default state
    // is inactive; clicking adds `.log-row-wrap` to the row, which
    // a CSS override (theme.css) flips this single body to
    // `white-space: pre-wrap` without disturbing other rows. Stays
    // visible (data-active="true") when wrap is on for the row, so
    // the operator can disable it without re-hovering precisely.
    const wrapBtn = document.createElement("button")

    wrapBtn.type = "button"
    wrapBtn.className = "log-wrap-single"
    wrapBtn.title = "Toggle wrap for this line"
    wrapBtn.setAttribute("aria-label", "Toggle wrap for this log line")
    wrapBtn.dataset.action = "click->log-stream#toggleRowWrap"
    wrapBtn.innerHTML = WRAP_ICON_SVG
    body.appendChild(wrapBtn)

    // Floating copy affordance — top-right of the body cell, revealed
    // on row hover (CSS-driven). Anchored to `.log-body` because the
    // row has `display: contents` (no box, can't be a positioning
    // context). Body IS the rightmost grid column, so top-right of
    // body = top-right of the row visually.
    //
    // Clicking calls `copyRow` below which reads body.textContent and
    // writes the raw payload (no timestamp, no level, no pod, no IP)
    // to the clipboard — matches operator's mental model: "the line
    // already has its own timestamp inside the JSON, just give me that."
    const copy = document.createElement("button")

    copy.type = "button"
    copy.className = "log-copy"
    copy.title = "Copy payload"
    copy.setAttribute("aria-label", "Copy log payload to clipboard")
    copy.dataset.action = "click->log-stream#copyRow"
    copy.innerHTML = COPY_ICON_SVG
    body.appendChild(copy)

    row.appendChild(body)

    return row
  }

  // copyRow — clipboard write of the body's textContent only. Strips
  // every metadata column (ts/level/pod/ip) because the payload itself
  // already carries a `"time":...` field in 99% of cases (structured
  // JSON from our agents) and the columns are display chrome, not
  // information the operator wants in their paste buffer.
  //
  // On success, the button flashes green for 1.2s via `data-copied`
  // — visual feedback the click landed without nagging a toast.
  // On clipboard-API failure (rare: insecure context, denied
  // permission), falls back to selecting the body text so the
  // operator can Ctrl+C manually.
  async copyRow(event) {
    event.preventDefault()
    event.stopPropagation()
    const btn = event.currentTarget
    const row = btn.closest(".log-row")

    if (!row) return
    const body = row.querySelector(".log-body")

    if (!body) return

    const text = this.extractBodyText(body)

    try {
      await navigator.clipboard.writeText(text)
      btn.dataset.copied = "true"
      setTimeout(() => { delete btn.dataset.copied }, 1200)
    } catch (e) {
      // Manual-select fallback for browsers without clipboard API
      // access (file://, insecure context, denied permission).
      const range = document.createRange()

      range.selectNodeContents(body)
      const sel = window.getSelection()

      sel.removeAllRanges()
      sel.addRange(range)
    }
  }

  // copyAll — bulk version of copyRow. Walks every visible row in the
  // buffer (respects level pills + filter input via `!hidden`),
  // extracts each body's payload, joins with newlines, single clipboard
  // write. Independent of scroll position — operator doesn't have to
  // drag-select page-by-page to grab a long viewport.
  //
  // "Visible" here means `row.hidden === false` after the level/search
  // filters resolved — same set the viewport currently shows. Hidden
  // rows skip silently.
  //
  // Feedback: the toolbar button's label flips to "Copied N" for 1.2s
  // then back to "Copy all". Same idiom as per-row but with a count so
  // the operator knows exactly how much landed in their buffer.
  async copyAll(event) {
    event.preventDefault()
    const btn = event.currentTarget

    if (!this.hasListTarget) return

    const lines = []

    for (const row of this.listTarget.children) {
      if (row.hidden) continue
      // Schema header has no payload to copy — skip it. Its
      // .log-body cell only carries the literal "PAYLOAD" label.
      if (row.classList.contains("log-header")) continue
      const body = row.querySelector(".log-body")

      if (!body) continue
      lines.push(this.extractBodyText(body))
    }

    const text = lines.join("\n")
    const label = btn.querySelector("[data-copy-all-label]")
    const originalLabel = label ? label.textContent : null

    try {
      await navigator.clipboard.writeText(text)
      if (label) label.textContent = `Copied ${lines.length}`
      btn.dataset.copied = "true"
      setTimeout(() => {
        if (label && originalLabel) label.textContent = originalLabel
        delete btn.dataset.copied
      }, 1200)
    } catch (e) {
      // Clipboard API unavailable — fall back to selecting the entire
      // list element so the operator can Ctrl+C. Less polished but
      // never strands the action.
      const range = document.createRange()

      range.selectNodeContents(this.listTarget)
      const sel = window.getSelection()

      sel.removeAllRanges()
      sel.addRange(range)
    }
  }

  // extractBodyText — pulls the payload string out of a `.log-body`
  // span, ignoring the floating control buttons (copy, wrap toggle)
  // that live inside it as siblings. `body.textContent` would include
  // any text inside those buttons (today both are pure SVG so the
  // result is the same, but tomorrow someone might add a text label
  // — better to be explicit now than chase a copy-includes-the-word-
  // "Copy" bug later).
  extractBodyText(body) {
    let out = ""

    for (const node of body.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        out += node.nodeValue
      } else if (node.nodeType === Node.ELEMENT_NODE
                 && !node.classList.contains("log-copy")
                 && !node.classList.contains("log-wrap-single")) {
        out += node.textContent || ""
      }
    }

    return out
  }

  // toggleRowWrap — flips `.log-row-wrap` on a single row so its
  // body becomes pre-wrap / break-all while every other row stays in
  // the current global mode. Lets the operator briefly expand ONE
  // stack-trace / multi-KB JSON without losing the column rhythm of
  // the surrounding dense viewport.
  //
  // Two entry points feed this single handler:
  //   1. Click on the floating `.log-wrap-single` chip
  //      (`click->log-stream#toggleRowWrap` set in renderRow on the
  //      button).
  //   2. Double-click anywhere on the row
  //      (`dblclick->log-stream#toggleRowWrap` on the row itself).
  //
  // The two paths differ only in how the event arrives — both end up
  // toggling the same class. We disambiguate when `event.target`
  // resolves: if the dblclick landed on one of the control chips,
  // skip (otherwise a fast double-click on Copy would also wrap the
  // row, which is jarring).
  //
  // `data-active` is mirrored onto the chip so:
  //   - CSS can keep the chip visible when wrap is on (without it
  //     the chip would fade out as soon as the cursor leaves the row,
  //     stranding the operator from un-wrapping).
  //   - The active state reads visually (accent palette) so the
  //     operator sees which rows they've expanded.
  toggleRowWrap(event) {
    // Skip dblclicks that originated on a control chip — those are
    // already wired to their own click handlers and shouldn't double-
    // fire as wrap toggles.
    if (event.type === "dblclick" && event.target.closest(".log-copy, .log-wrap-single")) {
      return
    }

    event.preventDefault()
    event.stopPropagation()

    // currentTarget is the chip for the click path and the row for
    // the dblclick path — handle both.
    const node = event.currentTarget
    const row = node.classList.contains("log-row") ? node : node.closest(".log-row")

    if (!row) return

    const wrapped = row.classList.toggle("log-row-wrap")

    // Find the chip on this row to mirror data-active. There's
    // exactly one per row (created in renderRow).
    const chip = row.querySelector(".log-wrap-single")

    if (chip) chip.dataset.active = wrapped ? "true" : "false"

    // Double-clicking text inside `.log-body` selects a word as a
    // side-effect of the browser's default. Toggling wrap with a
    // leftover word-selection looks broken (random highlight, no
    // copy intent). Clear it so the toggle feels clean.
    if (event.type === "dblclick") {
      const sel = window.getSelection()

      if (sel && sel.removeAllRanges) sel.removeAllRanges()
    }
  }

  rowMatches(row) {
    if (!this.activeLevels.has(row.dataset.level)) return false
    if (this.query && !row.dataset.search.includes(this.query)) return false
    if (!this.podMatchesResourceFilter(row.dataset.pod || row.dataset.container)) return false

    return true
  }

  // podMatchesResourceFilter — gates a row by the pod selector.
  // Null filter (`resourceFilter`) means default = show everything.
  // Empty array means operator deliberately hid all. Non-empty
  // array means keep only rows whose container's resource_name is
  // in the allow-set.
  //
  // Unknown containers (not in the pods snapshot we got at render
  // — e.g. a brand-new pod spawned mid-session) get shown by
  // default so the operator isn't surprised by "where did my log
  // go" when scale events run. They flip into the filter once
  // they're in a re-rendered snapshot.
  podMatchesResourceFilter(containerName) {
    if (this.resourceFilter === null) return true
    if (!containerName) return true
    const resource = this.containerToResource.get(containerName)

    if (!resource) return true

    return this.resourceFilter.has(resource)
  }

  // loadResourceFilter — reads the persisted resource_name list out
  // of localStorage and returns either:
  //   null        — no saved selection, show everything
  //   Set<string> — saved selection (possibly empty = hide all)
  loadResourceFilter() {
    if (!this.podsFilterKeyValue) return null

    try {
      const raw = localStorage.getItem(this.podsFilterKeyValue)

      if (raw === null) return null
      const parsed = JSON.parse(raw)

      return Array.isArray(parsed) ? new Set(parsed) : null
    } catch (_e) {
      return null
    }
  }

  // onPodsFilterChanged — window event hook. The drawer dispatches
  // this whenever its checkboxes change; we update our Set + re-
  // apply the filter to the live tail (existing rows AND future
  // ingest).
  onPodsFilterChanged(event) {
    const resources = event.detail && event.detail.resources

    if (resources === null || resources === undefined) {
      this.resourceFilter = null
    } else {
      this.resourceFilter = new Set(Array.isArray(resources) ? resources : [])
    }

    this.applyFilter()
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

    if (active) {
      btn.classList.remove(...TOGGLE_INACTIVE_CLASSES)
      btn.classList.add(...TOGGLE_ACTIVE_CLASSES)
    } else {
      btn.classList.remove(...TOGGLE_ACTIVE_CLASSES)
      btn.classList.add(...TOGGLE_INACTIVE_CLASSES)
    }
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

const ISO_RE        = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)\s+(.*)$/
const HTTP_REQ_RE   = /^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\S+)/
const HTTP_RES_RE   = /(\d{3})\s+(\d+)ms\b/
const IPV4_RE       = /\b(\d{1,3}(?:\.\d{1,3}){3})\b/
// Multi-source line prefix: handleLogsMulti tags every line with
// the pod that produced it. Stripped here so the row renders with
// the right pod color + the body stays readable.
const POD_PREFIX_RE = /^\[([^\]]+)\] (.*)$/

// ANSI_RE / stripAnsi — drop the SGR/CSI colour escapes a TTY app (FreeSWITCH's
// SIP trace, a colourised logger) prints to its console: ESC `[`, params,
// intermediates, a final byte. The invisible ESC renders to nothing in the
// browser and leaves the litter (`[m`, `[32m`) inline. The warehouse ingestion
// path already scrubs these server-side (LogTail::Parser); this covers the LIVE
// docker proxy (stream / stream_all) that bypasses the warehouse, so EVERY line
// the viewer shows is clean regardless of transport. Stripped BEFORE the pod /
// ISO / level heuristics so an escape never blocks a match.
// eslint-disable-next-line no-control-regex
const ANSI_RE = /\x1b\[[0-9;?]*[ -/]*[@-~]/g

function stripAnsi(s) {
  if (typeof s !== "string") return s

  return s.replace(ANSI_RE, "")
}

function parseLogLine(raw, fallbackPod) {
  let line = stripAnsi(raw)
  let ts = new Date()
  let pod = fallbackPod

  // Strip `[pod-name] ` first — when present that's the canonical
  // attribution from the multi-source stream and trumps the URL pod.
  const prefixMatch = line.match(POD_PREFIX_RE)

  if (prefixMatch) {
    pod  = prefixMatch[1]
    line = prefixMatch[2]
  }

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
    return { id: nextId(), ts, pod, ip, level: "HTTP", type: "request",
             method: reqMatch[1], path: reqMatch[2] }
  }

  // HTTP response shape (rare in raw container logs but our CLI uses it)
  const resMatch = line.match(HTTP_RES_RE)

  if (resMatch) {
    return { id: nextId(), ts, pod, ip, level: "HTTP", type: "response",
             status: parseInt(resMatch[1], 10), durationMs: parseInt(resMatch[2], 10) }
  }

  let level = "INFO"

  if (/\b(ERROR|FATAL|panic)\b/i.test(line)) level = "ERROR"
  else if (/\b(WARN|WARNING)\b/i.test(line)) level = "WARN"

  return { id: nextId(), ts, pod, ip, level, type: "message", message: line }
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

// tone — a level chip's {color, bg, border} built from a theme var so
// it tracks the active theme. Dark uses the bright base tones; light
// resolves the darkened variants (see theme.css), so the chips read with
// proper contrast on white. color-mix keeps the translucent bg/border
// tints theme-aware too. var() in an inline style re-resolves live on
// toggle, so even already-rendered rows recolor when the theme flips.
function tone(v, bgPct = 12, borderPct = 40) {
  return {
    color:  `var(${v})`,
    bg:     `color-mix(in srgb, var(${v}) ${bgPct}%, transparent)`,
    border: `color-mix(in srgb, var(${v}) ${borderPct}%, transparent)`,
  }
}

const LEVEL_TONE = {
  HTTP:  tone("--voodu-blue"),
  INFO:  tone("--voodu-accent-2"),
  WARN:  tone("--voodu-amber"),
  ERROR: tone("--voodu-red", 14, 45),
}

const POD_ACCENT_PALETTE = [
  "var(--voodu-blue)", "var(--voodu-green)", "var(--voodu-amber)", "var(--voodu-cyan)",
  "var(--voodu-violet)", "var(--voodu-pink)", "var(--voodu-orange)",
]

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
    GET: "var(--voodu-green)", POST: "var(--voodu-blue)",
    PUT: "var(--voodu-amber)", PATCH: "var(--voodu-amber)",
    DELETE: "var(--voodu-red)", HEAD: "var(--voodu-muted)", OPTIONS: "var(--voodu-muted)",
  })[m] || "var(--voodu-text-2)"
}

function statusColor(s) {
  if (s >= 500) return "var(--voodu-red)"
  if (s >= 400) return "var(--voodu-amber)"
  if (s >= 300) return "var(--voodu-blue)"

  return "var(--voodu-green)"
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
