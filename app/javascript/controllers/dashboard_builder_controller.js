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
  static targets = ["sourceLabel", "metricLabel", "metricMenu", "typeLabel", "typeMenu", "list", "empty", "hidden",
                    "logSourceLabel", "logLabel", "logQuery", "logSwatch",
                    "addTypeBtn", "metricBlock", "logBlock"]
  static values  = {
    catalog: Object,
    panels:  Array
  }

  connect() {
    this.panels = Array.isArray(this.panelsValue) ? this.panelsValue.map((p) => ({ ...p })) : []
    this.currentSource = { scope_kind: "host", label: "host" }
    this.currentMetric = null
    this.currentChartType = "area"

    this.currentLogSource = null
    this.currentLogColor = this.defaultLogColor()
    this.addType = "metric"

    this.populateMetrics()
    this.highlightLogColor()
    this.syncAddType()
    this.render()
    this.sync()
    this.initSortable()
  }

  disconnect() {
    if (this.sortable) this.sortable.destroy()
  }

  // ── add-type toggle (Metric | Log count) ──────────────────────────
  // One "add" block visible at a time so the form doesn't stack two builders.

  setAddType(event) {
    const type = event.currentTarget.dataset.addType

    if (!type) return

    this.addType = type
    this.syncAddType()
  }

  syncAddType() {
    const isLog = this.addType === "log"

    if (this.hasMetricBlockTarget) this.metricBlockTarget.hidden = isLog
    if (this.hasLogBlockTarget) this.logBlockTarget.hidden = !isLog

    if (this.hasAddTypeBtnTarget) {
      this.addTypeBtnTargets.forEach((b) => {
        const active = b.dataset.addType === this.addType

        b.style.background = active ? "var(--voodu-accent-dim)" : "transparent"
        b.style.color      = active ? "var(--voodu-accent-2)" : "var(--voodu-text-2)"
      })
    }
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

    this.render()
    this.sync()
  }

  // selectSource — operator picked a source row. Update the trigger
  // label + remember the identity, then rebuild the metric menu for
  // this source's kind.
  selectSource(event) {
    const source = this.parse(event.currentTarget.dataset.source)

    if (!source) return

    this.currentSource = source
    if (this.hasSourceLabelTarget) this.sourceLabelTarget.textContent = event.currentTarget.textContent.trim()

    this.populateMetrics()
  }

  selectMetric(event) {
    const spec = this.parse(event.currentTarget.dataset.metric)

    if (!spec) return

    this.currentMetric = spec
    if (this.hasMetricLabelTarget) this.metricLabelTarget.textContent = spec.label

    this.syncTypeAvailability()
  }

  selectType(event) {
    const t = event.currentTarget.dataset.chartType

    if (!t) return

    this.currentChartType = t
    if (this.hasTypeLabelTarget) this.typeLabelTarget.textContent = event.currentTarget.textContent.trim()
  }

  // syncTypeAvailability — gauges need a ceiling, so hide the gauge
  // options (and snap the selection back to Area) whenever the current
  // metric has none. Driven by the spec's `gauge` flag from the catalog.
  syncTypeAvailability() {
    const eligible = !!(this.currentMetric && this.currentMetric.gauge)

    if (this.hasTypeMenuTarget) {
      this.typeMenuTarget.querySelectorAll("[data-gauge='true']").forEach((el) => { el.hidden = !eligible })
    }

    if (!eligible && this.currentChartType !== "area") {
      this.currentChartType = "area"
      if (this.hasTypeLabelTarget) this.typeLabelTarget.textContent = "Area"
    }
  }

  // populateMetrics — rebuild the metric dropdown's menu from the
  // catalog for the current source's kind, and default-select the
  // first metric so Add always has a valid pair.
  populateMetrics() {
    if (!this.hasMetricMenuTarget) return

    const key   = this.currentSource.scope_kind === "host" ? "host" : (this.currentSource.kind || "pod")
    const specs = (this.catalogValue && this.catalogValue[key]) || []

    this.metricMenuTarget.innerHTML = ""
    specs.forEach((spec) => this.metricMenuTarget.appendChild(this.metricOption(spec)))

    this.currentMetric = specs[0] || null

    if (this.hasMetricLabelTarget) {
      this.metricLabelTarget.textContent = this.currentMetric ? this.currentMetric.label : "Select metric"
    }

    this.syncTypeAvailability()
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

  add(event) {
    event.preventDefault()
    if (!this.currentSource || !this.currentMetric) return

    this.panels.push(this.buildPanel(this.currentSource, this.currentMetric))
    this.render()
    this.sync()
  }

  remove(event) {
    event.preventDefault()
    const i = Number(event.params.index)

    if (Number.isNaN(i)) return

    this.panels.splice(i, 1)
    this.render()
    this.sync()
  }

  // buildPanel — combine the source identity with the chosen metric
  // spec into a self-contained panel. Label reads "<source> · <metric>"
  // so two CPU panels from different pods stay distinguishable.
  buildPanel(source, spec) {
    const srcLabel = source.label || (source.scope_kind === "host" ? "host" : source.name)

    const panel = {
      scope_kind: source.scope_kind,
      metric:     spec.metric,
      scale:      spec.scale,
      label:      `${srcLabel} · ${spec.label}`,
      color:      spec.color,
      unit:       spec.unit || "",
      // Gauge only sticks for a metric with a ceiling; otherwise area.
      chart_type: spec.gauge ? this.currentChartType : "area"
    }

    if (source.scope_kind === "pod") {
      panel.scope = source.scope
      panel.name  = source.name
      panel.kind  = source.kind
    }

    return panel
  }

  // ── log-count panels ──────────────────────────────────────────────
  // A different shape from a metric panel: no metric/scale, but a LogQuery
  // filter string + the workload identity, rendered as a big-number tile.

  selectLogSource(event) {
    const source = this.parse(event.currentTarget.dataset.source)

    if (!source) return

    this.currentLogSource = source
    if (this.hasLogSourceLabelTarget) this.logSourceLabelTarget.textContent = event.currentTarget.textContent.trim()
  }

  selectLogColor(event) {
    const color = event.currentTarget.dataset.color

    if (!color) return

    this.currentLogColor = color
    this.highlightLogColor()
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

  addLog(event) {
    event.preventDefault()
    if (!this.currentLogSource) return

    const query = this.hasLogQueryTarget ? this.logQueryTarget.value.trim() : ""

    if (!query) {
      if (this.hasLogQueryTarget) this.logQueryTarget.focus()

      return
    }

    this.panels.push(this.buildLogPanel(query))
    this.render()
    this.sync()

    if (this.hasLogLabelTarget) this.logLabelTarget.value = ""

    if (this.hasLogQueryTarget) {
      this.logQueryTarget.value = ""
      // Repaint the syntax-highlight overlay (the query-editor controller
      // only redraws on input) so the cleared field isn't left showing the
      // previous query behind an empty textarea.
      this.logQueryTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }
  }

  // buildLogPanel — count panel. Label defaults to "<pod> · count" so an
  // operator who skips the label field still gets a distinguishable tile.
  buildLogPanel(query) {
    const src   = this.currentLogSource
    const label = (this.hasLogLabelTarget ? this.logLabelTarget.value : "").trim()

    return {
      scope_kind: "log",
      scope:      src.scope,
      name:       src.name,
      kind:       src.kind,
      query:      query,
      agg:        "count",
      label:      label || `${src.name} · count`,
      color:      this.currentLogColor || "var(--voodu-orange)",
      chart_type: "number"
    }
  }

  render() {
    if (!this.hasListTarget) return

    this.listTarget.innerHTML = ""
    this.panels.forEach((panel, i) => this.listTarget.appendChild(this.chip(panel, i)))

    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.panels.length > 0
  }

  chip(panel, index) {
    const row = document.createElement("div")

    row.className = "flex items-center gap-2 px-2.5 h-9 border border-voodu-border bg-voodu-surface"

    const handle = document.createElement("span")

    handle.className = "inline-flex items-center justify-center w-4 h-6 text-voodu-muted-2 hover:text-voodu-text cursor-grab active:cursor-grabbing shrink-0 select-none leading-none"
    handle.setAttribute("data-role", "panel-handle")
    handle.setAttribute("aria-label", "Drag to reorder")
    handle.textContent = "⠿"
    row.appendChild(handle)

    const dot = document.createElement("span")

    dot.className = "inline-block w-2 h-2 rounded-full shrink-0"
    dot.style.background = panel.color || "var(--voodu-muted)"
    row.appendChild(dot)

    const label = document.createElement("span")

    label.className = "text-[12.5px] text-voodu-text truncate flex-1 min-w-0"
    label.textContent = panel.label
    row.appendChild(label)

    const typeTag = this.chipTypeTag(panel)

    if (typeTag) {
      const tag = document.createElement("span")

      tag.className = "text-[10px] font-voodu-mono text-voodu-muted-2 uppercase tracking-[0.04em] shrink-0"
      tag.textContent = typeTag
      row.appendChild(tag)
    }

    const remove = document.createElement("button")

    remove.type = "button"
    remove.className = "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-red shrink-0"
    remove.setAttribute("aria-label", `Remove ${panel.label}`)
    remove.dataset.action = "click->dashboard-builder#remove"
    remove.dataset.dashboardBuilderIndexParam = index
    remove.textContent = "✕"
    row.appendChild(remove)

    return row
  }

  // chipTypeTag — the small uppercase tag on a panel chip. Log panels read
  // "count"; gauges read their shape; an area chart has no tag.
  chipTypeTag(panel) {
    if (panel.scope_kind === "log") return "count"
    if (panel.chart_type === "gauge_radial") return "radial"
    if (panel.chart_type === "gauge_linear") return "linear"

    return null
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
