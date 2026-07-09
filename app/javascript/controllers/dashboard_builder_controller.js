import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// DashboardBuilderController — drives Views::MetricDashboards::Form.
//
// Holds the in-memory list of panels (source + metric pairs) the
// operator assembles, renders them as removable chips, and serializes
// the list to JSON into the hidden `metric_dashboard[panels]` field on
// every change so a plain (data-turbo:false) form submit ships it.
//
// Source + metric are picked from two DS dropdowns (the `dropdown`
// controller owns open/close; this controller owns the SELECTION).
// Picking a source repopulates the metric menu from the catalog —
// a { kind => [spec, …] } map rendered server-side from
// MetricsPageData.metric_catalog_for — so the offered metrics always
// match the chosen source's workload kind.

export default class extends Controller {
  static targets = ["sourceLabel", "metricLabel", "metricMenu", "metricQuery", "metricQueryRow", "metricTimelineRow", "metricShowChart", "shapeChip", "shapeSkeleton", "metricSwatch", "list", "empty", "hidden",
                    "logSourceLabel", "logLabel", "logQuery", "logSwatch", "logShowChart",
                    "tableBlock", "tableBlockTitle", "tableSourceViewLabel", "tableSourceMenu", "tableLabel", "tableQuery", "tableSwatch",
                    "hep3Shapes", "hep3ShapeChip", "hep3PercentRow", "hep3Percent",
                    "httpBlock", "httpBlockTitle", "httpUrl", "httpMethod", "httpMethodLabel", "httpBody",
                    "httpInterval", "httpMapping", "httpChartChip", "httpLabel", "httpSwatch",
                    "httpTab", "httpTabPanel", "httpHeadersRows", "httpHeaderTemplate", "httpHeaderKey", "httpHeaderValue",
                    "httpTestStatus", "httpTestResult", "httpTestRaw", "httpTestParsed",
                    "idleStep", "typeStep", "metricBlock", "logBlock",
                    "metricBlockTitle", "logBlockTitle", "backLink",
                    "previewPane", "panelPreview", "previewRefresh"]
  static values  = {
    catalog:          Object,
    logsSourceViews:  Array,
    hep3SourceViews:  Array,
    logsFields:       Array,
    hep3Fields:       Array,
    hep3Hints:        Object,
    httpTestUrl:      String,
    previewUrl:       String,
    defaultServer:    String,
    servers:          Object,
    panels:           Array
  }

  connect() {
    this.panels = Array.isArray(this.panelsValue) ? this.panelsValue.map((p) => ({ ...p })) : []
    // server_id — the server a fresh host panel binds to before a source is
    // picked. Every source option overrides it with its own server_id (M2).
    this.currentSource = { scope_kind: "host", label: "host", server_id: this.defaultServerValue }
    this.currentMetric = null
    this.currentMetricColor = null
    this.currentChartType = "area"
    // The server-rendered default source label ("Host (system)" / "srv · Host
    // (system)"), captured so resetMetricBlock can restore it when a fresh
    // Metric panel drops a carried-over pod selection back to host.
    this.defaultSourceLabel = this.hasSourceLabelTarget ? this.sourceLabelTarget.textContent.trim() : "Host (system)"

    // isQueryMeasure — the Metric block's "Query" measure is selected: the panel
    // is a LogQuery (count) routed to a log/table shape, NOT a warehouse metric.
    // Gates the render chips (Number/Line/Area/Bar/Table, no gauges), reveals the
    // query editor, and disables multi-pod (a query reads one pod).
    this.isQueryMeasure = false

    this.currentLogSource = null
    this.currentLogColor = this.defaultLogColor()

    this.currentTableSourceView = null
    this.tableKind = "table"
    this.currentHep3Shape = "table"
    this.currentTableColor = this.defaultTableColor()

    this.currentHttpChartType = "table"
    this.currentHttpColor = "var(--voodu-cyan)"

    this.addType = "metric"
    // idle → nothing selected (the resting/open state); type → the Add
    // panel chooser; config → a type's config block (new or editing).
    this.wizardStep = "idle"
    this.editingIndex = null
    this.selectedIndex = null

    this.buildMeasureIndex()
    this.populateMetrics()
    this.highlightLogColor()
    this.highlightTableColor()
    this.syncWizard()
    this.render()
    this.sync()
    this.initSortable()

    // Live auto-save: typing in the query updates the panel as you go (no
    // explicit Update). Wired imperatively so the shared query-editor's own
    // input action (syntax highlight) stays intact.
    if (this.hasLogQueryTarget) {
      this.onLogQueryInput = () => this.autoCommit()
      this.logQueryTarget.addEventListener("input", this.onLogQueryInput)
    }

    if (this.hasTableQueryTarget) {
      this.onTableQueryInput = () => this.autoCommit()
      this.tableQueryTarget.addEventListener("input", this.onTableQueryInput)
    }

    if (this.hasMetricQueryTarget) {
      this.onMetricQueryInput = () => this.autoCommit()
      this.metricQueryTarget.addEventListener("input", this.onMetricQueryInput)
    }

    // The DS color picker lives in a popover that portals OUT of this form to
    // the modal dialog, so its `color-picker:change` doesn't bubble through
    // here — listen on the document instead.
    this.onCustomColor = this.onCustomColor.bind(this)
    document.addEventListener("color-picker:change", this.onCustomColor)
  }

  disconnect() {
    if (this.sortable) this.sortable.destroy()

    clearTimeout(this.previewTimer)

    if (this.hasLogQueryTarget && this.onLogQueryInput) {
      this.logQueryTarget.removeEventListener("input", this.onLogQueryInput)
    }

    if (this.hasTableQueryTarget && this.onTableQueryInput) {
      this.tableQueryTarget.removeEventListener("input", this.onTableQueryInput)
    }

    if (this.hasMetricQueryTarget && this.onMetricQueryInput) {
      this.metricQueryTarget.removeEventListener("input", this.onMetricQueryInput)
    }

    document.removeEventListener("color-picker:change", this.onCustomColor)
  }

  // ── add wizard (step 1 type cards → step 2 config block) ──────────

  // chooseType — a type card was clicked: remember the type and advance to the
  // config step (its block).
  chooseType(event) {
    const type = event.currentTarget.dataset.addType

    if (!type) return

    this.addType = type
    this.wizardStep = "config"

    // A freshly-added panel starts from clean defaults — never inheriting the
    // previous panel's source / measure / query state — so every type
    // eager-commits a valid default row (and a carried-over Query mode can't
    // block the Metric commit).
    if (type === "metric") this.resetMetricBlock()
    if (type === "http") this.resetHttpBlock()

    // Table (logs) + HEP3 share one block; activate the kind's options + the
    // first source·view so autoCommit can create the panel immediately.
    if (type === "table" || type === "hep3") this.activateTableKind(type)

    this.syncWizard()
    // Every type now has valid defaults (host · first metric / a HEP3 reader /
    // a blank HTTP request) → eager-commit so the new row appears the instant
    // the type is chosen, then the operator just refines it.
    this.autoCommit()
  }

  // resetMetricBlock — restore the Metric block to its clean defaults (host ·
  // first metric, Area render, not Query mode) so a freshly-added Metric panel
  // always eager-commits a valid default row instead of inheriting the previous
  // panel's pod / measure / query state.
  resetMetricBlock() {
    this.currentSource = { scope_kind: "host", label: "host", server_id: this.defaultServerValue }
    this.selectedPods = []
    this.currentChartType = "area"
    this.currentMetric = null
    this.isQueryMeasure = false

    if (this.hasMetricQueryRowTarget) this.metricQueryRowTarget.hidden = true
    if (this.hasMetricQueryTarget) this.metricQueryTarget.value = ""
    if (this.hasMetricTimelineRowTarget) this.metricTimelineRowTarget.hidden = true
    if (this.hasMetricShowChartTarget) this.metricShowChartTarget.checked = true
    if (this.hasSourceLabelTarget) this.sourceLabelTarget.textContent = this.defaultSourceLabel

    this.markSelectedSources()
    this.populateMetrics()
  }

  // resetHttpBlock — clear the HTTP block back to a blank request (no URL /
  // headers / body / mapping, GET, Table render) so a freshly-added HTTP panel
  // starts empty instead of inheriting the previous request's config.
  resetHttpBlock() {
    this.loadHttpPanel({
      url: "", label: "", interval: "auto", method: "GET",
      headers: {}, body: "", mapping: {}, chart_type: "table", color: "var(--voodu-cyan)"
    })
  }

  // backToTypes — the config block's secondary link. While ADDING it reads
  // "Change type" → back to the type chooser. While EDITING it reads
  // "Cancel" → back to the idle placeholder (the edit is dropped, since
  // indices would go stale anyway). Capture the mode before cancelEdit
  // clears editingIndex.
  backToTypes() {
    const editing = this.editingIndex != null

    this.cancelEdit()
    this.wizardStep = editing ? "idle" : "type"
    this.syncWizard()
    this.render()
  }

