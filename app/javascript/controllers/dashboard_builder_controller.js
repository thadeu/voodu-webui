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
  static targets = ["sourceLabel", "metricLabel", "metricMenu", "shapeChip", "shapeSkeleton", "metricSwatch", "list", "empty", "hidden",
                    "logSourceLabel", "logLabel", "logQuery", "logSwatch", "logShowChart",
                    "tableBlock", "tableBlockTitle", "tableSourceViewLabel", "tableSourceMenu", "tableLabel", "tableQuery", "tableSwatch",
                    "hep3Shapes", "hep3ShapeChip", "hep3PercentRow", "hep3Percent",
                    "idleStep", "typeStep", "metricBlock", "logBlock",
                    "metricBlockTitle", "logBlockTitle", "backLink"]
  static values  = {
    catalog:          Object,
    logsSourceViews:  Array,
    hep3SourceViews:  Array,
    logsFields:       Array,
    hep3Fields:       Array,
    hep3Hints:        Object,
    panels:           Array
  }

  connect() {
    this.panels = Array.isArray(this.panelsValue) ? this.panelsValue.map((p) => ({ ...p })) : []
    this.currentSource = { scope_kind: "host", label: "host" }
    this.currentMetric = null
    this.currentMetricColor = null
    this.currentChartType = "area"

    this.currentLogSource = null
    this.currentLogColor = this.defaultLogColor()

    this.currentTableSourceView = null
    this.tableKind = "table"
    this.currentHep3Shape = "table"
    this.currentTableColor = this.defaultTableColor()

    this.addType = "metric"
    // idle → nothing selected (the resting/open state); type → the Add
    // panel chooser; config → a type's config block (new or editing).
    this.wizardStep = "idle"
    this.editingIndex = null
    this.selectedIndex = null

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

    // The DS color picker lives in a popover that portals OUT of this form to
    // the modal dialog, so its `color-picker:change` doesn't bubble through
    // here — listen on the document instead.
    this.onCustomColor = this.onCustomColor.bind(this)
    document.addEventListener("color-picker:change", this.onCustomColor)
  }

  disconnect() {
    if (this.sortable) this.sortable.destroy()

    if (this.hasLogQueryTarget && this.onLogQueryInput) {
      this.logQueryTarget.removeEventListener("input", this.onLogQueryInput)
    }

    if (this.hasTableQueryTarget && this.onTableQueryInput) {
      this.tableQueryTarget.removeEventListener("input", this.onTableQueryInput)
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

    // Table (logs) + HEP3 share one block; activate the kind's options + the
    // first source·view so autoCommit can create the panel immediately.
    if (type === "table" || type === "hep3") this.activateTableKind(type)

    this.syncWizard()
    // Metric panels have valid defaults (host · first metric) → auto-create
    // immediately so the operator just refines. Log + table panels need a
    // query / pod, so autoCommit no-ops here and fires on that input instead.
    this.autoCommit()
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
    const editing = this.editingIndex != null

    if (this.hasIdleStepTarget) this.idleStepTarget.hidden = step !== "idle"
    if (this.hasTypeStepTarget) this.typeStepTarget.hidden = step !== "type"
    if (this.hasMetricBlockTarget) this.metricBlockTarget.hidden = !(config && this.addType === "metric")
    if (this.hasLogBlockTarget) this.logBlockTarget.hidden = !(config && isLog)
    if (this.hasTableBlockTarget) this.tableBlockTarget.hidden = !(config && isTable)

    if (this.hasMetricBlockTitleTarget) this.metricBlockTitleTarget.textContent = editing ? "Edit metric panel" : "New metric panel"
    if (this.hasLogBlockTitleTarget) this.logBlockTitleTarget.textContent = editing ? "Edit log count" : "New log count"
    if (this.hasTableBlockTitleTarget) this.tableBlockTitleTarget.textContent = editing ? "Edit table panel" : "New table panel"
    this.backLinkTargets.forEach((el) => { el.textContent = editing ? "Cancel" : "Change type" })
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

  // selectSource — operator picked a source row. Update the trigger
  // label + remember the identity, then rebuild the metric menu for
  // this source's kind.
  selectSource(event) {
    const source = this.parse(event.currentTarget.dataset.source)

    if (!source) return

    this.currentSource = source
    if (this.hasSourceLabelTarget) this.sourceLabelTarget.textContent = event.currentTarget.textContent.trim()

    this.populateMetrics()
    this.autoCommit()
  }

  selectMetric(event) {
    const spec = this.parse(event.currentTarget.dataset.metric)

    if (!spec) return

    this.currentMetric = spec
    if (this.hasMetricLabelTarget) this.metricLabelTarget.textContent = spec.label

    // Reset to this metric's canonical color (the operator can re-override
    // via the swatches); recolor the shape previews to match.
    this.currentMetricColor = spec.color
    this.highlightMetricColor()
    this.recolorShapes()

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
    this.highlightShape()
    this.autoCommit()
  }

  // highlightShape — ring the active shape chip (accent border + fill). Inline
  // styles so nothing depends on a purge-scanned Tailwind class.
  highlightShape() {
    if (!this.hasShapeChipTarget) return

    this.shapeChipTargets.forEach((el) => {
      const active = el.dataset.chartType === this.currentChartType

      el.style.borderColor = active ? "var(--voodu-accent-line)" : ""
      el.style.background   = active ? "var(--voodu-accent-dim)" : ""
      el.setAttribute("aria-pressed", active ? "true" : "false")
    })
  }

  // syncTypeAvailability — gauges need a ceiling, so hide the gauge chips (and
  // snap the selection back to Area) whenever the current metric has none.
  // Driven by the spec's `gauge` flag from the catalog.
  syncTypeAvailability() {
    const eligible = !!(this.currentMetric && this.currentMetric.gauge)

    if (this.hasShapeChipTarget) {
      this.shapeChipTargets.forEach((el) => {
        if (el.dataset.gauge === "true") el.hidden = !eligible
      })
    }

    if (!eligible && this.currentChartType !== "area") this.currentChartType = "area"

    this.highlightShape()
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
    this.currentMetricColor = this.currentMetric ? this.currentMetric.color : null

    if (this.hasMetricLabelTarget) {
      this.metricLabelTarget.textContent = this.currentMetric ? this.currentMetric.label : "Select metric"
    }

    this.highlightMetricColor()
    this.recolorShapes()
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
  }

  // panelForType — the in-progress panel for the active add type, or null
  // when there isn't enough input to build one yet.
  panelForType() {
    if (this.addType === "log") return this.buildLogPanelSafe()

    if (this.addType === "table" || this.addType === "hep3") return this.buildTablePanelSafe()

    return this.buildPanelSafe()
  }

  // buildPanelSafe — the metric panel for the current source+metric, or null
  // when there isn't enough to build one yet.
  buildPanelSafe() {
    if (!this.currentSource || !this.currentMetric) return null

    return this.buildPanel(this.currentSource, this.currentMetric)
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
    else this.loadMetricPanel(panel)

    this.render()
  }

  // typeForPanel — the add-wizard type a saved panel edits under.
  typeForPanel(panel) {
    if (panel.scope_kind === "log") return "log"

    if (panel.scope_kind === "table") return panel.source === "hep3" ? "hep3" : "table"

    return "metric"
  }

  // loadMetricPanel — restore source + metric + chart type into the metric
  // block's dropdowns from a saved panel.
  loadMetricPanel(panel) {
    const host = panel.scope_kind === "host"

    this.currentSource = host
      ? { scope_kind: "host", label: "host" }
      : { scope_kind: "pod", scope: panel.scope, name: panel.name, kind: panel.kind || "pod", label: panel.name }

    if (this.hasSourceLabelTarget) {
      this.sourceLabelTarget.textContent = host ? "Host (system)" : `${panel.name} · ${panel.kind || "pod"}`
    }

    this.populateMetrics()

    const key  = host ? "host" : (panel.kind || "pod")
    const spec = ((this.catalogValue && this.catalogValue[key]) || []).find((s) => s.metric === panel.metric)

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
    this.syncTypeAvailability()
  }

  // loadLogPanel — restore pod + label + query + color into the log block.
  loadLogPanel(panel) {
    this.currentLogSource = { scope_kind: "pod", scope: panel.scope, name: panel.name, kind: panel.kind || "pod", label: panel.name }
    if (this.hasLogSourceLabelTarget) this.logSourceLabelTarget.textContent = `${panel.name} · ${panel.kind || "pod"}`
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
    const srcLabel = source.label || (source.scope_kind === "host" ? "host" : source.name)

    const panel = {
      scope_kind: source.scope_kind,
      metric:     spec.metric,
      scale:      spec.scale,
      label:      `${srcLabel} · ${spec.label}`,
      // Operator's chosen color, falling back to the metric's canonical one.
      color:      this.currentMetricColor || spec.color,
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
      scope:        sv.scope,
      name:         sv.name,
      view:         sv.view,
      label:        label || sv.label,
      color:        this.currentTableColor || this.defaultTableColor(),
      filter_query: filterQuery,
      percent:      percent
    }
  }

  // loadTablePanel — restore source·view (reader + view) + label + filter +
  // color from a saved panel (edit-in-place). Matches the reader by name so a
  // multi-reader island restores the right one.
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
    const sv = list.find((s) => s.source === panel.source && s.view === panel.view && s.name === panel.name) ||
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

  // chipTypeLabel — the chart-type line under each panel's label. Log panels
  // render a number + sparkline → "Log spark" (not "Count", which read as a
  // count-type query); metric panels read their shape (Area is the default).
  chipTypeLabel(panel) {
    if (panel.scope_kind === "log") return "Log spark"
    if (panel.scope_kind === "table") return "Table"
    if (panel.chart_type === "gauge_radial") return "Radial"
    if (panel.chart_type === "gauge_linear") return "Linear"

    return "Area"
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
