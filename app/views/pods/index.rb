# frozen_string_literal: true

# Views::Pods::Index — dense table of every container the active
# island reports. Each row: status dot, name (mono), kind, image,
# CPU mini-bar, memory mini-bar, age, restart button.
#
# Three-state pattern:
#   - no island selected   → NoIslandState
#   - client raised        → ErrorState
#   - happy                → table
class Views::Pods::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, pods: [], error: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @pods           = pods
    @error          = error
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands, current_island: @current_island
    ) do
      div(class: "mx-auto max-w-6xl px-6 py-6 flex flex-col gap-5") do
        header_block

        if @current_island.nil?
          render Components::UI::NoIslandState.new
        elsif @error
          render Components::UI::ErrorState.new(error: @error)
        elsif @pods.empty?
          empty_pods
        else
          pods_table
        end
      end
    end
  end

  private

  def header_block
    div(class: "flex items-baseline justify-between") do
      div(class: "flex flex-col gap-1") do
        h1(class: "text-2xl font-semibold text-voodu-text") { "Pods" }
        p(class: "text-voodu-text-2 text-sm") do
          if @current_island
            plain "#{@pods.size} container#{'s' unless @pods.size == 1} on "
            span(class: "font-voodu-mono text-voodu-accent-2") { @current_island.name }
          end
        end
      end
      render(Components::UI::Button.new(tag: :a, variant: :ghost, size: :sm, href: pods_path)) { "Refresh" }
    end
  end

  def empty_pods
    div(class: "py-12 text-center text-voodu-muted text-sm") { "no containers reported." }
  end

  def pods_table
    div(class: "border border-voodu-border rounded-voodu-md overflow-hidden bg-voodu-surface") do
      table(class: "w-full text-[12.5px]") do
        thead(class: "border-b border-voodu-border bg-voodu-bg-2") do
          tr do
            %w[status name kind image restarts age actions].each do |col|
              th(class: "text-left px-3 py-2 text-[10.5px] font-medium uppercase tracking-wider text-voodu-muted") { col }
            end
          end
        end

        tbody do
          @pods.each { |pod| pod_row(pod) }
        end
      end
    end
  end

  def pod_row(pod)
    status = pod_status(pod)

    tr(class: "border-b border-voodu-border last:border-b-0 hover:bg-voodu-surface-2") do
      td(class: "px-3 py-2") { render Components::UI::StatusDot.new(status: status) }

      td(class: "px-3 py-2") do
        span(class: "font-voodu-mono text-voodu-text") { pod["name"] }
      end

      td(class: "px-3 py-2 text-voodu-text-2") { pod["kind"] || "—" }

      td(class: "px-3 py-2") do
        span(class: "font-voodu-mono text-voodu-text-2 text-[11px]") { pod["image"] || "—" }
      end

      td(class: "px-3 py-2 font-voodu-mono text-voodu-text-2") { (pod["restarts"] || 0).to_s }

      td(class: "px-3 py-2 text-voodu-muted text-[11px]") { format_age(pod["created_at"]) }

      td(class: "px-3 py-2 text-right") { restart_form(pod) }
    end
  end

  def restart_form(pod)
    return if pod["kind"].present? && !pod["kind"].in?(%w[deployment statefulset])

    form(
      action: "/pods/#{CGI.escape(pod['name'])}/restart",
      method: "post",
      class: "inline-flex",
      data: { turbo_confirm: "Restart #{pod['name']}?", turbo: false }
    ) do
      input(type: "hidden", name: "authenticity_token", value: helpers.form_authenticity_token)
      button(
        type: "submit",
        class: "inline-flex items-center gap-1 px-2 py-1 text-[11px] rounded-voodu-sm border border-voodu-border text-voodu-text-2 hover:bg-voodu-surface-3 hover:text-voodu-text"
      ) { "Restart" }
    end
  end

  def pod_status(pod)
    return :running if pod["running"]

    :stopped
  end

  def format_age(created_at)
    return "—" if created_at.blank?

    t = Time.zone.parse(created_at.to_s)
    distance = Time.current - t
    case distance
    when 0..59 then "#{distance.to_i}s"
    when 60..3599 then "#{(distance / 60).to_i}m"
    when 3600..86_399 then "#{(distance / 3600).to_i}h"
    else "#{(distance / 86_400).to_i}d"
    end
  rescue ArgumentError, TypeError
    "—"
  end
end
