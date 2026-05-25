# frozen_string_literal: true

# Components::Logs::PodPicker — all-pods vs single-pod selector for
# the /logs page.
#
# Thin adapter: builds the data structure that
# Components::UI::ScopePicker expects (trigger label, ALL primary
# section, pod groups) and delegates the render. Look + behaviour
# stay in lock-step with Components::Metrics::PodPicker because
# both surfaces go through the same UI primitive.
class Components::Logs::PodPicker < Components::Base
  def initialize(active_pod:, pods: [])
    @active_pod = active_pod
    @pods       = Array(pods)
  end

  def view_template
    render Components::UI::ScopePicker.new(
      trigger:         build_trigger,
      primary_section: build_all_section,
      pod_sections:    build_pod_sections
    )
  end

  private

  def build_trigger
    if @active_pod.present?
      { icon: :CubeOutline,        prefix: "pod ", value: @active_pod }
    else
      { icon: :Squares2x2Outline,  prefix: nil,    value: "all pods" }
    end
  end

  def build_all_section
    {
      label:  "ALL",
      option: {
        title:  "all pods",
        meta:   "#{@pods.size} #{@pods.size == 1 ? "source" : "sources"}",
        href:   logs_path,
        active: @active_pod.blank?,
        icon:   :Squares2x2Outline
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
      title:  title,
      meta:   image,
      href:   pod_logs_path(name: container),
      active: @active_pod == container,
      status: status
    }
  end
end
