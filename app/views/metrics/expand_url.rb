# frozen_string_literal: true

# Views::Metrics::ExpandUrl — the maximize button's href, shared by
# Views::Metrics::Index (first paint) and Views::Metrics::Frame (every
# broadcast/poll re-render of the grid).
#
# These MUST agree: the two views render the same chart cards, so if only one
# builds the URL correctly, the maximize button silently changes behavior the
# moment the first poll tick swaps the frame in. That's exactly what happened —
# Index learned to carry the custom (brushed) window + interval into the modal,
# Frame didn't, so after one tick the maximized chart dropped back to the
# default range. Living in one module makes that drift impossible.
#
# The expand URL echoes the page's active window (range / from / until /
# interval) so the modal opens on the SAME span the operator is viewing, then
# layers on the per-chart metric metadata so /metrics/chart rebuilds the right
# single-chart slice. The endpoint reads all of it URL-first, falling back to
# its defaults when absent.
module Views::Metrics::ExpandUrl
  private

  # custom_window? — the active page is pinned to an explicit from/until window
  # (range=custom), i.e. a frozen past span rather than a rolling "last N".
  def custom_window?
    @data.respond_to?(:custom?) && @data.custom?
  end

  def expand_url_for(chart, data)
    # A zeroed card (a render the measure can't fill) has nothing to expand.
    return nil if chart[:zeroed]

    return hep3_expand_url(chart, data) if chart[:source] == "hep3"
    return log_expand_url(chart, data) if chart[:source] == "log"
    return multi_expand_url(chart, data) if chart[:multi]

    # Dashboard charts carry their own resolved scope_kind/scope_id (each panel
    # resolves to its own pod); scope-mode charts inherit the page's scope.
    sk = chart[:scope_kind] || (data.respond_to?(:scope_kind) ? data.scope_kind : nil)
    sid = chart[:scope_id] || (data.respond_to?(:scope_id) ? data.scope_id : nil)

    qp = {
      scope_kind: sk || "host",
      scope_id: sid,
      range: custom_window? ? "custom" : (data&.range || "1h"),
      # Carry the explicit window so the maximized chart opens on the SAME span
      # the operator is viewing (the endpoint re-resolves it).
      from: custom_window? ? request.query_parameters[:from] : nil,
      until: custom_window? ? request.query_parameters[:until] : nil,
      # `auto` is the default — omit from the URL so default views have a clean
      # `?range=1h` instead of `?range=1h&interval=auto`.
      interval: (data&.interval && data.interval != "auto") ? data.interval : nil,
      metric: chart[:metric],
      scale: chart[:scale],
      label: chart[:label],
      color: chart[:color],
      unit: chart[:unit],
      # server_id → the expand modal drills into the SAME server this panel
      # reads from (a cross-server dashboard panel expands its own server, not
      # the URL's). Omitted on scope-mode charts (they inherit current_server).
      server_id: chart[:server_id],
      # Carry the panel's chart type so the expand modal renders the same shape
      # (a gauge stays a gauge). Omitted for the default area.
      chart_type: ((chart[:chart_type].to_s == "area") ? nil : chart[:chart_type])
    }.compact

    "#{metrics_chart_path}?#{qp.to_query}"
  end

  # multi_expand_url — the maximize URL for a multi-series (multi-pod) chart. A
  # multi chart can't be rebuilt from flat metric/scope params (it's N pods on
  # shared axes), so it references the panel by dashboard + index; /metrics/chart
  # reloads the dashboard and rebuilds the series. Same active window as the rest.
  def multi_expand_url(chart, data)
    qp = {
      pid: chart[:dashboard_uuid], panel: chart[:panel_index],
      range: custom_window? ? "custom" : (data&.range || "1h"),
      from: custom_window? ? request.query_parameters[:from] : nil,
      until: custom_window? ? request.query_parameters[:until] : nil,
      interval: (data&.interval && data.interval != "auto") ? data.interval : nil
    }.compact

    "#{metrics_chart_path}?#{qp.to_query}"
  end

  # log_expand_url — the maximize URL for a log-query count CHART (area/bars/
  # line). Carries the panel (scope/name/query/chart_type) so /metrics/chart
  # re-aggregates the same slice in the modal, plus the same active window. A
  # log number tile has no expand button, so this only fires for chart renders.
  def log_expand_url(chart, data)
    qp = {
      source: "log", scope: chart[:scope], name: chart[:name],
      query: chart[:query].presence, chart_type: chart[:chart_type],
      label: chart[:label], color: chart[:color],
      server_id: chart[:server_id],
      range: custom_window? ? "custom" : (data&.range || "1h"),
      from: custom_window? ? request.query_parameters[:from] : nil,
      until: custom_window? ? request.query_parameters[:until] : nil,
      interval: (data&.interval && data.interval != "auto") ? data.interval : nil
    }.compact

    "#{metrics_chart_path}?#{qp.to_query}"
  end

  # hep3_expand_url — the maximize URL for a HEP3 count chart. Carries the
  # panel (source/scope/name/view/filter/chart_type/percent) so /metrics/chart
  # re-aggregates the same slice in the modal, plus the same active window.
  def hep3_expand_url(chart, data)
    qp = {
      source: "hep3", scope: chart[:scope], name: chart[:name], view: chart[:view],
      filter_query: chart[:filter_query].presence,
      chart_type: chart[:chart_type], percent: (chart[:percent] ? "true" : nil),
      label: chart[:label], color: chart[:color],
      # server_id → re-aggregate against the panel's own server in the modal.
      server_id: chart[:server_id],
      range: custom_window? ? "custom" : (data&.range || "1h"),
      from: custom_window? ? request.query_parameters[:from] : nil,
      until: custom_window? ? request.query_parameters[:until] : nil,
      interval: (data&.interval && data.interval != "auto") ? data.interval : nil
    }.compact

    "#{metrics_chart_path}?#{qp.to_query}"
  end
end