  // newPanel — the sidebar "Add panel" button: deselect, open the type
  // chooser. The next Add appends a fresh panel.
  newPanel() {
    this.cancelEdit()
    this.wizardStep = "type"
    this.syncWizard()
    this.render()
  }

  // syncWizard — toggle the four detail-pane states (idle / type chooser /
  // metric config / log config) and relabel the config chrome for new vs
  // editing (block title + the Change-type/Cancel link).
  syncWizard() {
    const step = this.wizardStep
    const config = step === "config"
    const isLog = this.addType === "log"
    const isTable = this.addType === "table" || this.addType === "hep3"
    const isHttp = this.addType === "http"
    const editing = this.editingIndex != null

    if (this.hasIdleStepTarget) this.idleStepTarget.hidden = step !== "idle"
    if (this.hasTypeStepTarget) this.typeStepTarget.hidden = step !== "type"
    if (this.hasMetricBlockTarget) this.metricBlockTarget.hidden = !(config && this.addType === "metric")
    if (this.hasLogBlockTarget) this.logBlockTarget.hidden = !(config && isLog)
    if (this.hasTableBlockTarget) this.tableBlockTarget.hidden = !(config && isTable)
    if (this.hasHttpBlockTarget) this.httpBlockTarget.hidden = !(config && isHttp)

    // The preview lives below the config — only meaningful while configuring.
    if (this.hasPreviewPaneTarget) this.previewPaneTarget.hidden = !config

    if (this.hasMetricBlockTitleTarget) this.metricBlockTitleTarget.textContent = editing ? "Edit metric panel" : "New metric panel"
    if (this.hasLogBlockTitleTarget) this.logBlockTitleTarget.textContent = editing ? "Edit log count" : "New log count"
    if (this.hasTableBlockTitleTarget) this.tableBlockTitleTarget.textContent = editing ? "Edit table panel" : "New table panel"
    if (this.hasHttpBlockTitleTarget) this.httpBlockTitleTarget.textContent = editing ? "Edit HTTP panel" : "New HTTP panel"
    this.backLinkTargets.forEach((el) => { el.textContent = editing ? "Cancel" : "Change type" })
  }

  // ── panel preview ──────────────────────────────────────────────────────────

  // refreshPreview — POST the in-progress panel to /metrics/previews/panel and
  // swap the rendered card into the preview pane. Manual (a button) so an HTTP
  // panel's external request only fires on demand; a panel that can't build yet
  // renders a placeholder server-side.
  refreshPreview() {
    if (!this.hasPanelPreviewTarget || !this.previewUrlValue) return

    const panel = this.currentPanel()

    this.setPreviewBusy(true)

    fetch(this.previewUrlValue, {
      method: "POST",
      headers: {"X-CSRF-Token": this.csrfToken(), "Content-Type": "application/x-www-form-urlencoded"},
      body: `panel=${encodeURIComponent(JSON.stringify(panel || {}))}`
    })
      .then((r) => r.text())
      .then((html) => { this.panelPreviewTarget.innerHTML = html })
      .catch(() => {})
      .finally(() => this.setPreviewBusy(false))
  }

  // currentPanel — what the preview renders: the row autoCommit keeps current
  // while editing, else a best-effort build of the in-progress config.
  currentPanel() {
    if (this.editingIndex != null && this.panels[this.editingIndex]) return this.panels[this.editingIndex]

    return this.panelForType()
  }

