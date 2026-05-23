# frozen_string_literal: true

# Views::Logs::Index — pod picker on the left, scrolling log box on
# the right. Selecting a pod sets `:name` in the URL which routes to
# LogsController#show.
class Views::Logs::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, pods: [], error: nil, selected_pod: nil, logs: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @pods           = pods
    @error          = error
    @selected_pod   = selected_pod
    @logs           = logs
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands, current_island: @current_island
    ) do
      div(class: "h-full") do
        if @current_island.nil?
          render Components::UI::NoIslandState.new
        elsif @error && @pods.empty?
          render Components::UI::ErrorState.new(error: @error)
        else
          logs_split_pane
        end
      end
    end
  end

  private

  def logs_split_pane
    div(class: "flex h-full") do
      pods_picker
      logs_pane
    end
  end

  def pods_picker
    aside(class: "w-[260px] border-r border-voodu-border bg-voodu-surface overflow-y-auto") do
      div(class: "px-3 py-3 border-b border-voodu-border") do
        h2(class: "text-[11px] font-semibold uppercase tracking-wider text-voodu-muted") { "Pods" }
      end

      if @pods.empty?
        div(class: "px-3 py-4 text-voodu-muted text-xs") { "no pods." }
      else
        div(class: "flex flex-col") { @pods.each { |p| pod_row(p) } }
      end
    end
  end

  def pod_row(pod)
    active = pod["name"] == @selected_pod
    a(
      href: "/logs/#{CGI.escape(pod['name'])}",
      class: tokens(
        "flex items-center gap-2 px-3 py-2 border-b border-voodu-border",
        active ? "bg-voodu-accent-dim" : "hover:bg-voodu-surface-2"
      )
    ) do
      render Components::UI::StatusDot.new(status: pod["running"] ? :running : :stopped)
      span(class: "font-voodu-mono text-[12px] truncate flex-1") { pod["name"] }
    end
  end

  def logs_pane
    section(class: "flex-1 flex flex-col overflow-hidden") do
      if @selected_pod
        div(
          class: "flex-1 flex flex-col overflow-hidden",
          data: { controller: "polling", polling_interval_value: 5000 }
        ) do
          logs_header
          turbo_frame_tag("logs", src: "/logs/#{CGI.escape(@selected_pod)}?frame=logs", class: "flex-1 overflow-hidden") do
            div(class: "p-4 text-voodu-muted text-sm") { "loading…" }
          end
        end
      else
        div(class: "flex-1 flex items-center justify-center text-voodu-muted text-sm") do
          plain "← select a pod to tail logs"
        end
      end
    end
  end

  def logs_header
    div(class: "flex items-center justify-between px-4 py-2 border-b border-voodu-border bg-voodu-bg-2") do
      div(class: "flex items-center gap-3") do
        render Components::UI::StatusDot.new(status: :running, pulse: true)
        span(class: "font-voodu-mono text-sm text-voodu-text") { @selected_pod }
      end
      span(class: "text-[11px] text-voodu-muted") { "tail · refreshes every 5s" }
    end
  end
end
