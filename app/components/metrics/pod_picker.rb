# frozen_string_literal: true

# Components::Metrics::PodPicker — pod (with "host" as the default
# row) selector for the /metrics page charts.
#
# Sibling of Components::Logs::PodPicker. Both adapters consume the
# same Components::UI::ScopePicker primitive (own the DOM shell,
# scrollbar treatment, dropdown wiring) and differ only in their
# data shaping:
#   - Metrics — primary row is HOST (the controller VM); selecting
#     a pod swaps the chart's scope. URLs preserve the active
#     `range` param so the operator doesn't lose their time window.
#   - Logs — primary row is ALL (multi-source fan-out); selecting
#     a pod scopes the tail to that one container.
class Components::Metrics::PodPicker < Components::Base
  # Modal opt-ins (all optional, defaulting to the page-level
  # behavior so existing call sites stay unchanged):
  #
  #   base_path:    where each row's URL points. Default
  #                 `metrics_path` (the page). Modal uses
  #                 `metrics_chart_path`.
  #   extra_params: hash merged into every URL after the standard
  #                 scope_kind/scope_id pair. Used by the modal
  #                 to ride along metric/scale/range/etc.
  #   turbo_stream: when true, anchor rows emit
  #                 `data-turbo-stream="true"` so clicking them
  #                 does a GET that the server answers with a
  #                 turbo_stream response — drives the
  #                 chart-modal swap in place without closing
  #                 the modal. When false (default), rows fall
  #                 back to `data-turbo="false"` for full-page
  #                 navigation (the original /metrics page
  #                 sidebar picker behaviour).
  #   hide_host:    skip the HOST primary section. The chart-modal
  #                 endpoint is per-metric and metrics are scoped
  #                 to either host OR pod — offering "host" inside
  #                 a modal showing a pod-only metric (like
  #                 req_count) would lead to "no data" confusion.
  def initialize(scope_kind:, scope_id:, current_island:, pods: [],
                 base_path: nil, extra_params: {}, turbo_stream: false,
                 hide_host: false)
    @scope_kind     = scope_kind         # "host" | "pod"
    @scope_id       = scope_id           # host name or pod container name
    @current_island = current_island
    @pods           = Array(pods)
    @base_path      = base_path
    @extra_params   = extra_params || {}
    @turbo_stream   = turbo_stream
    @hide_host      = hide_host
  end

  def view_template
    render Components::UI::ScopePicker.new(
      trigger:         build_trigger,
      primary_section: @hide_host ? nil : build_host_section,
      pod_sections:    build_pod_sections
    )
  end

  private

  def build_trigger
    if @scope_kind == "host"
      { icon: :CpuChipOutline, prefix: "host ", value: display_id }
    else
      { icon: :CubeOutline,    prefix: "pod ",  value: display_id }
    end
  end

  def display_id
    return @scope_id.to_s if @scope_id.present?
    return @current_island&.name || "host" if @scope_kind == "host"

    "(unknown)"
  end

  def build_host_section
    host_name = @current_island&.name || "host"

    {
      label:  "HOST",
      option: {
        title:       host_name,
        meta:        "#{@current_island&.host || "—"} · #{@pods.size} pods",
        href:        metrics_url(kind: "host", id: host_name),
        active:      @scope_kind == "host",
        icon:        :CpuChipOutline,
        turbo_stream: @turbo_stream
      }
    }
  end

  def build_pod_sections
    return [] if @pods.empty?

    @pods
      .group_by { |p| p[:scope] || p["scope"] || "(default)" }
      .sort_by  { |k, _| k.to_s }
      .map do |scope_name, pods|
        {
          label:   scope_name.to_s,
          options: pods.map { |p| pod_to_option(p) }
        }
      end
  end

  def pod_to_option(p)
    container = p[:name] || p["name"]
    resource  = p[:resource_name] || p["resource_name"]
    replica   = p[:replica_id] || p["replica_id"]
    image     = p[:image] || p["image"]
    status    = (p[:status] || p["status"] || "running").to_s.to_sym

    title = replica.present? ? "#{resource}.#{replica}" : (resource || container)

    {
      title:        title,
      meta:         image,
      href:         metrics_url(kind: "pod", id: container),
      active:       @scope_kind == "pod" && @scope_id == container,
      status:       status,
      turbo_stream: @turbo_stream
    }
  end

  # metrics_url — preserves the current request's query params + any
  # `extra_params` the caller passed (e.g. modal context with
  # metric/scale/range). Modal overrides `base_path` to point at
  # /metrics/chart instead of /metrics so URL stays inside the
  # in-modal endpoint.
  def metrics_url(kind:, id:)
    base = @base_path || metrics_path
    params = request.query_parameters.merge(@extra_params).merge(scope_kind: kind, scope_id: id)
    "#{base}?#{params.to_query}"
  end
end