  setPreviewBusy(on) {
    if (!this.hasPreviewRefreshTarget) return

    this.previewRefreshTarget.disabled = on
    this.previewRefreshTarget.classList.toggle("opacity-50", on)
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  // autoPreview — re-render the preview automatically on any config change
  // (chart type, measure, color, server, query…) so switching a shape updates
  // the view live, not just on the refresh button. Debounced so query typing
  // doesn't hammer the endpoint. Skipped for HTTP panels — those hit an external
  // API, so they stay manual (the refresh button is their only trigger). No-op
  // while the preview pane is hidden (no panel being configured yet).
  autoPreview() {
    if (!this.hasPreviewPaneTarget || this.previewPaneTarget.hidden) return

    const panel = this.currentPanel()

    if (panel && panel.source === "http") return

    clearTimeout(this.previewTimer)
    this.previewTimer = setTimeout(() => this.refreshPreview(), 250)
  }

  // initSortable — drag-reorder the panel chips. The grip handle
  // (data-role="panel-handle") is the only drag affordance so the remove
  // button + label stay clickable. onEnd mirrors the DOM move back into
  // the panels array, then re-renders to refresh each chip's index (the
  // remove button reads it) and re-syncs the hidden field.
  initSortable() {
    if (!this.hasListTarget) return

    this.sortable = new Sortable(this.listTarget, {
      animation:     150,
      handle:        "[data-role='panel-handle']",
      ghostClass:    "opacity-30",
      chosenClass:   "ring-1",
      forceFallback: true,
      fallbackClass: "shadow-lg",
      onEnd:         (e) => this.reorder(e.oldIndex, e.newIndex)
    })
  }

  reorder(from, to) {
    if (from === to || from == null || to == null) return

    const [moved] = this.panels.splice(from, 1)

    this.panels.splice(to, 0, moved)

    this.cancelEdit()
    this.render()
    this.sync()
  }

  // cancelEdit — drop edit-in-place mode + selection (indices shift on
  // remove/reorder, so a pending target would be stale). Resets Add labels.
  cancelEdit() {
    this.editingIndex = null
    this.selectedIndex = null
  }

  // optionLabel — a source row's LABEL text only. The row also holds a trailing
  // check span (opacity-toggled for the multi-select indicator); its ✓ glyph is
  // still in textContent, so read the first (label) span to keep it out of the
  // trigger. Falls back to the whole text for rows without a label span.
  optionLabel(el) {
    return (el.querySelector("span")?.textContent || el.textContent || "").trim()
  }

  // selectSource — operator picked a source row. Update the trigger
  // label + remember the identity, then rebuild the metric menu for
  // this source's kind.
  selectSource(event) {
    const source = this.parse(event.currentTarget.dataset.source)

    if (!source) return

    // Multi-series: a pod OR the host toggles in/out of the selection (keep the
    // dropdown open) so a chart can mix Host + pods; only Query is single-select.
    if (this.multiEligible() && (source.scope_kind === "pod" || source.scope_kind === "host")) {
      this.togglePod(source)

      return
    }

    this.currentSource = source
    this.selectedPods = []
    this.markSelectedSources()
    if (this.hasSourceLabelTarget) this.sourceLabelTarget.textContent = this.optionLabel(event.currentTarget)

    this.closeSourceDropdown(event.currentTarget)
    this.populateMetrics()
    this.autoCommit()
  }

  // ── Multi-pod selection (Line multi-series) ──────────────────────────────

  // multiEligible — multi-pod selection is enabled by default for EVERY render
  // (the operator can pick N pods on any chart type). Only a Query is inherently
  // one pod (logs are per-pod), so Query mode stays single-select. What the read
  // path DRAWS with the extra pods is its own concern — Line/Area render one mark
  // per pod; the rest render the first pod (the selection is still preserved).
  multiEligible() {
    return !this.isQueryMeasure
  }

  // isMultiChartType — the chart types that support a multi-pod series list.
  isMultiChartType(t) {
    return t === "line" || t === "area"
  }

  // podKey — a stable key for a series member. The host has no scope/name (one
  // node per server), so it keys off its server alone; a pod keys off scope+name.
  podKey(s) {
    return s.scope_kind === "host" ? `host/${s.server_id}` : `${s.server_id}/${s.scope}/${s.name}`
  }

  togglePod(source) {
    this.selectedPods ||= []

    const key = this.podKey(source)
    const at  = this.selectedPods.findIndex((p) => this.podKey(p) === key)

    if (at >= 0) {
      this.selectedPods.splice(at, 1)
    } else if (this.selectedPods.length < this.maxSeries()) {
      this.selectedPods.push(source)
    } else {
      return
    }

    // Metric enumeration + the panel's scope anchor ride the first pod.
    this.currentSource = this.selectedPods[0] || source
    this.updateSourceLabel()
    this.markSelectedSources()
    this.populateMetrics()
    this.autoCommit()
  }

  maxSeries() {
    return 5
  }

  updateSourceLabel() {
    if (!this.hasSourceLabelTarget) return

    const sel = this.selectedPods || []
    const n = sel.length

    if (n >= 2) {
      // "series" once the host joins (it isn't a pod); "pods" for a pure-pod set.
      this.sourceLabelTarget.textContent = `${n} ${sel.some((p) => p.scope_kind === "host") ? "series" : "pods"}`

      return
    }

    // A single source shows "<server> · <base>" (host / pod), always server-prefixed.
    const one = sel[0] || this.currentSource

    if (one) {
      const base = one.scope_kind === "host" ? "Host (system)" : (one.name || one.label || "Host (system)")

      this.sourceLabelTarget.textContent = this.sourceTriggerLabel(one.server_id, base)

      return
    }

    this.sourceLabelTarget.textContent = "Host (system)"
  }

  // markSelectedSources — toggle the accent/check on each source row (pods AND
  // the host) so the operator sees which sources are in the multi-series selection.
  markSelectedSources() {
    const keys = new Set((this.selectedPods || []).map((p) => this.podKey(p)))

    this.element.querySelectorAll("[data-dropdown-target='option'][data-source]").forEach((el) => {
      const src = this.parse(el.dataset.source)

      el.dataset.selected = src && (src.scope_kind === "pod" || src.scope_kind === "host") && keys.has(this.podKey(src)) ? "true" : "false"
    })
  }

  closeSourceDropdown(el) {
    const root = el.closest("[data-controller~='dropdown']")

    if (!root) return

    this.application.getControllerForElementAndIdentifier(root, "dropdown")?.close?.()
  }

  selectMetric(event) {
    const spec = this.parse(event.currentTarget.dataset.metric)

    if (!spec) return

    // Query is source-independent; a warehouse measure resolves to the concrete
    // spec for the CURRENT source's kind (host vs pod Memory differ), so the
    // panel captures the right metric key/scale — or an empty-reading fallback
    // when the source doesn't emit it (the operator owns that mismatch).
    const resolved = spec.query ? spec : (this.resolveMeasure(spec.label, this.currentSource) || spec)

    this.currentMetric = resolved
    if (this.hasMetricLabelTarget) this.metricLabelTarget.textContent = resolved.label

    // "Query" flips the block into log-query mode (render editor + gated shapes,
    // no gauges); any real metric flips it back. Toggle BEFORE gating so
    // syncTypeAvailability reads the right mode.
    this.applyQueryMode(!!spec.query)

    // A gauge render carries no meaning for a count — snap to a line if we land
    // in Query mode still holding a gauge shape.
    if (this.isQueryMeasure && this.isGaugeType(this.currentChartType)) this.currentChartType = "line"

    // Reset to this metric's canonical color (the operator can re-override
    // via the swatches); recolor the shape previews to match.
    this.currentMetricColor = resolved.color
    this.highlightMetricColor()
    this.recolorShapes()

    this.updateSourceLabel()
    this.markSelectedSources()
    this.syncTypeAvailability()
    this.autoCommit()
  }

  // selectMetricColor — override the metric panel's chart color.
  selectMetricColor(event) {
    const color = event.currentTarget.dataset.color

    if (!color) return

    this.currentMetricColor = color
    this.highlightMetricColor()
    this.recolorShapes()
    this.autoCommit()
  }

  // onCustomColor — the DS color picker (color_picker_controller) dispatches
  // `color-picker:change` { color, name } as the operator drags. Apply it to
  // the matching panel kind; coalesce the commit (drag fires many events).
  onCustomColor(event) {
    const { color, name } = event.detail || {}

    if (!color) return

    this.applyCustomColor(name, color)

    if (this.colorRaf) return

    this.colorRaf = requestAnimationFrame(() => {
      this.colorRaf = null
      this.autoCommit()
    })
  }

  // applyCustomColor — reveal + colour the row's custom swatch (so the choice
  // is visible + re-selectable), set the current colour, and re-ring swatches.
  applyCustomColor(name, color) {
    const sw = this.element.querySelector(`[data-role="custom-${name}"]`)

    if (sw) {
      sw.dataset.color = color
      sw.style.background = color
      sw.hidden = false
    }

    if (name === "log") {
      this.currentLogColor = color
      this.highlightLogColor()
    } else if (name === "table") {
      this.currentTableColor = color
      this.highlightTableColor()
    } else {
      this.currentMetricColor = color
      this.highlightMetricColor()
      this.recolorShapes()
    }
  }

  // highlightMetricColor — ring the active metric color swatch (outline, a
  // CSS-var color, so it survives purge without a safelist entry).
  highlightMetricColor() {
    if (!this.hasMetricSwatchTarget) return

    this.metricSwatchTargets.forEach((el) => {
      const active = el.dataset.color === this.currentMetricColor

      el.style.outline = active ? "2px solid var(--voodu-accent)" : "none"
      el.style.outlineOffset = active ? "1px" : "0"
    })
  }

  // recolorShapes — paint the shape-card skeletons in the chosen color (their
  // strokes use currentColor), so the previews show the real chart hue.
  recolorShapes() {
    if (!this.hasShapeSkeletonTarget) return

    this.shapeSkeletonTargets.forEach((el) => { el.style.color = this.currentMetricColor || "" })
  }

  selectType(event) {
    const t = event.currentTarget.dataset.chartType

    if (!t) return

    this.currentChartType = t

    // Multi-pod is enabled for every non-Query render, so switching shapes keeps
    // the pod selection (seed it with the current pod if empty). Query is
    // single-pod, so it collapses any multi-series selection.
    if (!this.isQueryMeasure) {
      if (!(this.selectedPods || []).length && this.currentSource?.scope_kind === "pod") {
        this.selectedPods = [this.currentSource]
      }
    } else {
      this.selectedPods = []
    }

    this.updateSourceLabel()
    this.markSelectedSources()
    this.highlightShape()
    this.autoCommit()
  }

  // highlightShape — ring the active shape chip (accent border + fill). Inline
  // styles so nothing depends on a purge-scanned Tailwind class.
  highlightShape() {
    this.syncTimelineRow()

    if (!this.hasShapeChipTarget) return

    this.shapeChipTargets.forEach((el) => {
      const active = el.dataset.chartType === this.currentChartType

      el.style.borderColor = active ? "var(--voodu-accent-line)" : ""
      el.style.background   = active ? "var(--voodu-accent-dim)" : ""
      el.setAttribute("aria-pressed", active ? "true" : "false")
    })
  }

  // syncTimelineRow — the "Show timeline chart" toggle only applies to a Number
  // render (it decides whether the tile draws its sparkline). Reveal that row
  // for Number, hide it for every other render. Runs from highlightShape, so it
  // fires on every render/measure/load change.
  syncTimelineRow() {
    if (this.hasMetricTimelineRowTarget) {
      this.metricTimelineRowTarget.hidden = this.currentChartType !== "number"
    }
  }

  // syncTypeAvailability — EVERY render is offered for EVERY measure. No gating,
  // no snapping: the operator owns the pairing (a render the measure can't fill
  // just reads empty — a product choice). The only mode switch left is Query,
  // which reveals the editor (applyQueryMode) — it does NOT gate the chips.
  syncTypeAvailability() {
    if (this.hasShapeChipTarget) {
      this.shapeChipTargets.forEach((el) => { el.hidden = false })
    }

    this.highlightShape()
  }

  isGaugeType(t) {
    return t === "gauge_radial" || t === "gauge_linear"
  }

  // buildMeasureIndex — collapse the { kind => [spec, …] } catalog into a
  // measure index keyed by LABEL: every distinct measure across all workload
  // kinds (host + pod kinds), each remembering its per-kind spec. The Type
  // dropdown is picked FIRST and lists every measure regardless of source, so a
  // measure that differs by kind (host `mem_used_bytes` vs pod `mem_usage_bytes`
  // Memory) resolves to the right metric once a source is chosen — CPU/Memory
  // work on both, while a source-only measure (Disk on host, Net/HTTP on pods)
  // simply reads empty where it doesn't exist.
  buildMeasureIndex() {
    this.measureOrder = []
    this.measureByLabel = new Map()

    Object.values(this.catalogValue || {}).forEach((specs) => {
      (specs || []).forEach((spec) => {
        let entry = this.measureByLabel.get(spec.label)

        if (!entry) {
          entry = { display: spec, byKind: {} }
          this.measureByLabel.set(spec.label, entry)
          this.measureOrder.push(spec.label)
        }
      })
    })

    // Second pass keys each measure's spec by the kind it came from (needs the
    // kind key, lost by Object.values above).
    Object.entries(this.catalogValue || {}).forEach(([kind, specs]) => {
      (specs || []).forEach((spec) => { this.measureByLabel.get(spec.label).byKind[kind] = spec })
    })
  }

  // measureKindKey — the catalog key for a source: "host" for the host, else the
  // workload kind ("deployment"/"statefulset"/…). Mirrors the old populateMetrics.
  measureKindKey(source) {
    return source && source.scope_kind === "host" ? "host" : ((source && source.kind) || "pod")
  }

  // resolveMeasure — the concrete spec for a measure LABEL against a source's
  // kind, or the measure's display spec as a fallback (the source doesn't emit
  // this measure → the panel reads empty data, by the operator's own choice).
  resolveMeasure(label, source) {
    const entry = this.measureByLabel.get(label)

    if (!entry) return null

    return entry.byKind[this.measureKindKey(source)] || entry.display
  }

  // populateMetrics — render the Type dropdown as the FULL measure set (every
  // label across all kinds) + Query, independent of the chosen source, then
  // re-bind the current measure to the current source's kind. Rebuilt idempotently
  // so every caller (source change, multi-pod toggle, edit-load) keeps working.
  populateMetrics() {
    if (!this.hasMetricMenuTarget) return

    const specs = [...this.measureOrder.map((l) => this.measureByLabel.get(l).display), this.queryMeasureSpec()]

    this.metricMenuTarget.innerHTML = ""
    specs.forEach((spec) => this.metricMenuTarget.appendChild(this.metricOption(spec)))

    // Query mode is source-independent — keep it. Otherwise re-resolve the
    // current measure BY LABEL for the current source (its metric key can differ
    // per kind), so switching sources re-binds the same measure to the new kind.
    if (!this.isQueryMeasure) {
      const label = (this.currentMetric && this.currentMetric.label) || this.measureOrder[0]
      const next = label ? this.resolveMeasure(label, this.currentSource) : null

      if (!this.currentMetric || !next || this.currentMetric.metric !== next.metric) {
        this.currentMetricColor = next ? next.color : null
      }

      this.currentMetric = next
    }

    if (this.hasMetricLabelTarget) {
      this.metricLabelTarget.textContent = this.currentMetric ? this.currentMetric.label : "Select type"
    }

    this.highlightMetricColor()
    this.recolorShapes()
    this.syncTypeAvailability()
  }

  // queryMeasureSpec — the synthetic "Query" measure appended to a pod's metric
  // list. `query: true` flags it so selectMetric enters Query mode; metric
  // "__query__" is a sentinel that never collides with a real catalog metric.
  queryMeasureSpec() {
    return { metric: "__query__", label: "Query", color: "var(--voodu-orange)", unit: "", gauge: false, query: true }
  }

  // applyQueryMode — enter/leave Query mode: reveal the query editor, and when
  // leaving, drop the multi-pod selection (a query is single-pod). The render
  // chip gating happens in syncTypeAvailability (which reads isQueryMeasure).
  applyQueryMode(on) {
    this.isQueryMeasure = on

    if (this.hasMetricQueryRowTarget) this.metricQueryRowTarget.hidden = !on

    // A query is one pod — collapse any multi-series selection on entry so the
    // panel doesn't carry a stale pods list into a log/table shape.
    if (on) this.selectedPods = []
  }

  metricOption(spec) {
    const b = document.createElement("button")

    b.type = "button"
    b.className = "flex items-center gap-2.5 w-full px-3 py-2 min-h-[34px] text-left text-[12.5px] text-voodu-text hover:bg-[#ffffff08]"
    b.textContent = spec.label
    b.dataset.action = "click->dashboard-builder#selectMetric click->dropdown#close"
    b.dataset.metric = JSON.stringify(spec)

    return b
  }

  // autoCommit — live-save the in-progress panel into the list as the
  // operator edits (no explicit Add/Update button). Creates the panel on the
  // first valid input, then updates it in place. Stays in the editor (never
  // deselects / closes); the dashboard only persists on Save changes.
  autoCommit() {
    const panel = this.panelForType()

    if (!panel) return

    if (this.editingIndex != null && this.panels[this.editingIndex]) {
      this.panels.splice(this.editingIndex, 1, panel)
    } else {
      this.panels.push(panel)
      this.editingIndex = this.panels.length - 1
      this.selectedIndex = this.editingIndex
    }

    this.render()
    this.sync()
    this.syncWizard()
    this.autoPreview()
  }

  // panelForType — the in-progress panel for the active add type, or null
  // when there isn't enough input to build one yet.
  panelForType() {
    if (this.addType === "log") return this.buildLogPanelSafe()

    if (this.addType === "table" || this.addType === "hep3") return this.buildTablePanelSafe()

    if (this.addType === "http") return this.buildHttpPanelSafe()

    return this.buildPanelSafe()
  }

  // buildPanelSafe — the metric panel for the current source+metric, or null
  // when there isn't enough to build one yet. In Query mode it only needs a pod
  // source (logs are per-pod); a blank query is allowed — the panel commits as a
  // placeholder the instant Query is picked (like the HTTP panel) and the row
  // stays put while the operator types, rather than vanishing. The model guards
  // a blank count query on save.
  buildPanelSafe() {
    if (!this.currentSource || !this.currentMetric) return null

    if (this.isQueryMeasure && this.currentSource.scope_kind !== "pod") return null

    return this.buildPanel(this.currentSource, this.currentMetric)
  }

  // metricQueryText — the trimmed LogQuery from the Metric block's query editor.
  metricQueryText() {
    return this.hasMetricQueryTarget ? this.metricQueryTarget.value.trim() : ""
  }

  // buildLogPanelSafe — the log-count panel for the current source+query, or
  // null until both a pod and a non-empty query exist.
  buildLogPanelSafe() {
    if (!this.currentLogSource) return null

    const query = this.hasLogQueryTarget ? this.logQueryTarget.value.trim() : ""

    if (!query) return null

    return this.buildLogPanel(query)
  }

  // editPanel — load an existing panel back into the matching builder block
  // (pre-filled) and jump to the config step; subsequent edits auto-save in
  // place (editingIndex tracks the row).
  editPanel(event) {
    event.preventDefault()
    const i = Number(event.params.index)

    if (Number.isNaN(i)) return

    const panel = this.panels[i]

    if (!panel) return

    this.editingIndex = i
    this.selectedIndex = i
    this.addType = this.typeForPanel(panel)
    this.wizardStep = "config"
    this.syncWizard()

    if (this.addType === "log") this.loadLogPanel(panel)
    else if (this.addType === "table" || this.addType === "hep3") this.loadTablePanel(panel)
    else if (this.addType === "http") this.loadHttpPanel(panel)
    else this.loadMetricPanel(panel)

    this.render()
    this.autoPreview()
  }

  // typeForPanel — the add-wizard type a saved panel edits under. Log-query
  // panels (scope_kind "log", and the logs DataTable "table"+source "logs") now
  // author under the Metric block's "Query" measure, so both route to "metric".
  // HEP3 (table+hep3) + HTTP (table+http) keep their own blocks.
  typeForPanel(panel) {
    if (panel.scope_kind === "log") return "metric"

    if (panel.scope_kind === "table") {
      if (panel.source === "hep3") return "hep3"
      if (panel.source === "http") return "http"
      if (panel.source === "logs") return "metric"

      return "table"
    }

    return "metric"
  }

  // serverName — a server's display name by server_id (from the servers map).
  serverName(serverId) {
    const map = this.serversValue || {}

    return map[serverId] || map[String(serverId)] || ""
  }

  // sourceTriggerLabel — ALWAYS prefix a source label with its server (mirrors the
  // form's source_text) so the server owning a host/pod is explicit even in a
  // single-server org.
  sourceTriggerLabel(serverId, base) {
    const name = this.serverName(serverId)

    return name ? `${name} · ${base}` : base
  }

  // resolvePodKind — a saved pod may not carry its workload kind: older panels
  // stored only scope/name, and the mirrored panel.kind can also be blank. The
  // metric catalog is keyed by kind ("deployment"/"statefulset"/…, NEVER "pod"),
  // so a wrong kind yields an empty catalog → null metric → the metric picker
  // empties AND the chart-type chips shuffle (gauges gate on the metric). Recover
  // the real kind from the live source options (which always carry it), then fall
  // back to the panel's mirrored kind, then a harmless default.
  resolvePodKind(pod, fallback) {
    if (pod && pod.kind) return pod.kind

    const match = this.sourceOptionFor(pod)

    return (match && match.kind) || fallback || "pod"
  }

  // sourceOptionFor — the rendered source option matching a pod by identity, so
  // its authoritative kind can be read back.
  sourceOptionFor(pod) {
    if (!pod) return null

    const opts = this.element.querySelectorAll("[data-dropdown-target='option'][data-source]")

    for (const el of opts) {
      const s = this.parse(el.dataset.source)

      if (s && s.scope_kind === "pod" && s.scope === pod.scope && s.name === pod.name && String(s.server_id) === String(pod.server_id)) {
        return s
      }
    }

    return null
  }

  // loadMetricPanel — restore source + metric + chart type into the metric
  // block's dropdowns from a saved panel. A log-query panel (scope_kind "log",
  // or the logs DataTable "table"+source "logs") restores into Query mode
  // instead of a warehouse metric.
  loadMetricPanel(panel) {
    if (panel.scope_kind === "log" || (panel.scope_kind === "table" && panel.source === "logs")) {
      this.loadQueryPanel(panel)

      return
    }

    const host = panel.scope_kind === "host"
    // Resolve the workload kind ONCE (recovering it from source options for old
    // panels) and reuse it for the source, the metric catalog key, and the label.
    const kind = host ? "host" : this.resolvePodKind(panel, panel.kind)

    this.currentSource = host
      ? { scope_kind: "host", label: "host", server_id: panel.server_id }
      : { scope_kind: "pod", scope: panel.scope, name: panel.name, kind: kind, label: panel.name, server_id: panel.server_id }

    if (this.hasSourceLabelTarget) {
      const base = host ? "Host (system)" : `${panel.name} · ${kind}`

      this.sourceLabelTarget.textContent = this.sourceTriggerLabel(panel.server_id, base)
    }

    this.populateMetrics()

    const spec = ((this.catalogValue && this.catalogValue[kind]) || []).find((s) => s.metric === panel.metric)

    if (spec) {
      this.currentMetric = spec
      if (this.hasMetricLabelTarget) this.metricLabelTarget.textContent = spec.label
    }

    // Restore the saved color (an override, or the canonical default).
    this.currentMetricColor = panel.color || (spec && spec.color) || null
    this.highlightMetricColor()
    this.recolorShapes()
    if (String(panel.color).startsWith("#")) this.applyCustomColor("metric", panel.color)

    this.currentChartType = panel.chart_type || "area"

    // Restore the Number "Show timeline chart" toggle (absent = shown). Harmless
    // for non-Number renders — syncTimelineRow hides the row for those.
    if (this.hasMetricShowChartTarget) this.metricShowChartTarget.checked = panel.show_chart !== false

    // Multi-series: restore the selected pods so re-editing shows all lines.
    // kind must be the REAL workload kind (not literal "pod") or the metric
    // catalog lookup on the next toggle comes back empty. resolvePodKind recovers
    // it from the source options for panels saved before per-pod kind existed.
    this.selectedPods = Array.isArray(panel.pods)
      ? panel.pods.map((p) => (
        p.scope_kind === "host"
          ? { scope_kind: "host", server_id: p.server_id, label: "host" }
          : { scope_kind: "pod", server_id: p.server_id, scope: p.scope, name: p.name, kind: this.resolvePodKind(p, panel.kind), label: p.name }
      ))
      : []
    this.updateSourceLabel()
    this.markSelectedSources()

    this.syncTypeAvailability()
  }

  // loadQueryPanel — restore a log-query panel into the Metric block's Query
  // measure: the pod source, the Query measure + its editor, the render (from
  // chart_type), and the color. Handles both the log shape (query in `query`,
  // default render "number") and the logs DataTable shape (query in
  // `filter_query`, render "table").
  loadQueryPanel(panel) {
    const kind = this.resolvePodKind(panel, panel.kind)

    this.currentSource = { scope_kind: "pod", scope: panel.scope, name: panel.name, kind: kind, label: panel.name, server_id: panel.server_id }

    if (this.hasSourceLabelTarget) {
      this.sourceLabelTarget.textContent = this.sourceTriggerLabel(panel.server_id, `${panel.name} · ${kind}`)
    }

    // Rebuild the metric menu for this source (appends the Query measure), then
    // pick Query so the label + Query mode are set.
    this.populateMetrics()
    this.currentMetric = this.queryMeasureSpec()
    if (this.hasMetricLabelTarget) this.metricLabelTarget.textContent = this.currentMetric.label
    this.applyQueryMode(true)

    // The log shape stores the filter in `query`; the logs DataTable in
    // `filter_query`. Default render: number for a log panel, table for the
    // logs DataTable.
    const isTable = panel.scope_kind === "table"

    this.currentChartType = panel.chart_type || (isTable ? "table" : "number")

    if (this.hasMetricQueryTarget) {
      this.metricQueryTarget.value = panel.query || panel.filter_query || ""
      this.metricQueryTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }

    this.currentMetricColor = panel.color || this.currentMetric.color
    this.highlightMetricColor()
    this.recolorShapes()
    if (String(panel.color).startsWith("#")) this.applyCustomColor("metric", panel.color)

    this.selectedPods = []
    this.updateSourceLabel()
    this.markSelectedSources()
    this.syncTypeAvailability()
  }

  // loadLogPanel — restore pod + label + query + color into the log block.
  loadLogPanel(panel) {
    this.currentLogSource = { scope_kind: "pod", scope: panel.scope, name: panel.name, kind: panel.kind || "pod", label: panel.name, server_id: panel.server_id }
    if (this.hasLogSourceLabelTarget) this.logSourceLabelTarget.textContent = this.sourceTriggerLabel(panel.server_id, `${panel.name} · ${panel.kind || "pod"}`)
    if (this.hasLogLabelTarget) this.logLabelTarget.value = panel.label || ""

    if (this.hasLogQueryTarget) {
      this.logQueryTarget.value = panel.query || ""
      this.logQueryTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }

    // Restore the chart toggle (default checked — a legacy panel without the
    // key keeps its chart, matching the read path's default).
    if (this.hasLogShowChartTarget) this.logShowChartTarget.checked = panel.show_chart !== false

    this.currentLogColor = panel.color || this.defaultLogColor()
    this.highlightLogColor()
    // A saved hex is a custom colour (presets are CSS vars) — surface it as
    // the row's custom swatch so it shows as selected.
    if (String(panel.color).startsWith("#")) this.applyCustomColor("log", panel.color)
  }

  remove(event) {
    event.preventDefault()
    const i = Number(event.params.index)

    if (Number.isNaN(i)) return

    // Removing anything cancels an in-flight edit (indices shift). If we
    // WERE editing, fall back to idle; an in-progress add keeps its step.
    const wasEditing = this.editingIndex != null

    this.panels.splice(i, 1)
    this.cancelEdit()
    if (wasEditing) this.wizardStep = "idle"
    this.render()
    this.sync()
    this.syncWizard()
  }

  // buildPanel — combine the source identity with the chosen metric
  // spec into a self-contained panel. Label reads "<source> · <metric>"
  // so two CPU panels from different pods stay distinguishable.
  buildPanel(source, spec) {
    // Query measure → a LogQuery panel, not a warehouse metric. Ignore the
    // metric fields entirely and route by the chosen render (Table → a logs
    // DataTable; everything else → a scope_kind="log" count/timeseries).
    if (spec.query) return this.buildQueryPanel(source)

    // "<server> · host" / "<server> · <pod>" so a single-source panel title names
    // its server too (consistent with the dropdown + multi-series legend).
    const srcBase = source.scope_kind === "host" ? "host" : (source.name || source.label)
    const srcLabel = this.sourceTriggerLabel(source.server_id, srcBase)

    const panel = {
      scope_kind: source.scope_kind,
      // server_id — the server this panel reads from (M2). Rides in every
      // source option; the model rejects a panel whose server_id isn't in the org.
      server_id:  source.server_id,
      metric:     spec.metric,
      scale:      spec.scale,
      label:      `${srcLabel} · ${spec.label}`,
      // Operator's chosen color, falling back to the metric's canonical one.
      color:      this.currentMetricColor || spec.color,
      unit:       spec.unit || "",
      // A GAUGE type only sticks for a metric with a ceiling; a gauge picked on
      // a ceiling-less metric falls back to Area. Area / Bar / Line are valid
      // for any metric, so keep the operator's choice.
      chart_type: (this.isGaugeType(this.currentChartType) && !spec.gauge) ? "area" : this.currentChartType
    }

    // Number render → the "Show timeline chart" toggle decides whether the tile
    // draws its sparkline. Only carried for Number (other renders ignore it), and
    // only when off — absent = shown, keeping the stored panel minimal.
    if (this.currentChartType === "number") {
      const showChart = this.hasMetricShowChartTarget ? this.metricShowChartTarget.checked : true

      if (!showChart) panel.show_chart = false
    }

    if (source.scope_kind === "pod") {
      panel.scope = source.scope
      panel.name  = source.name
      panel.kind  = source.kind
    }

    // Multi-series: 2+ selected sources (pods and/or the host) → store the list.
    // Fires whatever the anchor is, so a Host + pod chart is a multi panel too.
    // The read path draws one mark per member for Line/Area, and the first member
    // for the rest (the list survives either way).
    const pods = this.selectedPods || []

    if (pods.length >= 2) {
      // Each member marks its scope_kind. A pod carries its workload kind — the
      // metric catalog is keyed by kind ("deployment"/…), never "pod", so a
      // re-opened panel resolves the right catalog. The host carries only its
      // server (one node per server, no container).
      panel.pods = pods.map((p) => (
        p.scope_kind === "host"
          ? { scope_kind: "host", server_id: p.server_id }
          : { scope_kind: "pod", server_id: p.server_id, scope: p.scope, name: p.name, kind: p.kind }
      ))

      // Mirror the first POD into the single-series fields (keeps a pod-anchored
      // panel valid); a host-anchored panel keeps scope_kind "host".
      const firstPod = pods.find((p) => p.scope_kind !== "host")

      if (firstPod) { panel.scope = firstPod.scope; panel.name = firstPod.name; panel.kind = firstPod.kind }

      const noun = pods.some((p) => p.scope_kind === "host") ? "series" : "pods"

      panel.label = `${pods.length} ${noun} · ${spec.label}`
    }

    return panel
  }

  // buildQueryPanel — the "Query" measure's panel. Storage is routed by the
  // chosen render, transparent to the operator:
  //   Table                     → a logs DataTable (scope_kind "table", source
  //                                "logs", chart_type "table", filter_query).
  //   Number / Line / Area / Bar → a log-count panel (scope_kind "log",
  //                                agg "count", chart_type = the render, query).
  // Label defaults to "<pod> · query" so an unlabeled panel still reads.
  buildQueryPanel(source) {
    const query = this.metricQueryText()
    const color = this.currentMetricColor || "var(--voodu-orange)"

    if (this.currentChartType === "table") {
      return {
        scope_kind:   "table",
        source:       "logs",
        server_id:    source.server_id,
        scope:        source.scope,
        name:         source.name,
        view:         "lines",
        chart_type:   "table",
        filter_query: query,
        label:        `${source.name} · logs`,
        color:        color
      }
    }

    return {
      scope_kind: "log",
      server_id:  source.server_id,
      scope:      source.scope,
      name:       source.name,
      kind:       source.kind,
      query:      query,
      agg:        "count",
      chart_type: this.currentChartType,
      label:      `${source.name} · query`,
      color:      color
    }
  }

  // ── log-count panels ──────────────────────────────────────────────
  // A different shape from a metric panel: no metric/scale, but a LogQuery
  // filter string + the workload identity, rendered as a big-number tile.

  selectLogSource(event) {
    const source = this.parse(event.currentTarget.dataset.source)

    if (!source) return

    this.currentLogSource = source
    if (this.hasLogSourceLabelTarget) this.logSourceLabelTarget.textContent = this.optionLabel(event.currentTarget)
    this.autoCommit()
  }

  selectLogColor(event) {
    const color = event.currentTarget.dataset.color

    if (!color) return

    this.currentLogColor = color
    this.highlightLogColor()
    this.autoCommit()
  }


  // defaultLogColor — first swatch's token, falling back to orange when the
  // swatches haven't rendered (defensive; the form always renders them).
  defaultLogColor() {
    if (this.hasLogSwatchTarget && this.logSwatchTargets.length) return this.logSwatchTargets[0].dataset.color

    return "var(--voodu-orange)"
  }

  // highlightLogColor — ring the active swatch. Uses outline (a CSS-var
  // color) instead of a Tailwind ring class so it survives purge without a
  // safelist entry.
  highlightLogColor() {
    if (!this.hasLogSwatchTarget) return

    this.logSwatchTargets.forEach((el) => {
      const active = el.dataset.color === this.currentLogColor

      el.style.outline       = active ? "2px solid var(--voodu-accent)" : "none"
      el.style.outlineOffset = active ? "1px" : "0"
    })
  }

  // buildLogPanel — count panel. Label defaults to "<pod> · count" so an
  // operator who skips the label field still gets a distinguishable tile.
  buildLogPanel(query) {
    const src   = this.currentLogSource
    const label = (this.hasLogLabelTarget ? this.logLabelTarget.value : "").trim()

    // show_chart — the "Show timeline chart" toggle. Default true when the
    // target is absent (older markup) so a count tile keeps its chart.
    const showChart = this.hasLogShowChartTarget ? this.logShowChartTarget.checked : true

    return {
      scope_kind: "log",
      server_id:  src.server_id,
      scope:      src.scope,
      name:       src.name,
      kind:       src.kind,
      query:      query,
      agg:        "count",
      label:      label || `${src.name} · count`,
      color:      this.currentLogColor || "var(--voodu-orange)",
      chart_type: "number",
      show_chart: showChart
    }
  }

  // ── table panels (Table logs + HEP3 share this block) ───────────────
  // Both kinds render a DataSource·view via the data-table controller and
  // carry {source, scope, name, view} in each option. The block is one; the
  // KIND (this.tableKind) swaps the options list, the editor's filter fields,
  // and the title — so "Table" (logs, pod-based) and "HEP3" (reader-based)
  // stay distinct panel types without duplicating the block.

  sourceViews() {
    const list = this.tableKind === "hep3" ? this.hep3SourceViewsValue : this.logsSourceViewsValue

    return Array.isArray(list) ? list : []
  }

  // activateTableKind — switch the shared block to a kind: repopulate the
  // option menu, swap the filter-editor's fields, retitle, and pre-pick the
  // first option (so autoCommit can create the panel).
  activateTableKind(kind) {
    this.tableKind = kind === "hep3" ? "hep3" : "table"
    this.currentTableSourceView = null

    if (this.hasTableBlockTitleTarget) this.tableBlockTitleTarget.textContent = this.tableKind === "hep3" ? "HEP3 panel" : "Table panel"

    // The HEP3 kind picks a visualization (Table rows / Area / Radial /
    // Linear); the Table (logs) kind only tabulates. Default Table.
    const isHep3 = this.tableKind === "hep3"

    if (this.hasHep3ShapesTarget) this.hep3ShapesTarget.hidden = !isHep3
    if (isHep3 && !this.currentHep3Shape) this.currentHep3Shape = "table"
    if (!isHep3) this.currentHep3Shape = "table"
    this.highlightHep3Shape()

    this.rebuildSourceMenu()
    this.setQueryEditorFields()

    const list = this.sourceViews()

    if (list.length) this.applySourceView(list[0])
  }

  // selectHep3Shape — a HEP3 panel's visualization (table/area/gauge_*). Drives
  // the panel's chart_type; Table = rows, the rest = a count chart.
  selectHep3Shape(event) {
    const shape = event.currentTarget.dataset.chartType

    if (!shape) return

    this.currentHep3Shape = shape
    this.highlightHep3Shape()
    this.autoCommit()
  }

  highlightHep3Shape() {
    const shape = this.currentHep3Shape || "table"

    if (this.hasHep3ShapeChipTarget) {
      this.hep3ShapeChipTargets.forEach((chip) => {
        const active = chip.dataset.chartType === shape

        chip.classList.toggle("border-voodu-accent-line", active)
        chip.classList.toggle("ring-1", active)
        chip.classList.toggle("ring-voodu-accent-line", active)
      })
    }

    // The "show %" toggle only applies to gauges (Radial/Linear).
    if (this.hasHep3PercentRowTarget) {
      this.hep3PercentRowTarget.hidden = !(shape === "gauge_radial" || shape === "gauge_linear")
    }
  }

  // rebuildSourceMenu — fill the dropdown with the active kind's options.
  rebuildSourceMenu() {
    if (!this.hasTableSourceMenuTarget) return

    this.tableSourceMenuTarget.innerHTML = ""

    this.sourceViews().forEach((sv) => {
      const btn = document.createElement("button")

      btn.type = "button"
      btn.className = "flex items-center gap-2.5 w-full px-3 py-2 min-h-[34px] text-left text-[12.5px] text-voodu-text hover:bg-voodu-hover"
      btn.dataset.action = "click->dashboard-builder#selectTableSourceView click->dropdown#close"
      btn.dataset.sourceView = JSON.stringify(sv)
      btn.textContent = sv.label
      this.tableSourceMenuTarget.appendChild(btn)
    })
  }

  // setQueryEditorFields — point the filter editor's autocomplete + validation
  // at the active kind's fields (logs vs the SIP columns). Setting the value
  // attribute fires the query-editor's fieldsValueChanged.
  setQueryEditorFields() {
    if (!this.hasTableQueryTarget) return

    const editor = this.tableQueryTarget.closest('[data-controller~="query-editor"]')

    if (!editor) return

    const fields = this.tableKind === "hep3" ? this.hep3FieldsValue : this.logsFieldsValue

    editor.setAttribute("data-query-editor-fields-value", JSON.stringify(Array.isArray(fields) ? fields : []))

    if (this.tableKind === "hep3") {
      editor.setAttribute("data-query-editor-hints-value", JSON.stringify(this.hep3HintsValue || {}))
    } else {
      editor.setAttribute("data-query-editor-hints-value", "{}")
    }
  }

  applySourceView(sv) {
    this.currentTableSourceView = sv
    if (this.hasTableSourceViewLabelTarget) this.tableSourceViewLabelTarget.textContent = sv.label
  }

  selectTableSourceView(event) {
    const sv = this.parse(event.currentTarget.dataset.sourceView)

    if (!sv) return

    this.applySourceView(sv)
    this.autoCommit()
  }

  selectTableColor(event) {
    const color = event.currentTarget.dataset.color

    if (!color) return

    this.currentTableColor = color
    this.highlightTableColor()
    this.autoCommit()
  }

  // buildTablePanelSafe — the HEP3 panel, or null until a source·view is
  // chosen (it defaults in, and carries the reader's scope/name).
  buildTablePanelSafe() {
    if (!this.currentTableSourceView) return null

    return this.buildTablePanel()
  }

  buildTablePanel() {
    const sv = this.currentTableSourceView
    const label = (this.hasTableLabelTarget ? this.tableLabelTarget.value : "").trim()
    const filterQuery = (this.hasTableQueryTarget ? this.tableQueryTarget.value : "").trim()
    // HEP3 picks a visualization (table rows / area / gauge_*); logs → table.
    const chartType = this.tableKind === "hep3" ? (this.currentHep3Shape || "table") : "table"
    const isGauge = chartType === "gauge_radial" || chartType === "gauge_linear"
    // Gauges default to the raw count; "show %" flips them to "% of peak".
    const percent = isGauge && this.hasHep3PercentTarget && this.hep3PercentTarget.checked

    return {
      scope_kind:   "table",
      chart_type:   chartType,
      source:       sv.source,
      // server_id — the server this reader lives on (M2). hep3/logs source-views
      // carry it; an http panel has no server so it stays undefined.
      server_id:    sv.server_id,
      scope:        sv.scope,
      name:         sv.name,
      view:         sv.view,
      label:        label || sv.label,
      color:        this.currentTableColor || this.defaultTableColor(),
      filter_query: filterQuery,
      percent:      percent
    }
  }

  // ── http (external API) panel ──────────────────────────────────────

  // buildHttpPanelSafe — the HTTP panel for the current request. Always returns
  // a panel (even with a blank URL) so picking the HTTP type inserts a row
  // immediately, like HEP3/Metric; the model guards a blank URL on save.
  buildHttpPanelSafe() {
    return this.buildHttpPanel(this.httpFieldValue("httpUrl"))
  }

  buildHttpPanel(url) {
    return {
      scope_kind: "table",
      source:     "http",
      chart_type: this.currentHttpChartType || "table",
      url,
      method:     this.hasHttpMethodTarget ? this.httpMethodTarget.value : "GET",
      headers:    this.parseHttpHeaders(),
      body:       this.httpFieldValue("httpBody"),
      interval:   this.httpFieldValue("httpInterval") || "auto",
      view:       "response",
      label:      this.httpFieldValue("httpLabel") || "External API",
      color:      this.currentHttpColor || "var(--voodu-cyan)",
      mapping:    this.parseHttpMapping()
    }
  }

  httpFieldValue(target) {
    const key = `has${target[0].toUpperCase()}${target.slice(1)}Target`

    return this[key] ? this[`${target}Target`].value.trim() : ""
  }

  // parseHttpHeaders — the add-row key/value pairs → object. Keys + values are
  // parallel target lists in DOM order, so index i pairs one row. Blank keys
  // (an empty row the operator hasn't filled) are skipped.
  parseHttpHeaders() {
    const keys = this.httpHeaderKeyTargets
    const values = this.httpHeaderValueTargets
    const out = {}

    keys.forEach((keyEl, i) => {
      const k = keyEl.value.trim()

      if (k) out[k] = (values[i]?.value || "").trim()
    })

    return out
  }

  // switchHttpTab — Postman-style tabs: reveal the clicked tab's panel, hide
  // the rest, and mark the tab selected.
  switchHttpTab(event) {
    const name = event.currentTarget.dataset.httpTab

    this.httpTabTargets.forEach((t) => t.setAttribute("aria-selected", t.dataset.httpTab === name ? "true" : "false"))
    this.httpTabPanelTargets.forEach((p) => { p.hidden = p.dataset.httpTab !== name })
  }

  // selectHttpMethod — the method dropdown: store the verb in the hidden input
  // + reflect it in the trigger label, then rebuild the panel.
  selectHttpMethod(event) {
    const method = event.currentTarget.dataset.method

    if (this.hasHttpMethodTarget) this.httpMethodTarget.value = method
    if (this.hasHttpMethodLabelTarget) this.httpMethodLabelTarget.textContent = method
    this.autoCommit()
  }

  addHttpHeader() {
    if (!this.hasHttpHeaderTemplateTarget || !this.hasHttpHeadersRowsTarget) return

    this.httpHeadersRowsTarget.appendChild(this.httpHeaderTemplateTarget.content.cloneNode(true))
  }

  removeHttpHeader(event) {
    event.currentTarget.closest("div").remove()
    this.autoCommit()
  }

  parseHttpMapping() {
    if (!this.hasHttpMappingTarget) return {}

    try {
      return JSON.parse(this.httpMappingTarget.value || "{}")
    } catch (_e) {
      return {}
    }
  }

  selectHttpChartType(event) {
    this.currentHttpChartType = event.currentTarget.dataset.chartType || "table"
    this.highlightHttpChart()
    this.autoCommit()
  }

  highlightHttpChart() {
    this.httpChartChipTargets.forEach((el) => {
      el.dataset.active = el.dataset.chartType === this.currentHttpChartType ? "true" : "false"
    })
  }

  selectHttpColor(event) {
    this.currentHttpColor = event.currentTarget.dataset.color
    this.highlightHttpColor()
    this.autoCommit()
  }

  highlightHttpColor() {
    this.httpSwatchTargets.forEach((el) => {
      el.dataset.active = el.dataset.color === this.currentHttpColor ? "true" : "false"
    })
  }

  // testHttp — fire the in-progress config server-side; show raw × parsed so
  // the operator discovers the response shape and confirms the mapping.
  async testHttp() {
    const url = this.httpFieldValue("httpUrl")
    const status = this.hasHttpTestStatusTarget ? this.httpTestStatusTarget : null

    if (!url) { if (status) status.textContent = "Enter a URL first";

 return }

    if (status) status.textContent = "Testing…"

    const payload = {
      url,
      method: this.hasHttpMethodTarget ? this.httpMethodTarget.value : "GET",
      headers: this.parseHttpHeaders(),
      body: this.httpFieldValue("httpBody"),
      interval: this.httpFieldValue("httpInterval") || "auto",
      mapping: this.hasHttpMappingTarget ? this.httpMappingTarget.value : "{}",
      chart_type: this.currentHttpChartType || "table",
      label: this.httpFieldValue("httpLabel"), scope: "", range: "1h"
    }

    try {
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const resp = await fetch(this.httpTestUrlValue, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token, Accept: "application/json" },
        body: JSON.stringify(payload)
      })
      const data = await resp.json().catch(() => null)

      this.renderHttpTest(data, status)
    } catch (_e) {
      if (status) status.textContent = "Request failed"
    }
  }

  renderHttpTest(data, status) {
    if (this.hasHttpTestResultTarget) this.httpTestResultTarget.hidden = false

    if (!data || data.ok === false) {
      if (status) status.textContent = data?.error || "Failed"
      if (this.hasHttpTestRawTarget) this.httpTestRawTarget.textContent = data?.error || ""
      if (this.hasHttpTestParsedTarget) this.httpTestParsedTarget.textContent = ""

      return
    }

    const parsed = data.series || data.rows || []

    if (status) status.textContent = `✓ ${parsed.length} ${data.series ? "points" : "rows"}`

    if (this.hasHttpTestRawTarget) {
      const raw = JSON.stringify(data.raw, null, 2)
      const shown = raw.length > 4000 ? `${raw.slice(0, 4000)}\n  … (truncated)` : raw

      this.fillJson(this.httpTestRawTarget, shown)
    }

    if (this.hasHttpTestParsedTarget) this.fillJson(this.httpTestParsedTarget, JSON.stringify(parsed.slice(0, 20), null, 2))
  }

  // fillJson — paint a pane with syntax-highlighted JSON. highlightJson is a
  // lexical tokenizer (regex, not a parser), so it colours a truncated tail just
  // fine — NO JSON.parse guard, which would reject the 4k-clipped RESPONSE (cut
  // mid-token → invalid) and silently drop the whole pane to plain text.
  fillJson(el, str) {
    el.innerHTML = this.highlightJson(str)
  }

  // highlightJson — tokenize a JSON string into tok-* spans (same palette as the
  // json-editor). HTML is escaped FIRST — the payload is an untrusted external
  // response — so only our static span markup is ever added.
  highlightJson(str) {
    const esc = str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")

    return esc.replace(
      /("(?:[^"\\]|\\.)*")(\s*:)?|\b(true|false|null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|([{}[\],])/g,
      (match, string, colon, lit, num, punc) => {
        if (string !== undefined) {
          const cls = colon ? "tok-key" : "tok-str"
          const tail = colon ? `<span class="tok-punc">${colon}</span>` : ""

          return `<span class="${cls}">${string}</span>${tail}`
        }

        if (lit !== undefined) return `<span class="tok-lit">${lit}</span>`
        if (num !== undefined) return `<span class="tok-num">${num}</span>`
        if (punc !== undefined) return `<span class="tok-punc">${punc}</span>`

        return match
      }
    )
  }

  // loadHttpPanel — restore the config into the block for edit-in-place.
  loadHttpPanel(panel) {
    const set = (target, value) => { if (this[`has${target[0].toUpperCase()}${target.slice(1)}Target`]) this[`${target}Target`].value = value ?? "" }

    set("httpUrl", panel.url)
    set("httpLabel", panel.label)
    set("httpInterval", panel.interval || "auto")
    const method = panel.method || "GET"

    if (this.hasHttpMethodTarget) this.httpMethodTarget.value = method
    if (this.hasHttpMethodLabelTarget) this.httpMethodLabelTarget.textContent = method
    this.loadHttpHeaders(panel.headers || {})

    // Body + Mapping are json-editors: setting .value alone does NOT repaint the
    // highlight layer (json-editor paints on connect + on `input`). By load time
    // the controller has already connected on the empty field, so we fire `input`
    // to trigger a re-render — otherwise the restored JSON shows uncoloured until
    // the operator edits it.
    if (this.hasHttpBodyTarget) {
      this.httpBodyTarget.value = panel.body ?? ""
      this.httpBodyTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }

    if (this.hasHttpMappingTarget) {
      this.httpMappingTarget.value = JSON.stringify(panel.mapping || {}, null, 2)
      this.httpMappingTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }

    this.currentHttpChartType = panel.chart_type || "table"
    this.currentHttpColor = panel.color || "var(--voodu-cyan)"
    this.highlightHttpChart()
    this.highlightHttpColor()
  }

  // loadHttpHeaders — rebuild the add-row list from a saved headers object: one
  // row per header (or a single blank row when there are none).
  loadHttpHeaders(headers) {
    if (!this.hasHttpHeadersRowsTarget) return

    this.httpHeadersRowsTarget.replaceChildren()
    const entries = Object.entries(headers)
    const rows = entries.length ? entries : [["", ""]]

    rows.forEach(([k, v]) => {
      this.httpHeadersRowsTarget.appendChild(this.httpHeaderTemplateTarget.content.cloneNode(true))
      const row = this.httpHeadersRowsTarget.lastElementChild
      const key = row.querySelector('[data-dashboard-builder-target="httpHeaderKey"]')
      const val = row.querySelector('[data-dashboard-builder-target="httpHeaderValue"]')

      if (key) key.value = k
      if (val) val.value = v
    })
  }

  // loadTablePanel — restore source·view (reader + view) + label + filter +
  // color from a saved panel (edit-in-place). Matches the reader by name so a
  // multi-reader server restores the right one.
  loadTablePanel(panel) {
    // Activate the kind the panel belongs to FIRST (source=hep3 → HEP3 kind),
    // so the options list + filter fields match before we restore.
    this.activateTableKind(panel.source === "hep3" ? "hep3" : "table")

    // Restore the HEP3 visualization (chart_type) + the gauge "show %" toggle.
    if (panel.source === "hep3") {
      this.currentHep3Shape = panel.chart_type || "table"
      this.highlightHep3Shape()
      if (this.hasHep3PercentTarget) this.hep3PercentTarget.checked = panel.percent === true
    }

    const list = this.sourceViews()
    // Match the reader by server_id + name first (the same reader name can live
    // on two servers in the org — M2), then loosen to name-only, then any.
    const sv = list.find((s) => s.source === panel.source && s.view === panel.view && s.name === panel.name && String(s.server_id) === String(panel.server_id)) ||
      list.find((s) => s.source === panel.source && s.view === panel.view && s.name === panel.name) ||
      list.find((s) => s.source === panel.source && s.view === panel.view) || list[0] || null

    if (sv) this.applySourceView(sv)

    if (this.hasTableLabelTarget) this.tableLabelTarget.value = panel.label || ""

    if (this.hasTableQueryTarget) {
      this.tableQueryTarget.value = panel.filter_query || ""
      this.tableQueryTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }

    this.currentTableColor = panel.color || this.defaultTableColor()
    this.highlightTableColor()
    if (String(panel.color).startsWith("#")) this.applyCustomColor("table", panel.color)
  }

  defaultTableColor() {
    if (this.hasTableSwatchTarget && this.tableSwatchTargets.length) return this.tableSwatchTargets[0].dataset.color

    return "var(--voodu-teal)"
  }

  highlightTableColor() {
    if (!this.hasTableSwatchTarget) return

    this.tableSwatchTargets.forEach((el) => {
      const active = el.dataset.color === this.currentTableColor

      el.style.outline       = active ? "2px solid var(--voodu-accent)" : "none"
      el.style.outlineOffset = active ? "1px" : "0"
    })
  }

  render() {
    if (!this.hasListTarget) return

    this.listTarget.innerHTML = ""
    this.panels.forEach((panel, i) => this.listTarget.appendChild(this.chip(panel, i)))

    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.panels.length > 0
  }

  // chip — a panel row in the Panels sidebar. Two lines: the label (dot +
  // "<source> · <metric>") on top, the chart type (Area / Radial / Linear /
  // Count) below. A drag handle on the left, a remove ✕ on the right. The
  // selected row is ringed via inline style (CSS var) so it tracks which
  // editor is open.
  chip(panel, index) {
    const selected = index === this.selectedIndex
    const row = document.createElement("div")

    row.className = "flex items-stretch gap-1 pr-1 border border-voodu-border bg-voodu-surface"

    if (selected) {
      row.style.background = "var(--voodu-accent-dim)"
      row.style.borderColor = "var(--voodu-accent-line)"
    }

    const handle = document.createElement("span")

    handle.className = "inline-flex items-center justify-center w-5 text-voodu-muted-2 hover:text-voodu-text cursor-grab active:cursor-grabbing shrink-0 select-none leading-none"
    handle.setAttribute("data-role", "panel-handle")
    handle.setAttribute("aria-label", "Drag to reorder")
    handle.textContent = "⠿"
    row.appendChild(handle)

    const select = document.createElement("button")

    select.type = "button"
    select.className = "flex flex-col gap-0.5 flex-1 min-w-0 py-1.5 text-left"
    select.setAttribute("aria-label", `Edit ${panel.label}`)
    select.dataset.action = "click->dashboard-builder#editPanel"
    select.dataset.dashboardBuilderIndexParam = index

    const top = document.createElement("span")

    top.className = "flex items-center gap-2 min-w-0"

    const dot = document.createElement("span")

    dot.className = "inline-block w-2 h-2 rounded-full shrink-0"
    dot.style.background = panel.color || "var(--voodu-muted)"
    top.appendChild(dot)

    const label = document.createElement("span")

    label.className = selected ? "text-[12.5px] text-voodu-accent-2 truncate min-w-0" : "text-[12.5px] text-voodu-text truncate min-w-0"
    label.textContent = panel.label
    top.appendChild(label)
    select.appendChild(top)

    const type = document.createElement("span")

    type.className = "text-[10px] font-voodu-mono text-voodu-muted-2 uppercase tracking-[0.04em] pl-4 leading-none"
    type.textContent = this.chipTypeLabel(panel)
    select.appendChild(type)

    row.appendChild(select)

    const remove = document.createElement("button")

    remove.type = "button"
    remove.className = "inline-flex items-center justify-center w-6 self-center text-voodu-muted hover:text-voodu-red shrink-0"
    remove.setAttribute("aria-label", `Remove ${panel.label}`)
    remove.dataset.action = "click->dashboard-builder#remove"
    remove.dataset.dashboardBuilderIndexParam = index
    remove.textContent = "✕"
    row.appendChild(remove)

    return row
  }

  // chipTypeLabel — the type line under each panel's label (CSS-uppercased).
  // Log panels render a number + sparkline → "Log spark". Metric panels read as
  // just their shape (Area / Radial / Linear). Table-kind panels share one
  // "Table" viz across DIFFERENT SOURCES (HEP3 vs an external API) and http can
  // also be a chart (Area / Number) — so they carry a "<source> · <viz>" label
  // ("HEP3 · Table", "API · Area") to disambiguate what was otherwise all "Table".
  chipTypeLabel(panel) {
    if (panel.scope_kind === "log") return "Log spark"

    const viz = this.vizLabel(panel.chart_type)

    if (panel.scope_kind === "table") {
      const src = { hep3: "HEP3", http: "API" }[panel.source] || (panel.source || "").toUpperCase()

      return src ? `${src} · ${viz}` : viz
    }

    return viz
  }

  // vizLabel — the visualization shape as a word. Default "Area" (the metric
  // panel default + the http chart default).
  vizLabel(chartType) {
    switch (chartType) {
      case "table": return "Table"
      case "number": return "Number"
      case "bars": return "Bar"
      case "line": return "Line"
      case "gauge_radial": return "Radial"
      case "gauge_linear": return "Linear"
      default: return "Area"
    }
  }

  sync() {
    if (this.hasHiddenTarget) this.hiddenTarget.value = JSON.stringify(this.panels)
  }

  parse(value) {
    if (!value) return null

    try {
      return JSON.parse(value)
    } catch {
      return null
    }
  }
}
